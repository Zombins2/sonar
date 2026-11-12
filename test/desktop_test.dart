import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/data/db/database.dart';
import 'package:sonar/data/handoff.dart';
import 'package:sonar/data/subsonic/models.dart';
import 'package:sonar/data/subsonic/subsonic_client.dart';
import 'package:sonar/ui/desktop_shortcuts.dart';

import 'support/fake_server.dart';
import 'support/player_harness.dart';

PlayQueue _queue({String by = 'sonar', DateTime? changed, String current = 'b', int positionMs = 61000}) => PlayQueue(
  songs: [testSong('a'), testSong('b'), testSong('c')],
  currentId: current,
  position: Duration(milliseconds: positionMs),
  changed: changed ?? DateTime(2026, 11, 8, 12),
  changedBy: by,
);

void main() {
  group('carrying on from the other device', () {
    final now = DateTime(2026, 11, 8, 13);
    PlayQueue? offer(
      PlayQueue? server, {
      String me = SubsonicClient.desktopClientName,
      bool playing = false,
      String? current,
      Duration position = Duration.zero,
      DateTime? dismissed,
    }) => handoffOffer(
      server: server,
      me: me,
      playingHere: playing,
      currentHere: current,
      positionHere: position,
      dismissed: dismissed,
      now: now,
    );

    test('offers what the phone was playing to the PC, and back', () {
      expect(offer(_queue())?.current?.id, 'b');
      expect(offer(_queue(by: SubsonicClient.desktopClientName), me: 'sonar')?.current?.id, 'b');
    });

    test('not its own queue, and not over music that is already playing', () {
      expect(offer(_queue(by: SubsonicClient.desktopClientName)), isNull);
      expect(offer(_queue(), playing: true), isNull);
      expect(offer(null), isNull);
      expect(offer(_queue(current: 'gone')), isNull, reason: 'its current song is not in the queue');
    });

    test('not once turned down, until the other device plays on', () {
      final q = _queue();
      expect(offer(q, dismissed: q.changed), isNull);
      expect(offer(_queue(changed: q.changed!.add(const Duration(minutes: 5))), dismissed: q.changed), isNotNull);
    });

    test('not when this device is already at that spot, nor when it is weeks old', () {
      expect(offer(_queue(), current: 'b', position: const Duration(seconds: 55)), isNull);
      expect(offer(_queue(), current: 'b', position: const Duration(seconds: 5)), isNotNull);
      expect(offer(_queue(changed: now.subtract(const Duration(days: 20)))), isNull);
    });

    test('names the device that left it', () {
      expect(deviceName('sonar'), 'your phone');
      expect(deviceName(SubsonicClient.desktopClientName), 'your PC');
      expect(deviceName('NavidromeUI'), 'NavidromeUI');
      expect(deviceName(null), 'another device');
    });

    test('saves some of what played and what is still to come', () {
      final songs = [for (var i = 0; i < 400; i++) testSong('s$i')];
      final saved = queueToSave(songs, 100);
      expect(saved.first.id, 's50');
      expect(saved.last.id, 's300');
      expect(queueToSave(songs.take(3).toList(), 1).map((s) => s.id), ['s0', 's1', 's2']);
    });
  });

  group('the server queue API', () {
    test('saves with repeated ids, the current song and position in ms', () async {
      final server = fakeServer({});
      await server.client.savePlayQueue(['a', 'b'], current: 'b', position: const Duration(seconds: 61));
      final uri = server.adapter.requests.single;
      expect(uri.pathSegments.last, 'savePlayQueue');
      expect(uri.queryParametersAll['id'], ['a', 'b']);
      expect(uri.queryParameters['current'], 'b');
      expect(uri.queryParameters['position'], '61000');
      expect(uri.toString(), isNot(contains(testCreds.password)));
    });

    test('reads the saved queue, or nothing', () async {
      final server = fakeServer({
        'getPlayQueue': ok({
          'playQueue': {
            'current': 's2',
            'position': 61000,
            'changed': '2026-11-08T12:00:00Z',
            'changedBy': 'sonar',
            'entry': [
              {'id': 's1', 'title': 'One'},
              {'id': 's2', 'title': 'Two'},
            ],
          },
        }),
      });
      final q = (await server.client.getPlayQueue())!;
      expect(q.current?.title, 'Two');
      expect(q.currentIndex, 1);
      expect(q.position, const Duration(seconds: 61));
      expect(q.changedBy, 'sonar');
      expect(await fakeServer({}).client.getPlayQueue(), isNull);
    });
  });

  group('the player on desktop', () {
    final p = PlayerHarness();
    tearDown(p.tearDown);

    test('saves the queue to the server when paused, and picks one up mid-song', () async {
      p.setUp();
      final server = fakeServer({});
      final h = await p.start([testSong('a'), testSong('b')], server: server, position: const Duration(seconds: 7));
      expect(p.platform.players.first.loads.single.position, const Duration(seconds: 7));
      Iterable<Uri> saves() => server.adapter.requests.where((u) => u.pathSegments.last == 'savePlayQueue');
      // The song starting saves once; pausing must save again, at the new spot.
      await waitFor(() => saves().isNotEmpty);
      final before = saves().length;
      await h.seek(const Duration(seconds: 15));
      await h.pause();
      await waitFor(() => saves().length > before, timeout: const Duration(seconds: 1));
      final save = saves().last;
      expect(save.queryParametersAll['id'], ['a', 'b']);
      expect(save.queryParameters['current'], 'a');
      expect(int.parse(save.queryParameters['position']!), greaterThanOrEqualTo(15000));
    });

    test('a queue only restored at start-up is not saved over the other device', () async {
      p.setUp();
      final db = AppDatabase(NativeDatabase.memory());
      // Play and pause once, so there is a saved local queue to restore.
      final first = await p.start([testSong('a'), testSong('b')], db: db);
      await first.pause();
      final server = fakeServer({});
      final restored = await p.start(const [], db: db, server: server, play: false);
      expect(restored.currentSong?.id, 'a', reason: 'the queue came back');
      await restored.pause();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(server.adapter.requests.where((u) => u.pathSegments.last == 'savePlayQueue'), isEmpty);
    });

    test('a queue comes back on the song and second it was left at', () async {
      p.setUp();
      final db = AppDatabase(NativeDatabase.memory());
      final first = await p.start([testSong('a'), testSong('b'), testSong('c')], db: db);
      await first.skipToQueueItem(1);
      await first.seek(const Duration(seconds: 5));
      await first.pause();
      final restored = await p.start(const [], db: db, play: false);
      final shown = restored.currentSong?.id;
      final before = p.platform.players.length;
      unawaited(restored.play());
      // The restored handler's own player (a crossfade tail may follow it).
      await waitFor(() => p.platform.players.length > before && p.platform.players[before].playing);
      final native = p.platform.players[before];
      expect(native.index, 1, reason: 'plays the song it was on');
      expect(native.position.inMilliseconds, inInclusiveRange(5000, 7000), reason: 'from the second it was at');
      expect(shown, 'b', reason: 'shows the song it was on before play is pressed');
    });

    test('after a queue comes back at start-up, tapping a song plays it', () async {
      p.setUp();
      final db = AppDatabase(NativeDatabase.memory());
      final first = await p.start([testSong('a'), testSong('b')], db: db);
      await first.pause();
      final restored = await p.start(const [], db: db, play: false);
      expect(restored.currentSong?.id, 'a', reason: 'the queue came back');
      final before = p.platform.players.length;
      await restored.playSongs([testSong('c'), testSong('d')]);
      await waitFor(() => p.platform.players.skip(before).any((pl) => pl.playing), timeout: const Duration(seconds: 3));
      expect(restored.currentSong?.id, 'c');
    });

    test('logging out and back in, music still plays', () async {
      p.setUp();
      final server = fakeServer({});
      final h = await p.start(const [], server: server, play: false);
      await h.setClient(null); // Log out.
      await h.setClient(server.client); // And back in.
      await h.playSongs([testSong('a'), testSong('b')]);
      await waitFor(() => p.platform.players.any((pl) => pl.playing), timeout: const Duration(seconds: 3));
    });

    test('the volume slider scales every song and is remembered', () async {
      p.setUp();
      final db = AppDatabase(NativeDatabase.memory());
      final h = await p.start([testSong('a'), testSong('b')], db: db);
      h.setUserVolume(0.5);
      await waitFor(() => p.platform.players.first.volumes.isNotEmpty);
      expect(p.platform.players.first.volumes.last, closeTo(0.25, 1e-9), reason: 'loudness follows the square');
      await Future<void>.delayed(const Duration(milliseconds: 500)); // Saved after a short pause.
      final again = await p.start(const [], db: db, play: false);
      expect(again.userVolume.value, 0.5);
    });

    test('a pause from outside the app that lasts still ends the crossfade', () async {
      p.setUp();
      // A 4 s fade (starting at 16 s), so it can't simply run out first.
      final h = await p.start([testSong('a'), testSong('b')], crossfade: 4);
      final main = p.platform.players.first;
      await h.seek(const Duration(seconds: 13, milliseconds: 400));
      await waitFor(() => h.currentSong?.id == 'b');
      main.pauseFromOutside(); // A call comes in.
      await waitFor(() => p.tail!.disposed, timeout: const Duration(seconds: 2));
    });

    test("a crossfade survives Windows' 'not playing' blip while the next song opens", () async {
      p.setUp(blipOnSkip: true);
      final h = await p.start([testSong('a'), testSong('b')]);
      final main = p.platform.players.first;
      await h.seek(const Duration(seconds: 16, milliseconds: 400));
      await waitFor(() => h.currentSong?.id == 'b');
      final tail = p.tail!;
      await waitFor(() => tail.disposed);
      expect(tail.volumes.last, lessThan(0.25), reason: 'the outgoing song faded out instead of being cut off');
      expect(main.volumes.last, 1.0);
    });
  });

  group('keyboard shortcuts', () {
    Future<List<PlayerShortcut>> pump(WidgetTester tester) async {
      final pressed = <PlayerShortcut>[];
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopShortcuts(
            onShortcut: pressed.add,
            child: const Scaffold(body: Center(child: TextField())),
          ),
        ),
      );
      return pressed;
    }

    testWidgets('space plays and pauses, ctrl+arrows skip', (tester) async {
      final pressed = await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(pressed, [PlayerShortcut.playPause, PlayerShortcut.next]);
    });

    testWidgets('typing in a text field types, instead of playing', (tester) async {
      final pressed = await pump(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(pressed, isEmpty);
    });
  });
}
