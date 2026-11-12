// Runs the real Windows build (native audio, media keys, secure storage)
// against a fake server on 127.0.0.1, with quiet test tones.
//
//   flutter test integration_test/desktop_app_test.dart -d windows
//
// It logs in with a test-only account and logs out at the end, which clears
// the app's saved session and queue.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sonar/data/subsonic/models.dart';
import 'package:sonar/state/providers.dart';
import 'package:sonar/ui/shell/desktop_shell.dart';

import 'app_harness.dart';
import 'fake_navidrome.dart';

/// Presses a media key the way a keyboard does (it reaches the Windows media
/// controls, not the focused window).
void _mediaKey(int virtualKey) {
  final keybd = DynamicLibrary.open(
    'user32.dll',
  ).lookupFunction<Void Function(Uint8, Uint8, Uint32, IntPtr), void Function(int, int, int, int)>('keybd_event');
  const keyUp = 0x0002;
  keybd(virtualKey, 0, 0, 0);
  keybd(virtualKey, 0, keyUp, 0);
}

const _vkMediaPlayPause = 0xB3;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the Windows app plays, crossfades, takes media keys and picks up from the phone',
    (tester) async {
      final server = await FakeNavidrome.start(File('test/visual/covers/c1.png').readAsBytesSync());
      addTearDown(server.close);
      final app = AppHarness(tester);
      await app.launch();
      final container = app.container;
      final handler = container.read(audioHandlerProvider);
      final until = app.until;
      final errors = <String>[];
      handler.errors.listen(errors.add);
      final events = <String>[];
      handler.player.playbackEventStream.listen(
        (e) => events.add('${e.processingState.name} idx=${e.currentIndex} pos=${e.updatePosition}'),
        onError: (Object e) => events.add('ERROR $e'),
      );
      app.describe = () => [
        'playing=${handler.player.playing} state=${handler.player.processingState.name} '
            'pos=${handler.player.position} dur=${handler.player.duration} idx=${handler.player.currentIndex} '
            'song=${handler.currentSong?.id} volume=${handler.player.volume}',
        'server calls: ${server.requests.map((u) => u.pathSegments.last).where((e) => e != 'getCoverArt').join(', ')}',
        'errors: $errors',
        'last events: ${events.reversed.take(12).toList().reversed.join(' | ')}',
      ].join('\n');

      try {
        // Signed in to the fake server with plain http on loopback.
        await container
            .read(sessionProvider.notifier)
            .login(url: server.url, username: fakeUser, password: fakePassword);
        await until(() => find.byType(DesktopPlayerBar).evaluate().isNotEmpty, 'the desktop layout');
        handler.setUserVolume(0.15); // Barely audible.

        // Play an album from the page, the way a person would: the second
        // track, so the Windows playlist has to start part-way in.
        await until(() => find.text('Night Tones').evaluate().isNotEmpty, 'the album on Home');
        await tester.tap(find.text('Night Tones').first);
        await until(() => find.text('Tone B').evaluate().isNotEmpty, 'the album page');
        await tester.pump(const Duration(milliseconds: 800)); // Pages ignore taps while sliding in.
        // The row may sit below the fold on a small window.
        await tester.ensureVisible(find.text('Tone B').first);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Tone B').first);
        await until(() => handler.player.playing && handler.player.position > const Duration(seconds: 1), 'playback');
        expect(handler.currentSong?.id, 'a2', reason: 'the track that was clicked');

        // The media keys reach the app through the Windows media controls.
        await tester.pump(const Duration(seconds: 1));
        _mediaKey(_vkMediaPlayPause);
        await until(() => !handler.player.playing, 'the media key to pause', timeout: const Duration(seconds: 5));
        _mediaKey(_vkMediaPlayPause);
        await until(() => handler.player.playing, 'the media key to play', timeout: const Duration(seconds: 5));

        // Pausing saves the queue on the server for the other device.
        final saves = server.calls('savePlayQueue').length;
        await handler.pause();
        await until(() => server.calls('savePlayQueue').length > saves, 'the queue saved on the server');
        expect(server.calls('savePlayQueue').last.queryParameters['current'], 'a2');
        expect(server.calls('savePlayQueue').last.queryParameters['c'], 'sonar-desktop');

        // A crossfade into a song from another album, on two real Windows players.
        // 24 s songs: a 6 s fade starts at 18 s; the tail loads at 16 s.
        final a1 = Song.fromJson(tracks[0].toJson());
        final b1 = Song.fromJson(tracks[2].toJson());
        await handler.playSongs([a1, b1]);
        await until(() => handler.player.playing && handler.player.processingState.name == 'ready', 'playback');
        await handler.seek(const Duration(seconds: 13));
        final clock = Stopwatch()..start();
        await until(() => handler.currentSong?.id == 'b1', 'the crossfade', timeout: const Duration(seconds: 12));
        final switchedAfter = clock.elapsed;
        final full = 0.15 * 0.15;
        await tester.pump(const Duration(seconds: 1));
        final midFade = handler.player.volume;
        await until(() => (handler.player.volume - full).abs() < 1e-6, 'the fade to finish');
        expect(switchedAfter, lessThan(const Duration(seconds: 8)), reason: 'moved on at 18 s, before the song ended');
        expect(midFade, lessThan(full * 0.8), reason: 'the new song was still fading in a second later');
        expect(handler.player.position, greaterThan(const Duration(seconds: 4)), reason: 'it played on from the start');

        // The phone left a queue on the server: offer it, and pick it up here,
        // on its second song, 9 s in.
        await handler.pause();
        await tester.pump(const Duration(seconds: 1));
        server.phoneLeft('a2', const Duration(seconds: 9));
        container.invalidate(handoffProvider);
        await until(() => find.text('Continue from your phone').evaluate().isNotEmpty, 'the offer to carry on');
        await tester.pump(const Duration(milliseconds: 800)); // Let it finish sliding in.
        await tester.tap(find.textContaining('Play here'));
        await until(
          () => handler.player.playing && handler.player.processingState.name == 'ready',
          'the phone queue to play here',
        );
        await tester.pump(const Duration(seconds: 1));
        expect(handler.currentSong?.id, 'a2', reason: 'started on the song the phone was on');
        expect(
          handler.player.position.inMilliseconds,
          inInclusiveRange(9000, 14000),
          reason: 'and at the right second',
        );

        expect(errors, isEmpty, reason: 'no playback errors');
      } finally {
        // Here, not in a tear-down: by then the app's widgets are gone.
        await app.signOut();
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
