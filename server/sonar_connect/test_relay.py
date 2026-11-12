"""Relay tests against a real relay server and a fake Navidrome ping.

    python -m unittest -v test_relay.py      (from server/sonar_connect)
"""

from __future__ import annotations

import contextlib
import hashlib
import http.client
import io
import json
import queue
import socket
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

import relay

PASSWORDS = {"alice": "alice-test-pw", "bob": "bob-test-pw", "admin": "admin-test-pw"}
ADMINS = {"admin"}
SCANS: list[str] = []


def token(user: str, salt: str) -> str:
    return hashlib.md5((PASSWORDS[user] + salt).encode()).hexdigest()


class FakeNavidrome(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):  # noqa: N802
        q = {k: v[0] for k, v in parse_qs(urlsplit(self.path).query).items()}
        user = q.get("u", "")
        path = urlsplit(self.path).path
        login = user in PASSWORDS and q.get("t") == token(user, q.get("s", ""))
        ok = path == "/rest/ping.view" and login
        if path == "/rest/startScan.view":
            # Like Navidrome: only an admin may start a scan.
            ok = login and user in ADMINS
            if ok:
                SCANS.append(user)
        body = json.dumps({"subsonic-response": {"status": "ok" if ok else "failed"}}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def start(server: ThreadingHTTPServer) -> int:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_address[1]


class Client:
    """One app: hello, then an event stream read on a thread."""

    def __init__(self, port: int, user: str, device_id: str, prefix: str = ""):
        self.port = port
        self.prefix = prefix
        self.events: queue.Queue = queue.Queue()
        salt = f"salt{device_id}"
        status, body = self.post(
            "/hello",
            {"u": user, "t": token(user, salt), "s": salt, "device": {"id": device_id, "name": device_id, "kind": "pc"}},
        )
        assert status == 200, status
        self.session = body["session"]
        self.conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        self.conn.connect()
        # http.client drops its own reference once a Connection: close stream starts.
        self.sock = self.conn.sock
        self.conn.request("GET", prefix + "/events", headers={"Authorization": f"Bearer {self.session}"})
        self.response = self.conn.getresponse()
        assert self.response.status == 200, self.response.status
        self.closed = threading.Event()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        event = None
        try:
            for raw in self.response:
                line = raw.decode().rstrip("\n")
                if line.startswith("event: "):
                    event = line[7:]
                elif line.startswith("data: "):
                    self.events.put((event, json.loads(line[6:])))
        except Exception:  # noqa: BLE001
            pass
        self.closed.set()

    def post(self, path: str, body: dict, session: str | None = None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        headers = {"Content-Type": "application/json"}
        if session or getattr(self, "session", None):
            headers["Authorization"] = f"Bearer {session or self.session}"
        conn.request("POST", self.prefix + path, json.dumps(body), headers)
        r = conn.getresponse()
        data = r.read()
        conn.close()
        return r.status, (json.loads(data) if data else {})

    def next(self, kind: str, where=lambda _: True, timeout: float = 5):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                event, data = self.events.get(timeout=max(0.01, end - time.monotonic()))
            except queue.Empty:
                break
            if event == kind and where(data):
                return data
        raise AssertionError(f"no {kind} event")

    def close(self):
        """Hangs up, like an app being closed."""
        with contextlib.suppress(OSError):
            self.sock.shutdown(socket.SHUT_RDWR)
        self.sock.close()


def ids(devices):
    return sorted(d["id"] for d in devices)


class RelayTest(unittest.TestCase):
    def setUp(self):
        self.navidrome = ThreadingHTTPServer(("127.0.0.1", 0), FakeNavidrome)
        nav_port = start(self.navidrome)
        self.log = io.StringIO()
        self._stderr = contextlib.redirect_stderr(self.log)
        self._stderr.__enter__()
        self.navidrome_url = f"http://127.0.0.1:{nav_port}"
        self.relay = relay.serve(0, self.navidrome_url, host="127.0.0.1")
        self.port = start(self.relay)
        self.clients: list[Client] = []

    def tearDown(self):
        for c in self.clients:
            with contextlib.suppress(Exception):
                c.close()
        self.relay.shutdown()
        self.navidrome.shutdown()
        self._stderr.__exit__(None, None, None)

    def client(self, user: str, device_id: str, prefix: str = "") -> Client:
        c = Client(self.port, user, device_id, prefix)
        self.clients.append(c)
        return c

    def test_a_wrong_password_gets_no_session(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        body = {"u": "alice", "t": "0" * 32, "s": "x", "device": {"id": "pc"}}
        conn.request("POST", "/hello", json.dumps(body), {"Content-Type": "application/json"})
        self.assertEqual(conn.getresponse().status, 401)

    def test_no_session_no_stream_or_commands(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.request("GET", "/events", headers={"Authorization": "Bearer nope"})
        self.assertEqual(conn.getresponse().status, 401)
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.request("POST", "/command", json.dumps({"to": "x"}), {"Authorization": "Bearer nope"})
        self.assertEqual(conn.getresponse().status, 401)

    def test_devices_on_one_account_see_each_other_and_their_state(self):
        pc = self.client("alice", "pc")
        phone = self.client("alice", "phone")
        self.assertEqual(ids(pc.next("devices", lambda d: len(d) == 2)), ["pc", "phone"])
        phone.next("devices", lambda d: len(d) == 2)
        self.assertEqual(pc.post("/state", {"playing": True, "song": {"id": "a2"}, "queue": [1, 2]})[0], 200)
        self.assertEqual(
            phone.next("state"), {"id": "pc", "state": {"playing": True, "song": {"id": "a2"}, "queue": [1, 2]}}
        )
        # Later changes carry only what changed...
        pc.post("/state", {"playing": False})
        self.assertEqual(phone.next("state"), {"id": "pc", "state": {"playing": False}})
        with self.assertRaises(AssertionError):
            pc.next("state", timeout=0.3)  # (a device isn't sent its own changes)
        # ...and a device that joins later gets the whole merged state.
        tablet = self.client("alice", "tablet")
        seen = tablet.next("devices", lambda d: len(d) == 3)
        self.assertEqual(
            next(x for x in seen if x["id"] == "pc")["state"],
            {"playing": False, "song": {"id": "a2"}, "queue": [1, 2]},
        )

    def test_a_command_reaches_only_its_device_and_names_the_sender(self):
        pc = self.client("alice", "pc")
        phone = self.client("alice", "phone")
        tablet = self.client("alice", "tablet")
        pc.next("devices", lambda d: len(d) == 3)
        self.assertEqual(phone.post("/command", {"to": "pc", "cmd": "next"})[0], 200)
        self.assertEqual(pc.next("command"), {"to": "pc", "cmd": "next", "from": "phone"})
        with self.assertRaises(AssertionError):
            tablet.next("command", timeout=0.5)

    def test_accounts_are_kept_apart(self):
        alice = self.client("alice", "pc")
        bob = self.client("bob", "phone")
        self.assertEqual(ids(bob.next("devices")), ["phone"])
        self.assertEqual(ids(alice.next("devices")), ["pc"])
        self.assertEqual(bob.post("/command", {"to": "pc", "cmd": "pause"})[0], 404)
        bob.post("/state", {"playing": True})
        with self.assertRaises(AssertionError):
            alice.next("state", timeout=0.5)

    def test_a_closed_app_leaves_the_list(self):
        pc = self.client("alice", "pc")
        phone = self.client("alice", "phone")
        pc.next("devices", lambda d: len(d) == 2)
        phone.close()
        self.assertEqual(ids(pc.next("devices", lambda d: len(d) == 1)), ["pc"])

    def test_a_device_gone_silent_leaves_but_a_chatty_one_stays(self):
        saved = relay.SILENT_SECONDS
        relay.SILENT_SECONDS = 2
        self.addCleanup(setattr, relay, "SILENT_SECONDS", saved)
        pc = self.client("alice", "pc")
        phone = self.client("alice", "phone")
        pc.next("devices", lambda d: len(d) == 2)
        for _ in range(8):  # The PC keeps posting, the phone says nothing.
            pc.post("/state", {"tick": True})
            time.sleep(0.5)
        self.assertTrue(phone.closed.wait(3), "the silent phone's stream should end")
        self.assertFalse(pc.closed.is_set(), "the PC is still talking")
        self.assertEqual(ids(pc.next("devices", lambda d: len(d) == 1)), ["pc"])

    def test_reconnecting_replaces_the_old_connection(self):
        pc = self.client("alice", "pc")
        old = self.client("alice", "phone")
        new = self.client("alice", "phone")
        self.assertTrue(old.closed.wait(5), "the old stream should be closed")
        self.assertEqual(ids(new.next("devices", lambda d: len(d) == 2)), ["pc", "phone"])
        self.assertEqual(old.post("/state", {"x": 1})[0], 401, "the old session is gone")
        self.assertEqual(pc.post("/command", {"to": "phone", "cmd": "play"})[0], 200)
        self.assertEqual(new.next("command")["cmd"], "play")

    def test_works_under_the_tailscale_path(self):
        pc = self.client("alice", "pc", prefix="/sonar-connect")
        phone = self.client("alice", "phone", prefix="/sonar-connect")
        pc.next("devices", lambda d: len(d) == 2)
        phone.post("/command", {"to": "pc", "cmd": "pause"})
        self.assertEqual(pc.next("command")["cmd"], "pause")

    def rescan_relay(self, admin_password: str):
        """A second relay with an admin login, for the rescan tests."""
        server = relay.serve(
            0, self.navidrome_url, host="127.0.0.1", admin_user="admin", admin_password=admin_password
        )
        self.addCleanup(server.shutdown)
        return start(server)

    def test_rescan_off_without_an_admin_login(self):
        pc = self.client("alice", "pc")
        self.assertEqual(pc.post("/rescan", {}), (503, {"scan": "off"}))

    def test_rescan_asks_navidrome_as_the_admin_once_per_gap(self):
        SCANS.clear()
        port = self.rescan_relay(PASSWORDS["admin"])
        phone = Client(port, "alice", "phone")
        self.clients.append(phone)
        self.assertEqual(phone.post("/rescan", {}), (200, {"scan": "started"}))
        self.assertEqual(SCANS, ["admin"])
        # A second album right after shares the scan already running.
        self.assertEqual(phone.post("/rescan", {}), (200, {"scan": "recent"}))
        self.assertEqual(SCANS, ["admin"])

    def test_rescan_needs_a_session(self):
        port = self.rescan_relay(PASSWORDS["admin"])
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        conn.request("POST", "/sonar-connect/rescan", "{}", {"Authorization": "Bearer nope", "Content-Type": "application/json"})
        self.assertEqual(conn.getresponse().status, 401)

    def test_rescan_with_a_wrong_admin_password_fails_and_can_retry(self):
        SCANS.clear()
        port = self.rescan_relay("wrong")
        phone = Client(port, "alice", "phone")
        self.clients.append(phone)
        self.assertEqual(phone.post("/rescan", {}), (502, {"scan": "failed"}))
        self.assertEqual(phone.post("/rescan", {}), (502, {"scan": "failed"}), "a failure doesn't count as a scan")
        self.assertEqual(SCANS, [])
        self.assertNotIn(PASSWORDS["admin"], self.log.getvalue())
        self.assertNotIn("wrong", self.log.getvalue())

    def test_secrets_never_reach_the_log(self):
        pc = self.client("alice", "pc")
        phone = self.client("alice", "phone")
        phone.post("/command", {"to": "pc", "cmd": "next"})
        pc.next("command")
        phone.close()
        pc.next("devices", lambda d: len(d) == 1)
        out = self.log.getvalue()
        self.assertIn("joined", out, "the log is being captured")
        for secret in (pc.session, phone.session, token("alice", "saltpc"), "saltpc", PASSWORDS["alice"]):
            self.assertNotIn(secret, out)


if __name__ == "__main__":
    unittest.main()
