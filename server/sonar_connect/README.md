# Sonar Connect relay

Lets your Sonar apps (PC, phone) on one Navidrome account see what each other
is playing, control each other, and move playback between them. Design and
protocol: `../../docs/CONNECT_PLAN.md`.

Standard-library Python, no packages. Logins are checked against Navidrome's
`ping` with the app's own token; nothing secret is logged or stored on disk.
It also does Discover's keep / remove (below).

## Run

The server installer sets it up (`../README.md`): it runs as the
`sonar-connect` service in `../docker-compose.yml`, and Tailscale serves it at
`https://<your-server>/sonar-connect`, next to Navidrome at `/`.

By hand, beside a Navidrome you already run:

```
docker build -t sonar-connect .
docker run -d --name sonar-connect --restart unless-stopped -p 127.0.0.1:4534:4534 \
  -e NAVIDROME_URL=http://host.docker.internal:4533 --add-host host.docker.internal:host-gateway \
  sonar-connect
tailscale serve --bg --set-path /sonar-connect http://127.0.0.1:4534
```

Check: `curl https://<your-server>/sonar-connect/health` -> `{"ok": true}`.

## New albums straight away (optional)

Sonar asks the relay to rescan Navidrome when Soulbeet has filed an album
(`POST /rescan`). Navidrome only lets an admin start a scan, so the relay
needs an admin login in `NAVIDROME_ADMIN_USER` / `NAVIDROME_ADMIN_PASSWORD`
(the installer sets them from `.env`). The log then says `rescan on`.
Without it, new albums wait for Navidrome's own scan (hourly).

## Discover: keep / remove (optional)

`discover.py` moves a Discover song you keep into Get music's folder and
deletes one you remove (`GET /discover`, `POST /discover/keep`,
`POST /discover/remove`). It moves the song's beets rows with it, rescans, and
clears removed songs from Navidrome's missing files. It needs:
- the admin login above;
- the folders the installer mounts: the Discover folder at `/discover`, Get
  music's folder at `/getmusic`, and a `/state` volume for the list of removed
  songs;
- `DISCOVER=on` to turn it on.

The app sends song ids, never paths, and nothing outside the Discover folder
is ever deleted. Design: `../../docs/DISCOVER_PLAN.md`.

The compose file runs the relay as root for this, as Soulbeet writes its files
as root and only root may move or delete them. (Without Discover, the image's
own `relay` user is enough.) A move between the two folders, which are separate
mounts, copies the file and only then deletes the original. If the delete
fails, the copy is removed again, so a song is never in both places.

## Test

```
python -m unittest -v test_relay test_discover
```

Runs a real relay and a fake Navidrome on this machine. The Discover tests use
real files and real beets databases (beets' own schema, in `testdata/`) in
temp folders.
