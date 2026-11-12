# Sonar

A music player for your own music server. Sonar plays from
[Navidrome](https://www.navidrome.org/) (or any server that speaks the
Subsonic API) on **Android** and **Windows**.

It's a hobby project, shared as-is under the MIT license: take it, change it,
make it yours. There's no support promise and no app store listing.

## What it does

- **Browse and play** your library: albums, artists, playlists, genres,
  favourites, search. Gapless playback, a Spotify-style queue ("Play next",
  "Add to queue"), shuffle and repeat, a sleep timer.
- **Lock screen, notification and headset controls**, and **Android Auto**.
- **Offline:** download albums and playlists (on Wi-Fi only unless you say
  otherwise) and play them with no connection. Browsing works from cache when
  the server is out of reach.
- **Lyrics:** synced lyrics scroll along and can be tapped to jump. When the
  server only has plain lyrics, timed ones can be fetched from LRCLIB (can be
  turned off).
- **Quality caps** for Wi-Fi and mobile data, and scrobbling (play counts,
  and Last.fm / ListenBrainz if your server is set up for them).
- **Windows desktop app** with media keys, the Windows media overlay, and
  crossfade / ReplayGain.
- **Sonar Connect** (optional, small server add-on): your phone and PC see
  what each other is playing, control each other, and hand playback over.
- **Get music** (optional, server add-on): search for albums you don't have,
  download them through [Soulbeet](https://github.com/terry90/soulbeet), and
  watch them land in your library. Hidden unless you set it up.

## What you need

1. **A Navidrome server** with your music on it. See Navidrome's
   [install guide](https://www.navidrome.org/docs/installation/); Docker is
   the easy way.
2. **An `https://` address for it.** Sonar refuses plain `http://` (except on
   the same computer), because your login goes over it. Two easy ways:
   - [Tailscale](https://tailscale.com/) (free for personal use): install it
     on the server and your devices, then
     `tailscale serve --bg http://127.0.0.1:4533` gives Navidrome a private
     `https://<your-pc>.<your-tailnet>.ts.net` address only your devices can
     reach. This is what Sonar is mostly used with.
   - A reverse proxy with a certificate (Caddy, nginx, Traefik) on your own
     domain.
3. **A Navidrome user for Sonar.** Use an ordinary (non-admin) user.

## Install the app

Download from the [Releases](../../releases) page:

- **Android:** `app-arm64-v8a-release.apk` for almost every phone made since
  2017. Open it to install (allow installs from your browser or file manager
  when asked).
- **Windows:** unzip `sonar-windows.zip` anywhere and run `sonar.exe`.

Then log in with your server address, username and password.

iPhone: not yet. An iOS build is planned.

## Optional server add-ons

### Sonar Connect (control playback across devices)

A tiny relay that runs beside Navidrome in Docker. See
[`server/sonar_connect/README.md`](server/sonar_connect/README.md). Sonar
finds it at `https://<your-server>/sonar-connect`.

### Get music (download albums you don't have)

Get music talks to a [Soulbeet](https://github.com/terry90/soulbeet) server,
which searches MusicBrainz, downloads over Soulseek with
[slskd](https://github.com/slskd/slskd), and files the music with
[beets](https://beets.io/). Sonar looks for Soulbeet at
`https://<your-server>:8443` and only shows **Get music** when it answers.

How it works and the API Sonar uses: [`docs/SOULBEET_PLAN.md`](docs/SOULBEET_PLAN.md).

> You are responsible for what you download and share. Soulseek is a
> peer-to-peer network: run slskd behind a VPN, share only what you have the
> right to share, and respect the law where you live.

## Building from source

You need [Flutter](https://docs.flutter.dev/get-started/install) (3.41 or
newer), plus Android Studio for Android or Visual Studio 2022 with "Desktop
development with C++" for Windows.

```
flutter pub get
flutter build apk --release --split-per-abi   # build/app/outputs/flutter-apk/
flutter build windows --release               # build/windows/x64/runner/Release/
```

To pre-fill your server on the login screen:
`--dart-define=SONAR_SERVER=https://music.example.com`.

If Flutter can't find a JDK, point it at Android Studio's:
`flutter config --jdk-dir "<Android Studio>/jbr"`.

The Windows build uses patched copies of three plugins, in `packages/`
(what was changed and why: [`packages/PATCHES.md`](packages/PATCHES.md)).

### Tests

```
flutter test                                   # unit and widget tests
flutter test integration_test -d windows       # the real Windows app against a fake server
flutter test test/visual --dart-define=SCREENSHOTS=true   # screenshots of every screen, in build/screens/
cd server/sonar_connect && python -m unittest -v test_relay
```

### Code layout

```
lib/
  data/subsonic/   Subsonic API client (token auth, typed models)
  data/db/         drift database: response cache and saved state
  data/auth/       logins in secure storage
  data/soulbeet/   Get music: Soulbeet client, source picking, download flow
  audio/           player (just_audio + audio_service), Android Auto menus
  connect/         Sonar Connect client
  state/           Riverpod providers
  core/            theme, routes, navigation
  ui/              screens and widgets
server/sonar_connect/   the Sonar Connect relay (Python, no dependencies)
docs/                   design notes
```

After changing `lib/data/db/database.dart`, regenerate the database code with
`dart run build_runner build`. Format with `dart format lib test` (line width
120).

## Notes and troubleshooting

- **Login:** Sonar sends `t = md5(password + salt)` with a fresh salt on every
  request, as the Subsonic API asks. The password is never put in a URL and
  is stored in the system's secure storage.
- **Navidrome on Windows (Docker Desktop):** keep Navidrome's cache on a Docker
  volume (`ND_CACHEFOLDER=/cache` on a named volume), not a Windows folder.
  On a Windows bind mount, cached files can't be read back, which breaks
  lower-quality streaming and some cover art.
- **Synced lyrics in a `SYNCEDLYRICS` tag** are ignored by Navidrome unless you
  add that tag to its lyrics aliases, then run a full rescan.
- **Android Auto** only lists sideloaded apps after you turn on **Unknown
  sources** in Android Auto's developer settings.

## License

MIT, see [`LICENSE`](LICENSE). Bundled third-party code keeps its own license:
the Figtree font (SIL Open Font License, `assets/fonts/OFL.txt`) and the
patched plugins in `packages/` (MIT and BSD-3-Clause, each with its `LICENSE`).
