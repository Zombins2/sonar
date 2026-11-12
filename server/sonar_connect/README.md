# Sonar Connect relay

Lets your Sonar apps (PC, phone) on one Navidrome account see what each other
is playing, control each other, and move playback between them. Design and
protocol: `../../docs/CONNECT_PLAN.md`.

Standard-library Python, no packages. Logins are checked against Navidrome's
`ping` with the app's own token; nothing secret is logged or stored on disk.

## Run

```
docker compose up -d --build
tailscale serve --bg --set-path /sonar-connect http://127.0.0.1:4534
```

The first line builds and starts the container (restarts with Docker). The
second makes it reachable to your tailnet at
`https://<your-server>/sonar-connect`, next to Navidrome at `/`. It stays
tailnet-only, like Navidrome.

Check: `curl https://<your-server>/sonar-connect/health` -> `{"ok": true}`.

## New albums straight away (optional)

Sonar asks the relay to rescan Navidrome when Soulbeet has filed an album
(`POST /rescan`). Navidrome only lets an admin start a scan, so copy
`.env.example` to `.env`, put a Navidrome admin login in it, and run
`docker compose up -d` again. The log then says `rescan on`. Without it,
new albums wait for Navidrome's own scan (hourly).

## Test

```
python -m unittest -v test_relay
```

Runs a real relay and a fake Navidrome on this machine.
