# Sonar

A music player for your own music server. Sonar plays from
[Navidrome](https://www.navidrome.org/) (or any server that speaks the
Subsonic API) on **Android**, **Windows** and **iPhone**.

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

## Set up the server (one installer)

Sonar plays from a music server on your own computer. The installer in
[`server/`](server/README.md) sets everything up in Docker:

- **Navidrome**, the music server, reading your music folder (skip it if you
  already run Navidrome);
- **Sonar Connect** (on by default): your phone and PC see what each other is
  playing, control each other, and hand playback over;
- **Get music** (off unless you choose it): find and download albums you
  don't have, through [Soulbeet](https://github.com/terry90/soulbeet) and
  Soulseek, behind a VPN;
- an **https address** for your phone, through
  [Tailscale](https://tailscale.com/) (free).

You need [Docker](https://www.docker.com/products/docker-desktop/), and
Tailscale on the server and your phone. Then download this repository and run
**`server\install.cmd`** (Windows, double-click) or **`bash server/install.sh`**
(Mac / Linux). It asks a few questions, each with a default, and ends by
printing the address and login to type into Sonar. Run it again any time to
add Get music or change something. Details: [`server/README.md`](server/README.md).

Already have Navidrome? Sonar works with any Navidrome or Subsonic server
that has an `https://` address (Sonar refuses plain `http://` except on the
same computer, because your login goes over it). Use an ordinary, non-admin
user for the app.

## Install the app

Download from the [Releases](../../releases) page:

- **Android:** `app-arm64-v8a-release.apk` for almost every phone made since
  2017. Open it to install (allow installs from your browser or file manager
  when asked).
- **Windows:** unzip `sonar-windows.zip` anywhere and run `sonar.exe`.
- **iPhone:** `sonar-ios.ipa`, see below.

Then log in with your server address, username and password. **Get music**
appears by itself when the server has it.

### iPhone

Sonar isn't on the App Store, so an iPhone takes it the way it takes any app
you build yourself: signed with your own (free) Apple ID. The iPhone version
is new and less tried than Android and Windows: please open an issue if
something doesn't work.

**From a Windows PC or a Mac, with [AltStore](https://altstore.io/)** (free):

1. Install AltServer on your computer and AltStore on your iPhone, following
   AltStore's own guide (on Windows it needs iTunes and iCloud from Apple's
   website, not the Microsoft Store versions).
2. Download `sonar-ios.ipa` from Releases, then in AltStore on the phone tap
   **+** and pick it (or use AltServer's **Sideload .ipa** with the phone
   plugged in).
3. On iOS 16 or later, turn on **Settings > Privacy & Security > Developer
   Mode** when asked.

With a free Apple ID the app has to be re-signed every 7 days. AltStore does
that by itself over Wi-Fi while AltServer runs on your computer. (With a paid
Apple Developer account a signature lasts a year.)

**From a Mac with Xcode:** build it yourself (below), open
`ios/Runner.xcworkspace`, pick your Apple ID under Runner > Signing &
Capabilities > Team, and run it on the phone plugged in.

> Get music: you are responsible for what you download and share. Soulseek is
> a peer-to-peer network: share only what you have the right to share, and
> respect the law where you live. How Sonar talks to Soulbeet:
> [`docs/SOULBEET_PLAN.md`](docs/SOULBEET_PLAN.md).

## Building from source

You need [Flutter](https://docs.flutter.dev/get-started/install) (3.41 or
newer), plus Android Studio for Android, Visual Studio 2022 with "Desktop
development with C++" for Windows, or a Mac with Xcode for iPhone.

```
flutter pub get
flutter build apk --release --split-per-abi   # build/app/outputs/flutter-apk/
flutter build windows --release               # build/windows/x64/runner/Release/
flutter build ios --release                   # on a Mac; or open ios/Runner.xcworkspace
```

Releases are built by GitHub Actions (`.github/workflows/release.yml`): push
a tag like `v1.2.0` and it builds all three and publishes them. Android
release APKs are signed with the project's release key (`android/key.properties`
locally, two repository secrets on GitHub); without one, release builds use
your debug key.

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
