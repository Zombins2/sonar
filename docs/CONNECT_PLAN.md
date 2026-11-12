# Sonar Connect: see and control playback across your devices

Asked for 2026-11-09: "have them share what they are playing per account, so if
I'm listening on PC allow me to skip or edit my queue from phone, or choose to
change the device playing".

Decided with the owner: a small sync service runs in Docker beside Navidrome,
reached through the existing Tailscale address (tailnet only) at
`/sonar-connect`. Each account only sees its own devices.

## Pieces

1. **Relay** (`server/sonar_connect/`): Python standard library only, no
   packages. Image `python:3.12-alpine`. Listens on 127.0.0.1:4534 and joins
   the `navidrome_default` network to check logins against `navidrome:4533`.
   - `POST /hello` with `{u, t, s, device:{id, name, kind}}` in the body
     (never the URL). The relay asks Navidrome `ping` with those; on success
     it returns `{session}` (random, held in memory only). Never logs t, s or
     the session.
   - `GET /events` with `Authorization: Bearer <session>`: a Server-Sent
     Events stream. `devices` (every device on the account with its whole
     merged state) on every join/leave; `state` `{id, state: patch}` when
     another device reports changes; `command` events addressed to this
     device. A comment line every 15 s keeps proxies from closing it.
     Closing the stream ends the session and drops the device; so does
     posting nothing for 60 s (a phone that lost signal never hangs up).
   - `POST /state` (Bearer): changes to this device's player state. The relay
     merges them and passes the patch to the account's other devices.
   - `POST /command` (Bearer) `{to, cmd, ...}`: forwarded to that device on
     the same account only, with `from` set to the sender. Unknown device ->
     404. `to`, `cmd` and `from` are reserved: command arguments use other
     names (`fromIndex`/`toIndex`, `target`).
   - Limits: 2 MB bodies, 8 devices per account, sessions die with their
     stream.
   SSE + POST instead of WebSocket: plain HTTP both ways, which Tailscale
   serve proxies as-is (it flushes text/event-stream), and no hand-rolled
   frame parser on the server.

2. **App connection** (`lib/connect/`): one `ConnectClient` per login. Device
   id is random and kept in the app database; name/kind is "PC" or "phone".
   Address: the server address + `/sonar-connect`, except a loopback login
   (`http://localhost:4533`) which uses `http://127.0.0.1:4534` directly.
   Reconnects with backoff. If the relay can't be reached, everything works
   as today and the device list says so.

3. **State** each device publishes: current song (full song JSON), index,
   position + whether playing (receivers extrapolate from when they got it),
   the queue around the current song (at least 50 before and 200 after; the
   window moves in steps of 25 songs so it isn't resent every track), which
   items were queued by hand, shuffle, repeat, volume, and the source
   ("Playing from album ..."). Only changed keys are sent: the queue when it
   or its window changes, the position on play/pause, track change, any jump
   over 1.5 s (a seek) and every 15 s.

4. **Controlling another device**: the app has an output target, `null` =
   this device. While the target is another device:
   - the mini player, desktop player bar and Now Playing show that device's
     state, with a "Playing on your PC" line;
   - every control (play/pause, skip, seek, shuffle, repeat, volume, the queue
     list's reorder/remove/jump, and Play / Play next / Add to queue from any
     song menu or page) is sent to that device as a command.
   - Sleep timer and downloads stay local and hide in this mode.
   The target is set automatically when this device has nothing playing and
   another device on the account is playing; it drops back to this device if
   that device disconnects or empties its queue. The user can always pick in
   the device list.

5. **Switching the playing device** (device list, from a speaker icon on the
   mini player, player bar and Now Playing): pick a device and playback moves
   there at the same song and second, in the same order, with shuffle/repeat
   and hand-queued items kept. The old device pauses. Flow: the device that is
   playing sends a `takeOver` command with a queue snapshot to the new one,
   then pauses. When the new one is remote, the picker sends that device's
   player a `handOver {to}` and it does the rest.

6. **Handoff banner** ("Continue from your phone") stays for when the other
   device is offline; it hides while that device is live on Connect.

## Steps

1. Relay + its tests (Windows Python, fake Navidrome), Dockerfile.
2. `ConnectClient`, device id, state publishing, command handling, tests
   against the real relay process.
3. Controls/state switching + UI (device list, "Playing on" indicators,
   remote queue), tests.
4. Transfer both ways, tests.
5. Deploy: build the image (asks before the python:3.12-alpine pull), run it
   with `--restart unless-stopped`, add the `/sonar-connect` path to Tailscale
   serve. Real PC app + phone APK; owner tries PC <-> phone.

## Not in this

- Several people on one account see each other (it's per account, by design).
- No auto-pausing a device because another started: the device list shows
  both.
