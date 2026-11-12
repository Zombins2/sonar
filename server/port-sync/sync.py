"""Keeps slskd listening on the port Proton forwards through gluetun.

Runs in gluetun's network, so both APIs are on 127.0.0.1. Every minute it
asks gluetun for the forwarded port and, when slskd isn't on it (a new
port, or slskd restarted and fell back to its default), tells slskd.
API keys are never printed.
"""

import json
import os
import time
import urllib.request

GLUETUN = "http://127.0.0.1:8000/v1/portforward"
SLSKD = "http://127.0.0.1:5030/api/v0/options"
EVERY = 60


def call(url, key, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("X-API-Key", key)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=10) as r:
        text = r.read().decode() or "null"
    return json.loads(text)


def slskd_port(key):
    options = call(SLSKD, key)
    soulseek = (options or {}).get("soulseek") or {}
    return soulseek.get("listenPort")


def main():
    gluetun_key = os.environ["GLUETUN_API_KEY"]
    slskd_key = os.environ["SLSKD_API_KEY"]
    last_error = None
    while True:
        try:
            port = (call(GLUETUN, gluetun_key) or {}).get("port") or 0
            if port:
                current = slskd_port(slskd_key)
                if current != port:
                    call(SLSKD, slskd_key, "PATCH", {"soulseek": {"listenPort": port}})
                    print(f"slskd now listens on {port} (was {current})", flush=True)
            last_error = None
        except Exception as e:  # slskd or the VPN still starting, etc.
            msg = f"{type(e).__name__}: {getattr(e, 'code', '') or getattr(e, 'reason', '') or e}"
            if msg != last_error:
                print(f"waiting: {msg}", flush=True)
                last_error = msg
        time.sleep(EVERY)


if __name__ == "__main__":
    main()
