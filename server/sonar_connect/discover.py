"""Discover: songs Sonar downloaded for you to try, kept or removed on request.

Soulbeet downloads Discover songs into their own folder, which Navidrome shows
as a separate library ("Discover"). This module does what neither the app nor
Navidrome can: moving a kept song into the library Soulbeet files into, and
deleting a removed one. See docs/DISCOVER_PLAN.md.

Safety, each covered by a test:
- The app sends Navidrome song ids, never paths. The path comes from
  Navidrome's admin API, and the song must be in the Discover library.
- Nothing outside the Discover folder is ever deleted or moved, after
  resolving links and "..". A kept song never overwrites a file in the library.
- Songs are moved with their beets rows (Soulbeet keeps one beets database per
  folder), so beets and Soulbeet still know where everything is.

Standard library only, like relay.py.
"""

from __future__ import annotations

import contextlib
import errno
import hashlib
import json
import os
import queue
import secrets
import shutil
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

BEETS_DB = ".beets_library.db"
AUDIO = {".aac", ".aif", ".aiff", ".alac", ".ape", ".dsf", ".flac", ".m4a", ".mp3", ".ogg", ".opus", ".wav", ".wma", ".wv"}
MAX_SONGS = 100
MAX_REMOVED = 5000
SCAN_TIMEOUT_SECONDS = 600.0
SCAN_POLL_SECONDS = 1.0
LIBRARY_NAME = "Discover"


def log(message: str) -> None:
    print(time.strftime("%Y-%m-%d %H:%M:%S"), message, file=sys.stderr, flush=True)


class Refused(Exception):
    """A song this module won't touch, with the reason the app shows."""


# ---- Navidrome, as the admin ---------------------------------------------------


class NavidromeAdmin:
    """Navidrome's admin API (logged in once, again when the login lapses) and
    the Subsonic scan calls. The password only ever leaves here to Navidrome's
    own login, or as a one-time Subsonic token."""

    def __init__(self, url: str, user: str, password: str):
        self.url = url.rstrip("/")
        self.user = user
        self._password = password
        self._token: str | None = None
        self._lock = threading.Lock()

    def _login(self) -> str:
        body = json.dumps({"username": self.user, "password": self._password}).encode()
        req = urllib.request.Request(
            f"{self.url}/auth/login", data=body, method="POST", headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=20) as r:
            reply = json.load(r)
        if not reply.get("isAdmin"):
            raise Refused("the Navidrome login in NAVIDROME_ADMIN_USER isn't an admin")
        return reply["token"]

    def api(self, method: str, path: str, body=None):
        """(status, parsed reply) from the admin API."""
        for attempt in (1, 2):
            with self._lock:
                if self._token is None:
                    self._token = self._login()
                token = self._token
            data = json.dumps(body).encode() if body is not None else None
            req = urllib.request.Request(f"{self.url}{path}", data=data, method=method)
            req.add_header("Content-Type", "application/json")
            req.add_header("X-ND-Authorization", f"Bearer {token}")
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    raw = r.read()
                    return r.status, (json.loads(raw) if raw.strip() else None)
            except urllib.error.HTTPError as e:
                if e.code == 401 and attempt == 1:
                    with self._lock:
                        self._token = None  # Expired: log in again.
                    continue
                return e.code, None
        return 401, None

    def subsonic(self, endpoint: str, **params) -> dict:
        salt = secrets.token_hex(8)
        token = hashlib.md5((self._password + salt).encode()).hexdigest()
        query = {"u": self.user, "t": token, "s": salt, "v": "1.16.1", "c": "sonar-connect", "f": "json", **params}
        with urllib.request.urlopen(f"{self.url}/rest/{endpoint}?{urllib.parse.urlencode(query)}", timeout=20) as r:
            return json.load(r).get("subsonic-response", {})

    def scan_and_wait(self, timeout: float = SCAN_TIMEOUT_SECONDS) -> bool:
        """Starts a scan once any running one has finished, and waits for it."""
        end = time.monotonic() + timeout
        status = self.subsonic("getScanStatus").get("scanStatus", {})
        while status.get("scanning") and time.monotonic() < end:
            time.sleep(SCAN_POLL_SECONDS)
            status = self.subsonic("getScanStatus").get("scanStatus", {})
        before = status.get("lastScan")
        if self.subsonic("startScan").get("status") != "ok":
            return False
        while time.monotonic() < end:
            status = self.subsonic("getScanStatus").get("scanStatus", {})
            if not status.get("scanning") and status.get("lastScan") != before:
                return True
            time.sleep(SCAN_POLL_SECONDS)
        return False


# ---- Files ----------------------------------------------------------------------


def _inside(root: str, path: str) -> bool:
    """Whether [path], links and ".." resolved, is strictly inside [root]."""
    real_root = os.path.realpath(root)
    real = os.path.realpath(path)
    try:
        return real != real_root and os.path.commonpath([real_root, real]) == real_root
    except ValueError:  # Another drive.
        return False


def _relative(path: str) -> str:
    """Navidrome's library-relative path, checked to be a plain relative one."""
    rel = path.replace("\\", "/")
    parts = rel.split("/")
    if not rel or rel.startswith("/") or ":" in parts[0] or any(p in ("", ".", "..") for p in parts):
        raise Refused("its path is outside the Discover folder")
    return rel


def _move(src: str, dst: str) -> None:
    """Moves a file into a new place, possibly on another mount, leaving
    nothing behind if it can't: a copy is only kept once the original is gone.
    The folders it had to make go again too."""
    made = []
    folder = os.path.dirname(dst)
    while not os.path.isdir(folder):
        made.append(folder)
        folder = os.path.dirname(folder)
    try:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        try:
            os.rename(src, dst)  # Same mount: one step.
            return
        except OSError as e:
            if e.errno != errno.EXDEV:
                raise
        part = dst + ".sonar-part"
        shutil.copy2(src, part)
        try:
            os.replace(part, dst)
        except OSError:
            os.remove(part)
            raise
        try:
            os.remove(src)
        except OSError:
            os.remove(dst)  # The original stays: no second copy.
            raise
    except OSError:
        for d in made:  # Deepest first.
            with contextlib.suppress(OSError):
                os.rmdir(d)
        raise


def _tidy(root: str, folder: str) -> None:
    """Removes [folder] once no song is left in it (covers and other extras go
    with it), then any parents left empty, stopping at [root]."""
    if not _inside(root, folder) or not os.path.isdir(folder):
        return
    entries = os.listdir(folder)
    has_song = any(os.path.splitext(e)[1].lower() in AUDIO for e in entries)
    has_dir = any(os.path.isdir(os.path.join(folder, e)) for e in entries)
    if has_song or has_dir:
        return
    shutil.rmtree(folder)
    parent = os.path.dirname(folder)
    while _inside(root, parent) and not os.listdir(parent):
        os.rmdir(parent)
        parent = os.path.dirname(parent)


# ---- beets ------------------------------------------------------------------------


def _columns(db: sqlite3.Connection, schema: str, table: str) -> list[str]:
    return [r[1] for r in db.execute(f"PRAGMA {schema}.table_info({table})") if r[1] != "id"]


def _rewrite(value, old: str, new: str):
    """An absolute path flexible attribute (beets keeps `artpath` as one) moved
    from the Discover folder to the library, as Soulbeet sees them."""
    old_b, new_b = old.rstrip("/").encode() + b"/", new.rstrip("/").encode() + b"/"
    if isinstance(value, bytes) and value.startswith(old_b):
        return new_b + value[len(old_b) :]
    if isinstance(value, str) and value.startswith(old_b.decode()):
        return new_b.decode() + value[len(old_b) :]
    return value


def _copy_row(db, table: str, row_id: int, extra: dict | None = None) -> int:
    """Copies src.<table> row [row_id] into main.<table>; columns by name, as
    two libraries' tables can have them in different orders."""
    src_cols = set(_columns(db, "src", table))
    cols = [c for c in _columns(db, "main", table) if c in src_cols and c not in (extra or {})]
    names = ", ".join(f'"{c}"' for c in [*cols, *(extra or {})])
    marks = ", ".join(["?"] * len(extra or {}))
    picked = ", ".join([*(f'"{c}"' for c in cols), *([marks] if marks else [])])
    cur = db.execute(
        f"INSERT INTO main.{table} ({names}) SELECT {picked} FROM src.{table} WHERE id = ?",
        (*(extra or {}).values(), row_id),
    )
    return cur.lastrowid


def _copy_attributes(db, table: str, old_id: int, new_id: int, old: str, new: str) -> None:
    for key, value in db.execute(f"SELECT key, value FROM src.{table} WHERE entity_id = ?", (old_id,)).fetchall():
        db.execute(
            f"INSERT INTO main.{table} (entity_id, key, value) VALUES (?, ?, ?)", (new_id, key, _rewrite(value, old, new))
        )


def _drop(db, schema: str, item_id: int, album_id) -> None:
    db.execute(f"DELETE FROM {schema}.item_attributes WHERE entity_id = ?", (item_id,))
    db.execute(f"DELETE FROM {schema}.items WHERE id = ?", (item_id,))
    if album_id is not None and not db.execute(
        f"SELECT 1 FROM {schema}.items WHERE album_id = ? LIMIT 1", (album_id,)
    ).fetchone():
        db.execute(f"DELETE FROM {schema}.album_attributes WHERE entity_id = ?", (album_id,))
        db.execute(f"DELETE FROM {schema}.albums WHERE id = ?", (album_id,))


def beets_keep(src_db: str, dst_db: str, rel: str, src_prefix: str, dst_prefix: str) -> str:
    """Moves a song's beets rows (and its album's, shared if the library has
    that album already) from the Discover library to the main one. beets keeps
    paths relative to the library folder, so the path itself doesn't change."""
    if not os.path.exists(src_db):
        return "no beets row"
    if not os.path.exists(dst_db):
        beets_drop(src_db, rel)
        return "the library has no beets database yet"
    db = sqlite3.connect(dst_db, timeout=30)
    try:
        db.execute("ATTACH ? AS src", (src_db,))
        row = db.execute("SELECT id, album_id FROM src.items WHERE path = ?", (rel.encode(),)).fetchone()
        if row is None:
            return "no beets row"
        item_id, album_id = row
        with db:
            new_album = None
            if album_id is not None:
                mb, artist, title = db.execute(
                    "SELECT mb_albumid, albumartist, album FROM src.albums WHERE id = ?", (album_id,)
                ).fetchone()
                found = (
                    db.execute("SELECT id FROM main.albums WHERE mb_albumid = ?", (mb,)).fetchone()
                    if mb
                    else db.execute(
                        "SELECT id FROM main.albums WHERE albumartist = ? AND album = ?", (artist, title)
                    ).fetchone()
                )
                if found:
                    new_album = found[0]
                else:
                    new_album = _copy_row(db, "albums", album_id)
                    _copy_attributes(db, "album_attributes", album_id, new_album, src_prefix, dst_prefix)
            new_item = _copy_row(db, "items", item_id, {"album_id": new_album})
            _copy_attributes(db, "item_attributes", item_id, new_item, src_prefix, dst_prefix)
            _drop(db, "src", item_id, album_id)
        return "moved"
    finally:
        db.close()


def beets_drop(db_path: str, rel: str) -> str:
    if not os.path.exists(db_path):
        return "no beets row"
    db = sqlite3.connect(db_path, timeout=30)
    try:
        row = db.execute("SELECT id, album_id FROM items WHERE path = ?", (rel.encode(),)).fetchone()
        if row is None:
            return "no beets row"
        with db:
            _drop(db, "main", *row)
        return "dropped"
    finally:
        db.close()


# ---- The service --------------------------------------------------------------------


class Discover:
    """Keep / remove for Discover songs, plus the list of removed songs (so
    they aren't suggested again), kept in [state_dir]."""

    def __init__(
        self,
        navidrome: NavidromeAdmin,
        discover_dir: str,
        music_dir: str,
        state_dir: str,
        navidrome_path: str = "/discover",
        soulbeet_discover: str = "/music-discover",
        soulbeet_music: str = "/music",
    ):
        self.nav = navidrome
        self.discover_dir = discover_dir
        self.music_dir = music_dir
        self.state_path = os.path.join(state_dir, "discover.json")
        self.navidrome_path = navidrome_path
        self.soulbeet_discover = soulbeet_discover
        self.soulbeet_music = soulbeet_music
        self.library_id: int | None = None
        self._lock = threading.Lock()  # One keep / remove at a time.
        self._jobs: queue.Queue = queue.Queue()
        threading.Thread(target=self._worker, daemon=True).start()

    # -- Navidrome's Discover library

    def ensure_library(self) -> int:
        """Finds (or creates) the Discover library and gives every non-admin
        user access to it. Safe to call again: it only adds what's missing."""
        status, libraries = self.nav.api("GET", "/api/library")
        if status != 200 or not isinstance(libraries, list):
            raise Refused(f"Navidrome didn't list its libraries ({status})")
        lib = next((l for l in libraries if l.get("path") == self.navidrome_path), None)
        if lib is None:
            status, lib = self.nav.api("POST", "/api/library", {"name": LIBRARY_NAME, "path": self.navidrome_path})
            if status not in (200, 201) or not isinstance(lib, dict):
                raise Refused(f"Navidrome didn't create the Discover library ({status})")
            log("discover: created the Discover library in Navidrome")
        lib_id = int(lib["id"])
        status, users = self.nav.api("GET", "/api/user")
        for user in users if status == 200 and isinstance(users, list) else []:
            if user.get("isAdmin"):
                continue  # Admins see every library.
            status, has = self.nav.api("GET", f"/api/user/{user['id']}/library")
            ids = sorted({int(l["id"]) for l in has or []})
            if status == 200 and lib_id not in ids:
                status, _ = self.nav.api("PUT", f"/api/user/{user['id']}/library", {"libraryIds": [*ids, lib_id]})
                log("discover: gave a user the Discover library" if status == 200 else f"discover: grant failed ({status})")
        self.library_id = lib_id
        return lib_id

    # -- Removed songs

    def _load(self) -> dict:
        try:
            with open(self.state_path, encoding="utf-8") as f:
                state = json.load(f)
            return state if isinstance(state, dict) else {}
        except (OSError, ValueError):
            return {}

    def _remember_removed(self, songs: list[dict]) -> None:
        state = self._load()
        removed = [*state.get("removed", []), *songs][-MAX_REMOVED:]
        tmp = self.state_path + ".tmp"
        os.makedirs(os.path.dirname(self.state_path), exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({**state, "removed": removed}, f)
        os.replace(tmp, self.state_path)

    def status(self) -> dict:
        if self.library_id is None:
            self.ensure_library()
        return {"library": self.library_id, "removed": self._load().get("removed", [])}

    # -- Keep / remove

    def _song(self, song_id: str) -> tuple[str, dict]:
        status, song = self.nav.api("GET", f"/api/song/{urllib.parse.quote(song_id, safe='')}")
        if status != 200 or not isinstance(song, dict):
            raise Refused("Navidrome doesn't know this song")
        if self.library_id is None:
            self.ensure_library()
        if song.get("libraryId") != self.library_id:
            raise Refused("it isn't a Discover song")
        rel = _relative(str(song.get("path") or ""))
        src = os.path.join(self.discover_dir, rel)
        if not _inside(self.discover_dir, src):
            raise Refused("its path is outside the Discover folder")
        if not os.path.isfile(src):
            raise Refused("its file is gone")
        return rel, song

    def keep(self, song_ids: list[str]) -> dict:
        done, failed = [], {}
        with self._lock:
            for song_id in song_ids:
                try:
                    rel, _ = self._song(song_id)
                    src = os.path.join(self.discover_dir, rel)
                    dst = os.path.join(self.music_dir, rel)
                    if not _inside(self.music_dir, dst):
                        raise Refused("its path is outside the library")
                    if os.path.lexists(dst):
                        raise Refused("your library already has a file there")
                    _move(src, dst)
                    folder = os.path.dirname(src)
                    for extra in os.listdir(folder):  # The album's cover, for the library's copy.
                        here, there = os.path.join(folder, extra), os.path.join(os.path.dirname(dst), extra)
                        if os.path.splitext(extra)[1].lower() in (".jpg", ".jpeg", ".png", ".webp") and not os.path.lexists(there):
                            shutil.copy2(here, there)
                    beets = beets_keep(
                        os.path.join(self.discover_dir, BEETS_DB),
                        os.path.join(self.music_dir, BEETS_DB),
                        rel,
                        self.soulbeet_discover,
                        self.soulbeet_music,
                    )
                    if beets != "moved":
                        log(f"discover: kept a song ({beets})")
                    _tidy(self.discover_dir, folder)
                    done.append(song_id)
                except Refused as e:
                    failed[song_id] = str(e)
                except PermissionError:
                    log("discover: keep failed: Sonar Connect isn't allowed to change files in the Discover or library folder")
                    failed[song_id] = "the server isn't allowed to move it"
                except OSError as e:
                    log(f"discover: keep failed: {type(e).__name__}")
                    failed[song_id] = "the server couldn't move it"
        if done:
            self._jobs.put([])
        log(f"discover: kept {len(done)}, refused {len(failed)}")
        return {"done": done, "failed": failed}

    def remove(self, song_ids: list[str]) -> dict:
        done, failed, gone = [], {}, []
        with self._lock:
            for song_id in song_ids:
                try:
                    rel, song = self._song(song_id)
                    src = os.path.join(self.discover_dir, rel)
                    os.remove(src)
                    beets_drop(os.path.join(self.discover_dir, BEETS_DB), rel)
                    _tidy(self.discover_dir, os.path.dirname(src))
                    gone.append(
                        {
                            "artist": song.get("artist") or "",
                            "title": song.get("title") or "",
                            "album": song.get("album") or "",
                            "at": int(time.time()),
                        }
                    )
                    done.append(song_id)
                except Refused as e:
                    failed[song_id] = str(e)
                except PermissionError:
                    log("discover: remove failed: Sonar Connect isn't allowed to change files in the Discover folder")
                    failed[song_id] = "the server isn't allowed to delete it"
                except OSError as e:
                    log(f"discover: remove failed: {type(e).__name__}")
                    failed[song_id] = "the server couldn't delete it"
            if gone:
                self._remember_removed(gone)
        if done:
            self._jobs.put(done)
        log(f"discover: removed {len(done)}, refused {len(failed)}")
        return {"done": done, "failed": failed}

    # -- Rescans, after the files changed

    def _worker(self) -> None:
        while True:
            purge = list(self._jobs.get())
            try:
                while True:  # One scan covers everything asked for meanwhile.
                    try:
                        purge += self._jobs.get_nowait()
                        self._jobs.task_done()
                    except queue.Empty:
                        break
                if not self.nav.scan_and_wait():
                    log("discover: Navidrome's scan didn't finish")
                elif purge:
                    self._purge(set(purge))
            except Exception as e:  # noqa: BLE001 - the worker must survive
                log(f"discover: rescan failed: {type(e).__name__}")
            finally:
                self._jobs.task_done()

    def _purge(self, ids: set[str]) -> None:
        """Clears removed songs from Navidrome's missing files, so they don't
        linger in its database. Only songs this module removed, and only while
        Navidrome lists them as missing."""
        status, missing = self.nav.api("GET", "/api/missing?_start=0&_end=1000")
        for m in missing if status == 200 and isinstance(missing, list) else []:
            if m.get("id") in ids:
                self.nav.api("DELETE", f"/api/missing?id={urllib.parse.quote(m['id'], safe='')}")

    def wait_idle(self) -> None:
        """For tests: until every rescan asked for has run."""
        self._jobs.join()


def from_env(navidrome_url: str, admin_user: str, admin_password: str) -> Discover | None:
    """Discover, when the installer turned it on (DISCOVER=on, the folders
    mounted) and there's an admin login; None otherwise."""
    if os.environ.get("DISCOVER", "") != "on" or not (admin_user and admin_password):
        return None
    discover_dir = os.environ.get("DISCOVER_DIR", "/discover")
    music_dir = os.environ.get("GETMUSIC_DIR", "/getmusic")
    for folder in (discover_dir, music_dir):
        if not os.path.isdir(folder):
            log(f"discover off: {folder} isn't mounted")
            return None
    return Discover(
        NavidromeAdmin(navidrome_url, admin_user, admin_password),
        discover_dir,
        music_dir,
        os.environ.get("STATE_DIR", "/state"),
        navidrome_path=os.environ.get("NAVIDROME_DISCOVER_PATH", "/discover"),
        soulbeet_discover=os.environ.get("SOULBEET_DISCOVER_PATH", "/music-discover"),
        soulbeet_music=os.environ.get("SOULBEET_MUSIC_PATH", "/music"),
    )
