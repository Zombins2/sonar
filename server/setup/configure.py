"""Finishes a Sonar server install. Run by the installer inside Docker
(`docker compose --profile setup run --rm setup`), on the stack's network.

Steps, each skipped when there's nothing to do, so running it again is safe:
1. Navidrome: create the first admin (a fresh server has no users), or check
   the admin login works.
2. Navidrome: create the everyday login for the Sonar app (not an admin).
3. Get music: point Soulbeet at slskd.

Never prints passwords, tokens or keys.
"""

import http.cookiejar
import json
import os
import sys
import time
import urllib.error
import urllib.request

NAVIDROME = os.environ.get("NAVIDROME_URL", "http://navidrome:4533").rstrip("/")
SOULBEET = os.environ.get("SOULBEET_URL", "http://soulbeet:9765").rstrip("/")
PROFILES = {p.strip() for p in os.environ.get("COMPOSE_PROFILES", "").split(",") if p.strip()}
ADMIN = os.environ.get("NAVIDROME_ADMIN_USER", "")
ADMIN_PASSWORD = os.environ.get("NAVIDROME_ADMIN_PASSWORD", "")
APP_USER = os.environ.get("SONAR_USER", "")
APP_PASSWORD = os.environ.get("SONAR_USER_PASSWORD", "")
SLSKD_API_KEY = os.environ.get("SLSKD_API_KEY", "")
# slskd shares gluetun's network, so on the Docker network it is gluetun.
SLSKD_URL = "http://gluetun:5030"


class Failed(Exception):
    pass


def say(msg):
    print(f"  {msg}", flush=True)


def request(opener, url, body=None, headers=None, method=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method or ("POST" if data else "GET"))
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with opener.open(req, timeout=20) as r:
            text = r.read().decode() or "null"
            return r.status, json.loads(text) if text.strip().startswith(("{", "[", "null", '"')) else text
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:300]


def wait_for(name, url, seconds=180):
    plain = urllib.request.build_opener()
    end = time.time() + seconds
    while time.time() < end:
        try:
            with plain.open(url, timeout=5):
                return
        except urllib.error.HTTPError:
            return  # It answered, even if with an error.
        except Exception:
            time.sleep(2)
    raise Failed(f"{name} didn't start within {seconds} s (check `docker compose logs`)")


def navidrome_admin_token():
    """Logs in as the admin, creating it first on a fresh server."""
    plain = urllib.request.build_opener()
    creds = {"username": ADMIN, "password": ADMIN_PASSWORD}
    status, reply = request(plain, f"{NAVIDROME}/auth/login", creds)
    if status == 200 and isinstance(reply, dict) and reply.get("isAdmin"):
        say(f"Navidrome admin '{ADMIN}': login works")
        return reply["token"]
    if status == 200:
        raise Failed(f"'{ADMIN}' can log in to Navidrome but isn't an admin")
    status, reply = request(plain, f"{NAVIDROME}/auth/createAdmin", creds)
    if status == 200 and isinstance(reply, dict) and reply.get("token"):
        say(f"Navidrome admin '{ADMIN}': created")
        return reply["token"]
    raise Failed(
        "the Navidrome admin login didn't work, and Navidrome already has users, "
        "so no new admin can be made. Check NAVIDROME_ADMIN_USER / PASSWORD in .env."
    )


def navidrome_app_user(token):
    plain = urllib.request.build_opener()
    auth = {"X-ND-Authorization": f"Bearer {token}"}
    status, users = request(plain, f"{NAVIDROME}/api/user", headers=auth)
    if status == 200 and any(u.get("userName") == APP_USER for u in users or []):
        say(f"Sonar login '{APP_USER}': already exists")
        return
    status, reply = request(
        plain,
        f"{NAVIDROME}/api/user",
        {"userName": APP_USER, "name": APP_USER, "password": APP_PASSWORD, "isAdmin": False},
        headers=auth,
    )
    if status not in (200, 201):
        raise Failed(f"couldn't create the Sonar login '{APP_USER}' (Navidrome said {status}: {reply})")
    say(f"Sonar login '{APP_USER}': created")


def soulbeet_config():
    if not SLSKD_API_KEY:
        raise Failed("SLSKD_API_KEY is missing from .env")
    jar = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    status, reply = request(jar, f"{SOULBEET}/api/auth/login", {"username": ADMIN, "password": ADMIN_PASSWORD})
    if status != 200:
        raise Failed(f"couldn't log in to Soulbeet as '{ADMIN}' ({status}: {reply})")
    status, reply = request(
        jar, f"{SOULBEET}/api/config", {"config": {"slskd_url": SLSKD_URL, "slskd_api_key": SLSKD_API_KEY}}
    )
    if status != 200 or not isinstance(reply, dict) or reply.get("slskd_url") != SLSKD_URL:
        raise Failed(f"Soulbeet didn't take the slskd settings ({status})")
    say("Soulbeet: connected to slskd")


def main():
    try:
        if not (ADMIN and ADMIN_PASSWORD):
            raise Failed("NAVIDROME_ADMIN_USER / NAVIDROME_ADMIN_PASSWORD are missing from .env")
        wait_for("Navidrome", f"{NAVIDROME}/ping")
        token = navidrome_admin_token()
        if APP_USER and APP_PASSWORD:
            navidrome_app_user(token)
        if "getmusic" in PROFILES:
            wait_for("Soulbeet", f"{SOULBEET}/api/system/health")
            soulbeet_config()
    except Failed as e:
        print(f"  Setup stopped: {e}", file=sys.stderr, flush=True)
        sys.exit(1)
    say("Setup done.")


if __name__ == "__main__":
    main()
