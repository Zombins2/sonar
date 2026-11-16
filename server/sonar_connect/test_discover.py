"""Discover tests: real files and real beets databases (beets 2.11's own
schema, testdata/beets_schema.sql) in temp folders, against a fake Navidrome
admin API that behaves like the real one where it matters (checked on
Navidrome 0.64.2, docs/DISCOVER_PLAN.md step 0).

    python -m unittest -v test_discover      (from server/sonar_connect)
"""

from __future__ import annotations

import contextlib
import errno
import http.client
import io
import json
import os
import shutil
import sqlite3
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock
from urllib.parse import parse_qs, urlsplit

import discover
import relay
from test_relay import PASSWORDS, Client, FakeNavidrome, start, token

SCHEMA = os.path.join(os.path.dirname(__file__), "testdata", "beets_schema.sql")
discover.SCAN_POLL_SECONDS = 0.05
ADMIN_TOKEN = "jwt-for-the-admin"
COVER = b"\xff\xd8 a cover"


def song_bytes(name: str) -> bytes:
    return f"audio of {name}".encode()


class Navidrome:
    """The fake server's state, one per test."""

    def __init__(self, discover_dir: str, music_dir: str):
        self.discover_dir = discover_dir
        self.music_dir = music_dir
        self.libraries = [{"id": 1, "name": "Music Library", "path": "/music"}]
        self.users = {"u-admin": {"isAdmin": True, "libs": [1]}, "u-alice": {"isAdmin": False, "libs": [1]}}
        self.songs: dict[str, dict] = {}
        self.missing: set[str] = set()
        self.scans = 0
        self.last_scan = "never"
        self.scanning = False
        self.requests: list[str] = []

    def start_scan(self) -> None:
        """Like Navidrome, the scan runs after startScan has answered."""
        self.scanning = True

        def run():
            time.sleep(0.3)
            self.scan()
            self.scanning = False

        threading.Thread(target=run, daemon=True).start()

    def scan(self) -> None:
        """Like Navidrome: a Discover file now in the library folder is the same
        song in the main library (same id); a vanished file is missing."""
        self.scans += 1
        self.last_scan = f"scan {self.scans}"
        for song_id, s in self.songs.items():
            if s["libraryId"] != 2 or os.path.exists(os.path.join(self.discover_dir, s["path"])):
                continue
            if os.path.exists(os.path.join(self.music_dir, s["path"])):
                s["libraryId"] = 1
            else:
                self.missing.add(song_id)


def fake_navidrome(nd: Navidrome):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _reply(self, status: int, body=None):
            raw = json.dumps(body).encode() if body is not None else b""
            self.send_response(status)
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def _json(self):
            n = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(n)) if n else None

        def _admin(self) -> bool:
            return self.headers.get("X-ND-Authorization") == f"Bearer {ADMIN_TOKEN}"

        def _subsonic(self, q: dict) -> bool:
            return q.get("u") == "admin" and q.get("t") == token("admin", q.get("s", ""))

        def do_GET(self):  # noqa: N802
            url = urlsplit(self.path)
            q = {k: v[0] for k, v in parse_qs(url.query).items()}
            nd.requests.append(f"GET {url.path}")
            if url.path.startswith("/rest/"):
                if not self._subsonic(q):
                    return self._reply(200, {"subsonic-response": {"status": "failed"}})
                endpoint = url.path[len("/rest/") :].removesuffix(".view")
                if endpoint == "startScan" and not nd.scanning:
                    nd.start_scan()
                body = {"status": "ok", "scanStatus": {"scanning": nd.scanning, "lastScan": nd.last_scan}}
                return self._reply(200, {"subsonic-response": body})
            if not self._admin():
                return self._reply(401)
            if url.path == "/api/library":
                return self._reply(200, nd.libraries)
            if url.path == "/api/user":
                return self._reply(200, [{"id": k, "isAdmin": v["isAdmin"]} for k, v in nd.users.items()])
            if url.path.startswith("/api/user/") and url.path.endswith("/library"):
                user = nd.users[url.path.split("/")[3]]
                return self._reply(200, [l for l in nd.libraries if l["id"] in user["libs"]])
            if url.path.startswith("/api/song/"):
                s = nd.songs.get(url.path[len("/api/song/") :])
                return self._reply(200, s) if s else self._reply(404)
            if url.path == "/api/missing":
                return self._reply(200, [{"id": i, "title": nd.songs[i]["title"]} for i in sorted(nd.missing)])
            return self._reply(404)

        def do_POST(self):  # noqa: N802
            url = urlsplit(self.path)
            body = self._json()
            nd.requests.append(f"POST {url.path}")
            if url.path == "/auth/login":
                if body == {"username": "admin", "password": PASSWORDS["admin"]}:
                    return self._reply(200, {"token": ADMIN_TOKEN, "isAdmin": True})
                return self._reply(401)
            if not self._admin():
                return self._reply(401)
            if url.path == "/api/library":
                lib = {"id": len(nd.libraries) + 1, "name": body["name"], "path": body["path"]}
                nd.libraries.append(lib)
                return self._reply(200, {"id": str(lib["id"])})  # Navidrome answers the id as text.
            return self._reply(404)

        def do_PUT(self):  # noqa: N802
            url = urlsplit(self.path)
            body = self._json()
            nd.requests.append(f"PUT {url.path}")
            if not self._admin():
                return self._reply(401)
            ids = body.get("libraryIds")
            if not all(isinstance(i, int) for i in ids):
                return self._reply(400)  # Like Navidrome: numbers, not "2".
            nd.users[url.path.split("/")[3]]["libs"] = ids
            return self._reply(200, [l for l in nd.libraries if l["id"] in ids])

        def do_DELETE(self):  # noqa: N802
            url = urlsplit(self.path)
            q = {k: v[0] for k, v in parse_qs(url.query).items()}
            nd.requests.append(f"DELETE {url.path}")
            if not self._admin():
                return self._reply(401)
            if url.path == "/api/missing" and q.get("id") in nd.missing:
                nd.missing.discard(q["id"])
                del nd.songs[q["id"]]
                return self._reply(200, {"id": q["id"]})
            return self._reply(404)

    return Handler


class Beets:
    """A beets library database made with beets' own schema."""

    def __init__(self, folder: str):
        self.path = os.path.join(folder, discover.BEETS_DB)
        db = sqlite3.connect(self.path)
        with open(SCHEMA, encoding="utf-8") as f:
            db.executescript(f.read())
        db.close()

    def db(self):
        return sqlite3.connect(self.path)

    def album(self, artist: str, title: str, mb: str, root: str) -> int:
        with self.db() as db:
            cur = db.execute(
                "INSERT INTO albums (albumartist, album, mb_albumid, artpath) VALUES (?, ?, ?, ?)",
                (artist, title, mb, f"{artist}/{title}/cover.jpg".encode()),
            )
            db.execute("INSERT INTO album_attributes (entity_id, key, value) VALUES (?, 'data_source', 'MusicBrainz')", (cur.lastrowid,))
            return cur.lastrowid

    def item(self, rel: str, title: str, album_id, root: str) -> int:
        artist = rel.split("/")[0]
        with self.db() as db:
            cur = db.execute(
                "INSERT INTO items (path, title, artist, albumartist, album_id) VALUES (?, ?, ?, ?, ?)",
                (rel.encode(), title, artist, artist, album_id),
            )
            art = f"{root}/{os.path.dirname(rel)}/cover.jpg".encode()
            db.executemany(
                "INSERT INTO item_attributes (entity_id, key, value) VALUES (?, ?, ?)",
                [(cur.lastrowid, "artpath", art), (cur.lastrowid, "track_alt", "A2")],
            )
            return cur.lastrowid

    def rows(self, sql: str, args=()):
        db = self.db()
        try:
            return db.execute(sql, args).fetchall()
        finally:
            db.close()


class DiscoverTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sonar-discover-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.discover_dir = os.path.join(self.tmp, "discover")
        self.music_dir = os.path.join(self.tmp, "library", "Soulbeet")
        self.outside = os.path.join(self.tmp, "library")  # Navidrome's main library around it.
        self.state_dir = os.path.join(self.tmp, "state")
        for d in (self.discover_dir, self.music_dir):
            os.makedirs(d)
        self.nd = Navidrome(self.discover_dir, self.music_dir)
        server = ThreadingHTTPServer(("127.0.0.1", 0), fake_navidrome(self.nd))
        self.addCleanup(server.shutdown)
        self.url = f"http://127.0.0.1:{start(server)}"
        self.log = io.StringIO()
        redirect = contextlib.redirect_stderr(self.log)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)
        self.disc_beets = Beets(self.discover_dir)
        self.main_beets = Beets(self.music_dir)
        self.d = self.service()
        self.addCleanup(self.d.wait_idle)  # Before the fake server goes (cleanups run last-first).

    def service(self) -> discover.Discover:
        return discover.Discover(
            discover.NavidromeAdmin(self.url, "admin", PASSWORDS["admin"]),
            self.discover_dir,
            self.music_dir,
            self.state_dir,
        )

    def add_song(self, song_id: str, rel: str, title: str, album: tuple | None = None, library: int = 2) -> None:
        """A Discover song: its file and cover, its beets rows, and Navidrome's entry."""
        root = self.discover_dir if library == 2 else self.music_dir
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(song_bytes(title))
        with open(os.path.join(os.path.dirname(path), "cover.jpg"), "wb") as f:
            f.write(COVER)
        if library == 2:
            if album and album not in self.album_ids:
                self.album_ids[album] = self.disc_beets.album(*album, root="/music-discover")
            self.disc_beets.item(rel, title, self.album_ids.get(album), "/music-discover")
        self.nd.songs[song_id] = {"id": song_id, "libraryId": library, "path": rel, "title": title,
                                  "artist": rel.split("/")[0], "album": rel.split("/")[1]}

    def prepared(self):
        self.album_ids: dict = {}
        self.d.ensure_library()

    # ---- Navidrome's Discover library

    def test_makes_the_discover_library_and_gives_it_to_users_once(self):
        lib = self.d.ensure_library()
        self.assertEqual(self.nd.libraries[1], {"id": 2, "name": "Discover", "path": "/discover"})
        self.assertEqual(lib, 2)
        self.assertEqual(self.nd.users["u-alice"]["libs"], [1, 2])
        self.assertEqual(self.nd.users["u-admin"]["libs"], [1], "admins see every library already")
        puts = self.nd.requests.count("PUT /api/user/u-alice/library")
        self.service().ensure_library()  # The relay restarting.
        self.assertEqual(len(self.nd.libraries), 2, "no second Discover library")
        self.assertEqual(self.nd.requests.count("PUT /api/user/u-alice/library"), puts, "nothing to grant again")

    # ---- Keep

    def test_keep_moves_the_song_cover_and_beets_rows_into_the_library(self):
        self.prepared()
        self.add_song("s1", "Junior Murvin/Police and Thieves/02 Police and Thieves.flac", "Police and Thieves",
                      album=("Junior Murvin", "Police and Thieves", "mb-pat"))
        result = self.d.keep(["s1"])
        self.assertEqual(result, {"done": ["s1"], "failed": {}})
        rel = "Junior Murvin/Police and Thieves/02 Police and Thieves.flac"
        with open(os.path.join(self.music_dir, rel), "rb") as f:
            self.assertEqual(f.read(), song_bytes("Police and Thieves"))
        with open(os.path.join(self.music_dir, "Junior Murvin/Police and Thieves/cover.jpg"), "rb") as f:
            self.assertEqual(f.read(), COVER)
        self.assertEqual(os.listdir(self.discover_dir), [discover.BEETS_DB], "the emptied album folder is gone")
        # beets: the song and its album now belong to the library's database...
        (item_id, album_id), = self.main_beets.rows("SELECT id, album_id FROM items WHERE path = ?", (rel.encode(),))
        self.assertEqual(self.main_beets.rows("SELECT mb_albumid, artpath FROM albums WHERE id = ?", (album_id,)),
                         [("mb-pat", b"Junior Murvin/Police and Thieves/cover.jpg")])
        attrs = dict(self.main_beets.rows("SELECT key, value FROM item_attributes WHERE entity_id = ?", (item_id,)))
        self.assertEqual(attrs, {"artpath": b"/music/Junior Murvin/Police and Thieves/cover.jpg", "track_alt": "A2"})
        self.assertEqual(self.main_beets.rows("SELECT key FROM album_attributes WHERE entity_id = ?", (album_id,)),
                         [("data_source",)])
        # ...and are gone from Discover's.
        for table in ("items", "albums", "item_attributes", "album_attributes"):
            self.assertEqual(self.disc_beets.rows(f"SELECT count(*) FROM {table}"), [(0,)], table)
        # Navidrome rescans and sees the same song, now in the library.
        self.d.wait_idle()
        self.assertEqual(self.nd.scans, 1)
        self.assertEqual(self.nd.songs["s1"]["libraryId"], 1)
        self.assertEqual(self.nd.missing, set())

    def test_two_songs_of_one_album_share_one_album_in_the_library(self):
        self.prepared()
        album = ("Toots & The Maytals", "Funky Kingston", "mb-fk")
        self.add_song("s1", "Toots & The Maytals/Funky Kingston/01 Sit Right Down.flac", "Sit Right Down", album)
        self.add_song("s2", "Toots & The Maytals/Funky Kingston/05 Funky Kingston.flac", "Funky Kingston", album)
        self.d.keep(["s1"])
        # The other song stays in Discover, with its album row and cover.
        self.assertTrue(os.path.exists(os.path.join(self.discover_dir, "Toots & The Maytals/Funky Kingston/cover.jpg")))
        self.assertEqual(self.disc_beets.rows("SELECT count(*) FROM albums"), [(1,)])
        self.d.keep(["s2"])
        self.assertEqual(self.main_beets.rows("SELECT count(*) FROM albums"), [(1,)])
        self.assertEqual(self.main_beets.rows("SELECT count(DISTINCT album_id) FROM items"), [(1,)])
        self.assertEqual(self.disc_beets.rows("SELECT count(*) FROM albums"), [(0,)])

    @contextlib.contextmanager
    def across_mounts(self, deny_delete: str | None = None):
        """Like Docker: the two folders are separate mounts, so a rename can't
        cross (EXDEV) and the file is copied. [deny_delete] can't be deleted,
        as a root-owned file under a non-root Connect (seen on the live server)."""
        real_remove = os.remove

        def rename(src, dst):
            raise OSError(errno.EXDEV, "Invalid cross-device link")

        def remove(path):
            if deny_delete and os.path.abspath(path) == os.path.abspath(deny_delete):
                raise PermissionError(errno.EACCES, "Permission denied", path)
            real_remove(path)

        with mock.patch.object(discover.os, "rename", rename), mock.patch.object(discover.os, "remove", remove):
            yield

    def test_keep_across_mounts_copies_and_then_deletes_the_original(self):
        self.prepared()
        rel = "Jimmy Cliff/The Harder They Come/01 You Can Get It If You Really Want.flac"
        self.add_song("s1", rel, "You Can Get It If You Really Want")
        with self.across_mounts():
            self.assertEqual(self.d.keep(["s1"]), {"done": ["s1"], "failed": {}})
        with open(os.path.join(self.music_dir, rel), "rb") as f:
            self.assertEqual(f.read(), song_bytes("You Can Get It If You Really Want"))
        self.assertFalse(os.path.exists(os.path.join(self.discover_dir, rel)))
        leftovers = [f for _, _, fs in os.walk(self.music_dir) for f in fs if f.endswith(".sonar-part")]
        self.assertEqual(leftovers, [])

    def test_a_keep_that_cant_delete_the_original_leaves_no_copy(self):
        self.prepared()
        rel = "Steel Pulse/Handsworth Revolution/01 Handsworth Revolution.flac"
        self.add_song("s1", rel, "Handsworth Revolution", album=("Steel Pulse", "Handsworth Revolution", "mb-hr"))
        src = os.path.join(self.discover_dir, rel)
        with self.across_mounts(deny_delete=src):
            result = self.d.keep(["s1"])
        self.assertEqual(result, {"done": [], "failed": {"s1": "the server isn't allowed to move it"}})
        self.assertEqual(os.listdir(self.music_dir), [discover.BEETS_DB], "no copy, and no folders left behind")
        with open(src, "rb") as f:
            self.assertEqual(f.read(), song_bytes("Handsworth Revolution"))
        self.assertEqual(self.disc_beets.rows("SELECT count(*) FROM items"), [(1,)], "beets rows untouched")
        self.assertEqual(self.main_beets.rows("SELECT count(*) FROM items"), [(0,)])
        self.d.wait_idle()
        self.assertEqual(self.nd.scans, 0, "nothing changed, so no rescan")

    def test_keep_never_overwrites_a_file_in_the_library(self):
        self.prepared()
        rel = "Lecrae/Anomaly/01 Outsiders.flac"
        self.add_song("s1", rel, "Outsiders")
        os.makedirs(os.path.join(self.music_dir, "Lecrae/Anomaly"))
        with open(os.path.join(self.music_dir, rel), "wb") as f:
            f.write(b"the library's own copy")
        result = self.d.keep(["s1"])
        self.assertEqual(result["done"], [])
        self.assertIn("already has", result["failed"]["s1"])
        with open(os.path.join(self.music_dir, rel), "rb") as f:
            self.assertEqual(f.read(), b"the library's own copy")
        self.assertTrue(os.path.exists(os.path.join(self.discover_dir, rel)), "the Discover copy stays put")

    # ---- Remove

    def test_remove_deletes_the_song_remembers_it_and_clears_it_from_navidrome(self):
        self.prepared()
        self.add_song("s1", "Kabaka Pyramid/The Kalling/04 Red Gold and Green.flac", "Red Gold and Green",
                      album=("Kabaka Pyramid", "The Kalling", "mb-k"))
        result = self.d.remove(["s1"])
        self.assertEqual(result, {"done": ["s1"], "failed": {}})
        self.assertEqual(os.listdir(self.discover_dir), [discover.BEETS_DB])
        for table in ("items", "albums", "item_attributes", "album_attributes"):
            self.assertEqual(self.disc_beets.rows(f"SELECT count(*) FROM {table}"), [(0,)], table)
        self.d.wait_idle()
        self.assertNotIn("s1", self.nd.songs, "cleared from Navidrome's missing files after the scan")
        removed = self.service().status()["removed"]  # Survives a restart.
        self.assertEqual([(r["artist"], r["title"]) for r in removed], [("Kabaka Pyramid", "Red Gold and Green")])

    def test_removing_one_song_leaves_its_album_for_the_other(self):
        self.prepared()
        album = ("Sizzla", "Black Woman & Child", "mb-bwc")
        self.add_song("s1", "Sizzla/Black Woman & Child/01 Black Woman & Child.flac", "Black Woman & Child", album)
        self.add_song("s2", "Sizzla/Black Woman & Child/02 Princess Black.flac", "Princess Black", album)
        self.d.remove(["s1"])
        folder = os.path.join(self.discover_dir, "Sizzla/Black Woman & Child")
        self.assertEqual(sorted(os.listdir(folder)), ["02 Princess Black.flac", "cover.jpg"])
        self.assertEqual(self.disc_beets.rows("SELECT count(*) FROM albums"), [(1,)])
        self.assertEqual(self.disc_beets.rows("SELECT title FROM items"), [("Princess Black",)])

    def test_only_removed_songs_are_cleared_from_navidromes_missing_files(self):
        self.prepared()
        self.add_song("s1", "Anthony B/Untouchable/01 Rumours.flac", "Rumours")
        self.nd.songs["other"] = {"id": "other", "libraryId": 1, "path": "x.flac", "title": "Someone else's"}
        self.nd.missing.add("other")  # Missing for its own reasons: not ours to clear.
        self.d.remove(["s1"])
        self.d.wait_idle()
        self.assertEqual(self.nd.missing, {"other"})

    # ---- Refusals: nothing outside the Discover folder is touched

    def test_refuses_a_song_in_the_main_library(self):
        self.prepared()
        rel = "Bob Marley & The Wailers/Exodus/01 Natural Mystic.flac"
        self.add_song("lib", rel, "Natural Mystic", library=1)
        for action in (self.d.keep, self.d.remove):
            result = action(["lib"])
            self.assertEqual(result["failed"], {"lib": "it isn't a Discover song"})
        self.assertTrue(os.path.exists(os.path.join(self.music_dir, rel)))

    def test_refuses_paths_that_climb_out_of_the_discover_folder(self):
        self.prepared()
        victim = os.path.join(self.outside, "Precious", "song.flac")
        os.makedirs(os.path.dirname(victim))
        with open(victim, "wb") as f:
            f.write(b"keep me")
        for bad in ("../library/Precious/song.flac", "Artist/../../library/Precious/song.flac",
                    victim.replace("\\", "/"), "C:/x/song.flac", ""):
            self.nd.songs["evil"] = {"id": "evil", "libraryId": 2, "path": bad, "title": "x", "artist": "x"}
            result = self.d.remove(["evil"])
            self.assertEqual(result["failed"], {"evil": "its path is outside the Discover folder"}, bad)
            result = self.d.keep(["evil"])
            self.assertEqual(result["failed"], {"evil": "its path is outside the Discover folder"}, bad)
        with open(victim, "rb") as f:
            self.assertEqual(f.read(), b"keep me")

    def test_refuses_dot_dot_even_when_it_lands_back_inside(self):
        # The resolved-path check would pass this one: the plain-path check is
        # its own layer, and Navidrome never gives such a path for a real song.
        self.prepared()
        self.add_song("s1", "Anthony B/Untouchable/01 Rumours.flac", "Rumours")
        self.nd.songs["s1"]["path"] = "Anthony B/../Anthony B/Untouchable/01 Rumours.flac"
        self.assertEqual(self.d.remove(["s1"])["failed"], {"s1": "its path is outside the Discover folder"})
        self.assertTrue(os.path.exists(os.path.join(self.discover_dir, "Anthony B/Untouchable/01 Rumours.flac")))

    def test_refuses_a_link_out_of_the_discover_folder(self):
        self.prepared()
        victim_dir = os.path.join(self.outside, "Precious")
        os.makedirs(victim_dir)
        with open(os.path.join(victim_dir, "song.flac"), "wb") as f:
            f.write(b"keep me")
        try:
            os.symlink(victim_dir, os.path.join(self.discover_dir, "Linked"), target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest("this system won't make symlinks for a normal user")
        self.nd.songs["link"] = {"id": "link", "libraryId": 2, "path": "Linked/song.flac", "title": "x", "artist": "x"}
        self.assertEqual(self.d.remove(["link"])["failed"], {"link": "its path is outside the Discover folder"})
        self.assertTrue(os.path.exists(os.path.join(victim_dir, "song.flac")))

    def test_an_unknown_song_is_refused_and_the_rest_still_go(self):
        self.prepared()
        self.add_song("s1", "Tarrus Riley/Parables/01 She's Royal.flac", "She's Royal")
        result = self.d.remove(["nope", "s1"])
        self.assertEqual(result["done"], ["s1"])
        self.assertEqual(result["failed"], {"nope": "Navidrome doesn't know this song"})

    # ---- Secrets

    def test_the_admin_password_and_token_never_reach_the_log(self):
        self.prepared()
        self.add_song("s1", "Lutan Fyah/Africa/01 Africa.flac", "Africa")
        self.d.keep(["s1"])
        self.d.wait_idle()
        out = self.log.getvalue()
        self.assertIn("discover: kept 1", out, "the log is being captured")
        for secret in (PASSWORDS["admin"], ADMIN_TOKEN):
            self.assertNotIn(secret, out)


class DiscoverEndpointsTest(unittest.TestCase):
    """Through the relay: a session is needed, and off means 503."""

    def setUp(self):
        self.log = io.StringIO()
        redirect = contextlib.redirect_stderr(self.log)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)
        navidrome = ThreadingHTTPServer(("127.0.0.1", 0), FakeNavidrome)
        self.addCleanup(navidrome.shutdown)
        self.navidrome_url = f"http://127.0.0.1:{start(navidrome)}"

    def relay_with(self, d) -> int:
        server = relay.serve(0, self.navidrome_url, host="127.0.0.1", discover=d)
        self.addCleanup(server.shutdown)
        return start(server)

    def get(self, port: int, path: str, session: str | None):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        conn.request("GET", path, headers={"Authorization": f"Bearer {session}"} if session else {})
        r = conn.getresponse()
        data = r.read()
        return r.status, (json.loads(data) if data else {})

    def test_off_without_discover(self):
        port = self.relay_with(None)
        app = Client(port, "alice", "phone")
        self.assertEqual(self.get(port, "/discover", app.session), (503, {"discover": "off"}))
        self.assertEqual(app.post("/discover/keep", {"songs": ["s1"]}), (503, {"discover": "off"}))
        app.close()

    def test_needs_a_session_and_a_proper_song_list(self):
        calls = []

        class Recording:
            def status(self):
                return {"library": 2, "removed": []}

            def keep(self, songs):
                calls.append(("keep", songs))
                return {"done": songs, "failed": {}}

            def remove(self, songs):
                calls.append(("remove", songs))
                return {"done": songs, "failed": {}}

        port = self.relay_with(Recording())
        self.assertEqual(self.get(port, "/discover", None)[0], 401)
        self.assertEqual(self.get(port, "/sonar-connect/discover", "nope")[0], 401)
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        conn.request("POST", "/discover/remove", json.dumps({"songs": ["s1"]}),
                     {"Authorization": "Bearer nope", "Content-Type": "application/json"})
        self.assertEqual(conn.getresponse().status, 401)
        self.assertEqual(calls, [], "nothing reached Discover without a session")
        app = Client(port, "alice", "phone")
        self.addCleanup(app.close)
        self.assertEqual(self.get(port, "/sonar-connect/discover", app.session), (200, {"library": 2, "removed": []}))
        for bad in ({}, {"songs": []}, {"songs": "s1"}, {"songs": [1]}, {"songs": ["x" * 65]},
                    {"songs": [f"s{i}" for i in range(discover.MAX_SONGS + 1)]}):
            self.assertEqual(app.post("/discover/keep", bad)[0], 400, bad)
        self.assertEqual(app.post("/discover/remove", {"songs": ["s1", "s1", "s2"]}),
                         (200, {"done": ["s1", "s2"], "failed": {}}))
        self.assertEqual(calls, [("remove", ["s1", "s2"])])


if __name__ == "__main__":
    unittest.main()
