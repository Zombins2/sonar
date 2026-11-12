# Sonar Connect relay

Lets your Sonar apps (PC, phone) on one Navidrome account see what each other
is playing, control each other, and move playback between them. Design and
protocol: `../../docs/CONNECT_PLAN.md`.

Standard-library Python, no packages. Logins are checked against Navidrome's
`ping` with the app's own token; nothing secret is logged or stored on disk.

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

## Test

```
python -m unittest -v test_relay
```

Runs a real relay and a fake Navidrome on this machine.
