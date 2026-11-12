# Patched Windows plugins

Copies of three pub.dev packages, kept here because Sonar needs fixes the
published versions don't have. Each change is marked `Sonar patch` in the
source. All of these were found or confirmed by running the real Windows app
(`integration_test/`) against a local fake server.

## just_audio_windows 0.2.3 (bdlukaa, MIT)

- **Main-thread events** (`windows/main_thread.hpp`, `player.hpp`): WinRT raises
  playback events on worker threads, and the plugin sent them straight down
  Flutter's platform channels, which must only be used from the platform
  thread. Events now go through `MainThread::Post`, which posts a window
  message to the app's top-level window and runs the work there. A late event
  for a disposed player is dropped instead of touching freed memory.
  - The window is looked up at each post: while plugins register, Flutter's
    view isn't inside the app window yet.
  - Each plugin uses its own message name (`SONAR_MAIN_THREAD_MESSAGE`): the
    first window-proc delegate to answer a message stops it reaching the
    others, so a shared name meant one plugin swallowed the other's events.
- **No per-player media flyout**: by Windows' design each `MediaPlayer` joins the
  media flyout through its CommandManager. `CommandManager().IsEnabled(false)`
  keeps the main and crossfade players out, so the flyout shows only the app's
  own entry (audio_service_win). In our runs media keys worked either way; this
  follows the documented way to drive the flyout yourself.
- **Start on the right song**: a playlist can't `MoveTo()` an item before it has
  opened ("the request is invalid in the current state"), so clicking the 5th
  track played the 1st. The list's `StartingItem` is set before opening.
  (Shown by the real run: without it, clicking track 2 played track 1.)
- **Long start positions**: `initialPosition`/`initialIndex` were read with
  `get_if<int>`, which silently ignored 64-bit values (positions past ~35 min).

## audio_service_win 0.0.3 (HemantKArya, MIT)

- **Main-thread button presses**: the SMTC `ButtonPressed` handler (a worker
  thread) called the method channel directly; it now posts to the main thread
  (same `main_thread.hpp`, its own message name).
- **CommandManager off** on the plugin's silent `MediaPlayer`, so button
  presses reach `ButtonPressed` instead of being handled by Windows.
- **Thumbnail**: an http(s) cover is set directly (it's only a reference)
  instead of from a detached thread racing `ClearAll()`; a null cover is skipped.

## flutter_secure_storage_windows 4.2.2 (mogol, BSD-3-Clause)

- **No ATL**: the plugin included `<atlstr.h>` only for `CA2W`/`CW2A` string
  conversions, so it failed to build without Visual Studio's optional ATL
  component. Small stand-ins with the same names do the same conversions
  (ANSI code page) using `MultiByteToWideChar`/`WideCharToMultiByte`.
  Wired in through `dependency_overrides` in pubspec.yaml.
