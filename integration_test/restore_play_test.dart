// A queue saved last time comes back at start-up, part-way into a song; then
// play is pressed. On the real Windows player.
//
//   flutter test integration_test/restore_play_test.dart -d windows
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sonar/data/subsonic/models.dart';
import 'package:sonar/state/providers.dart';

import 'app_harness.dart';
import 'fake_navidrome.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a queue restored at start-up resumes where it was', (tester) async {
    final server = await FakeNavidrome.start(File('test/visual/covers/c1.png').readAsBytesSync());
    addTearDown(server.close);
    final app = AppHarness(tester);
    await app.launch();
    final handler = app.container.read(audioHandlerProvider);
    app.describe = () {
      final p = handler.player;
      return 'playing=${p.playing} state=${p.processingState.name} pos=${p.position} dur=${p.duration} '
          'idx=${p.currentIndex} song=${handler.currentSong?.id}\n'
          'server: ${server.requests.map((u) => u.pathSegments.last).where((e) => e != 'getCoverArt').join(',')}';
    };

    try {
      // What the last session left behind: the second song, 5 s in.
      final songs = [for (final t in tracks) Song.fromJson(t.toJson())];
      await app.container.read(dbProvider).setJson('queue_state', {
        'songs': [for (final s in songs.take(2)) s.toJson()],
        'index': 1,
        'positionMs': 5000,
        'loop': 'off',
        'queued': <int>[],
      });
      await app.container
          .read(sessionProvider.notifier)
          .login(url: server.url, username: fakeUser, password: fakePassword);
      await app.until(() => handler.currentSong?.id == 'a2', 'the queue to come back');
      handler.setUserVolume(0.15);
      await tester.pump(const Duration(seconds: 1));

      final clock = Stopwatch()..start();
      unawaited(handler.play());
      await app.until(
        () => handler.player.playing && handler.player.position > const Duration(seconds: 6),
        'the restored song to resume',
      );
      debugPrint('SONAR-STEP resumed after ${clock.elapsedMilliseconds} ms at ${handler.player.position}');
      expect(handler.currentSong?.id, 'a2', reason: 'the song it was on');
      expect(handler.player.position.inSeconds, lessThan(10), reason: 'from 5 s, not the start or the end');
    } finally {
      await app.signOut();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
