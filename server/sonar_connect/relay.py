"""Sonar Connect relay: lets one account's Sonar apps see and control each other.

Python standard library only. Plain HTTP both ways:

  POST /hello    {u, t, s, device: {id, name, kind}}  -> {session}
  GET  /events   Bearer session -> Server-Sent Events: `devices` (everyone, on
                 join/leave), `state` (another device's changes), `command`
  POST /state    Bearer session, changes to this device's player state
  POST /command  Bearer session, {to, cmd, ...} for a device on the same account
  POST /rescan   Bearer session -> asks Navidrome to scan for new music (an album
                 Soulbeet just filed). Needs an admin login, NAVIDROME_ADMIN_USER
                 and NAVIDROME_ADMIN_PASSWORD; 503 without them. At most one
                 scan per SCAN_GAP_SECONDS; the rest are answered as started.

Logins are checked with Navidrome's `ping` using the app's own token (t, s),
which arrive in the request body, never the URL. Tokens, salts and sessions
are never logged. See docs/CONNECT_PLAN.md.
"""

from __future__ import annotations

import hashlib
import json
import os
import queue
import secrets
import select
import socket
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 2 * 1024 * 1024
MAX_DEVICES = 8
HEARTBEAT_SECONDS = 15.0
# A device that has posted nothing for this long has dropped off the network
# without hanging up (a phone losing signal); it leaves the list.
SILENT_SECONDS = 60.0
# A session must open its event stream this soon after hello.
UNCLAIMED_SECONDS = 30.0
PREFIX = "/sonar-connect"
SCAN_GAP_SECONDS = 10.0
_CLOSE = object()


def log(message: str) -> None:
    print(time.strftime("%Y-%m-%d %H:%M:%S"), message, file=sys.stderr, flush=True)


class Device:
    def __init__(self, account: str, device_id: str, name: str, kind: str, session: str):
        self.account = account
        self.id = device_id
        self.name = name
        self.kind = kind
        self.session = session
        self.state: dict | None = None
        self.outbox: queue.Queue = queue.Queue()
        self.streaming = False
        self.created = time.monotonic()
        # Any request from the app; apps post their state every 15 s.
        self.last_seen = self.created

    def public(self) -> dict:
        return {"id": self.id, "name": self.name, "kind": self.kind, "state": self.state}


class Hub:
    """Every connected device, grouped by account. All access holds the lock."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._sessions: dict[str, Device] = {}

    def _account(self, account: str) -> list[Device]:
        return [d for d in self._sessions.values() if d.account == account]

    def _broadcast(self, account: str) -> None:
        devices = self._account(account)
        payload = [d.public() for d in devices]
        for d in devices:
            d.outbox.put(("devices", payload))

    def _expire_unclaimed(self) -> None:
        now = time.monotonic()
        for key, d in list(self._sessions.items()):
            if not d.streaming and now - d.created > UNCLAIMED_SECONDS:
                del self._sessions[key]

    def join(self, account: str, device: dict) -> str | None:
        """A new session for this device, replacing any older one."""
        device_id = str(device.get("id") or "")[:64]
        if not device_id:
            return None
        with self._lock:
            self._expire_unclaimed()
            for key, d in list(self._sessions.items()):
                if d.account == account and d.id == device_id:
                    d.outbox.put(_CLOSE)
                    del self._sessions[key]
            if len(self._account(account)) >= MAX_DEVICES:
                return None
            session = secrets.token_urlsafe(32)
            self._sessions[session] = Device(
                account,
                device_id,
                str(device.get("name") or "Device")[:64],
                str(device.get("kind") or "other")[:16],
                session,
            )
            return session

    def device(self, session: str) -> Device | None:
        with self._lock:
            return self._sessions.get(session)

    def start_stream(self, session: str) -> Device | None:
        with self._lock:
            d = self._sessions.get(session)
            if d is None or d.streaming:
                return None
            d.streaming = True
            self._broadcast(d.account)
            return d

    def leave(self, device: Device) -> None:
        with self._lock:
            if self._sessions.get(device.session) is device:
                del self._sessions[device.session]
                self._broadcast(device.account)

    def set_state(self, device: Device, patch: dict) -> None:
        """Merges [patch] into the device's state (apps send only what
        changed: the queue rarely, the position often) and passes the patch to
        the account's other devices."""
        with self._lock:
            if self._sessions.get(device.session) is not device:
                return
            device.state = {**(device.state or {}), **patch}
            for d in self._account(device.account):
                if d is not device:
                    d.outbox.put(("state", {"id": device.id, "state": patch}))

    def command(self, sender: Device, body: dict) -> bool:
        target_id = body.get("to")
        with self._lock:
            for d in self._account(sender.account):
                if d.id == target_id and d is not sender and d.streaming:
                    d.outbox.put(("command", {**body, "from": sender.id}))
                    return True
        return False


def make_checker(navidrome_url: str):
    """Returns check(u, t, s) -> bool, asking Navidrome's ping."""

    def check(u: str, t: str, s: str) -> bool:
        query = urllib.parse.urlencode({"u": u, "t": t, "s": s, "v": "1.16.1", "c": "sonar-connect", "f": "json"})
        try:
            with urllib.request.urlopen(f"{navidrome_url}/rest/ping.view?{query}", timeout=10) as r:
                data = json.load(r)
            return data.get("subsonic-response", {}).get("status") == "ok"
        except Exception as e:  # noqa: BLE001 - any failure is a refusal
            log(f"login check failed: {type(e).__name__}")
            return False

    return check


def make_scanner(navidrome_url: str, admin_user: str, admin_password: str):
    """Returns scan() -> "started" | "recent" | "failed" | "off", starting a
    Navidrome scan as the admin. The admin password only ever leaves here as
    a one-time token (md5 of password + salt), on the Docker network."""
    lock = threading.Lock()
    last = [float("-inf")]

    def scan() -> str:
        if not (admin_user and admin_password):
            return "off"
        with lock:
            now = time.monotonic()
            if now - last[0] < SCAN_GAP_SECONDS:
                return "recent"
            last[0] = now
        salt = secrets.token_hex(8)
        token = hashlib.md5((admin_password + salt).encode()).hexdigest()
        query = urllib.parse.urlencode(
            {"u": admin_user, "t": token, "s": salt, "v": "1.16.1", "c": "sonar-connect", "f": "json"}
        )
        try:
            with urllib.request.urlopen(f"{navidrome_url}/rest/startScan.view?{query}", timeout=10) as r:
                data = json.load(r)
            ok = data.get("subsonic-response", {}).get("status") == "ok"
        except Exception as e:  # noqa: BLE001 - any failure means no scan
            log(f"rescan failed: {type(e).__name__}")
            ok = False
        if not ok:
            with lock:
                last[0] = float("-inf")  # Let the next try go through.
            log("rescan refused by Navidrome (is the admin login right?)")
            return "failed"
        log("rescan started")
        return "started"

    return scan


def make_handler(hub: Hub, check, scan=lambda: "off"):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "SonarConnect/1"

        def log_message(self, format, *args):  # noqa: A002 - BaseHTTPRequestHandler's name
            pass  # Requests are not logged: nothing here is useful and headers carry sessions.

        # --- helpers
        def _path(self) -> str:
            path = urllib.parse.urlsplit(self.path).path
            if path.startswith(PREFIX):
                path = path[len(PREFIX) :] or "/"
            return path

        def _send(self, status: int, body: dict | None = None) -> None:
            raw = json.dumps(body or {}).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(raw)

        def _body(self) -> dict | None:
            try:
                length = int(self.headers.get("Content-Length") or "0")
            except ValueError:
                return None
            if length <= 0 or length > MAX_BODY:
                return None
            try:
                body = json.loads(self.rfile.read(length))
            except (ValueError, UnicodeDecodeError):
                return None
            return body if isinstance(body, dict) else None

        def _device(self) -> Device | None:
            auth = self.headers.get("Authorization") or ""
            if not auth.startswith("Bearer "):
                return None
            device = hub.device(auth[len("Bearer ") :].strip())
            if device is not None:
                device.last_seen = time.monotonic()
            return device

        def _peer_closed(self) -> bool:
            """The app hung up. It sends nothing on this connection after the
            request, so anything readable means end of stream."""
            try:
                readable, _, _ = select.select([self.connection], [], [], 0)
                return bool(readable) and self.connection.recv(1, socket.MSG_PEEK) == b""
            except OSError:
                return True

        # --- routes
        def do_GET(self) -> None:  # noqa: N802
            path = self._path()
            if path == "/health":
                return self._send(200, {"ok": True})
            if path != "/events":
                return self._send(404)
            device = self._device()
            device = device and hub.start_stream(device.session)
            if device is None:
                return self._send(401)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Accel-Buffering", "no")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            log(f"{device.kind} joined")
            last_write = time.monotonic()
            try:
                while True:
                    try:
                        item = device.outbox.get(timeout=1)
                    except queue.Empty:
                        now = time.monotonic()
                        if self._peer_closed() or now - device.last_seen > SILENT_SECONDS:
                            break
                        if now - last_write >= HEARTBEAT_SECONDS:
                            self.wfile.write(b": keep-alive\n\n")
                            self.wfile.flush()
                            last_write = now
                        continue
                    if item is _CLOSE:
                        break
                    event, data = item
                    self.wfile.write(f"event: {event}\ndata: {json.dumps(data)}\n\n".encode())
                    self.wfile.flush()
                    last_write = time.monotonic()
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                pass
            finally:
                hub.leave(device)
                log(f"{device.kind} left")

        def do_POST(self) -> None:  # noqa: N802
            path = self._path()
            body = self._body()
            if body is None:
                return self._send(400)
            if path == "/hello":
                u, t, s = (str(body.get(k) or "") for k in ("u", "t", "s"))
                device = body.get("device")
                if not (u and t and s and isinstance(device, dict)) or not check(u, t, s):
                    time.sleep(1)  # Slows guessing.
                    return self._send(401)
                session = hub.join(u.lower(), device)
                if session is None:
                    return self._send(409)
                return self._send(200, {"session": session})
            device = self._device()
            if device is None:
                return self._send(401)
            if path == "/state":
                hub.set_state(device, body)
                return self._send(200)
            if path == "/command":
                return self._send(200 if hub.command(device, body) else 404)
            if path == "/rescan":
                result = scan()
                status = {"started": 200, "recent": 200, "failed": 502, "off": 503}[result]
                return self._send(status, {"scan": result})
            return self._send(404)

    return Handler


def serve(
    port: int, navidrome_url: str, host: str = "0.0.0.0", admin_user: str = "", admin_password: str = ""
) -> ThreadingHTTPServer:
    scan = make_scanner(navidrome_url, admin_user, admin_password)
    server = ThreadingHTTPServer((host, port), make_handler(Hub(), make_checker(navidrome_url), scan))
    server.daemon_threads = True
    return server


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "4534"))
    host = os.environ.get("HOST", "0.0.0.0")  # In Docker; tests use 127.0.0.1.
    navidrome = os.environ.get("NAVIDROME_URL", "http://navidrome:4533").rstrip("/")
    admin_user = os.environ.get("NAVIDROME_ADMIN_USER", "")
    admin_password = os.environ.get("NAVIDROME_ADMIN_PASSWORD", "")
    log(f"Sonar Connect on {host}:{port}, checking logins with {navidrome}")
    log("rescan " + ("on" if admin_user and admin_password else "off (no NAVIDROME_ADMIN_USER / PASSWORD)"))
    serve(port, navidrome, host=host, admin_user=admin_user, admin_password=admin_password).serve_forever()
