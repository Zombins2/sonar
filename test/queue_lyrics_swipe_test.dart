import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/audio/audio_handler.dart';
import 'package:sonar/data/lyrics/lrclib_client.dart';
import 'package:sonar/data/subsonic/models.dart';
import 'package:sonar/data/subsonic/subsonic_client.dart';
import 'package:sonar/state/providers.dart';
import 'package:sonar/ui/widgets/track_swipe.dart';

import 'support/fake_server.dart';

void main() {
  group('queueInsertIndex', () {
    test('goes straight after the current track when nothing is queued', () {
      expect(queueInsertIndex([false, false, false, false], 1), 2);
    });

    test('goes after songs already queued, ahead of the rest of the album', () {
      // album, CURRENT, queued, queued, album, album
      expect(queueInsertIndex([false, false, true, true, false, false], 1), 4);
    });

    test('queued songs that already played do not count', () {
      expect(queueInsertIndex([true, true, false, false], 2), 3);
    });

    test('appends when the current track is last', () {
      expect(queueInsertIndex([false, false, true], 1), 3);
    });
  });

  group('Lyrics.fromLrc', () {
    test('parses stamps, skips metadata, splits repeated lines, sorts', () {
      final l = Lyrics.fromLrc(
        '[ar:Bob Marley]\n'
        '[00:08.89] Buffalo Soldier\r\n'
        '[01:00.00][00:30.5]Chorus <00:31.00>line\n'
        'no stamp here\n',
      )!;
      expect(l.synced, isTrue);
      expect(l.lines.map((x) => x.text), ['Buffalo Soldier', 'Chorus line', 'Chorus line']);
      expect(l.lines.map((x) => x.start), [
        const Duration(milliseconds: 8890),
        const Duration(milliseconds: 30500),
        const Duration(minutes: 1),
      ]);
    });

    test('is null without any timed line', () {
      expect(Lyrics.fromLrc('just words\nmore words'), isNull);
    });
  });

  group('LrclibClient', () {
    Map<String, Object> hit(double seconds, {String? lrc, bool instrumental = false}) => {
      'trackName': 'Mix Up, Mix Up',
      'duration': seconds,
      'instrumental': instrumental,
      'syncedLyrics': ?lrc,
    };

    LrclibClient lrclib(List<Object> results) => LrclibClient(
      dio: Dio(BaseOptions(baseUrl: 'https://lrclib.net'))..httpClientAdapter = FakeAdapter({'search': results}),
    );

    test('picks the synced result whose length matches the file', () async {
      final client = lrclib([
        hit(287, lrc: '[00:01.00] single edit'),
        hit(302, lrc: null), // plain only
        hit(303, lrc: '[00:01.00] album cut'),
        hit(302.5, instrumental: true, lrc: '[00:01.00] instrumental'),
      ]);
      final lrc = await client.findLrc(
        title: 'Mix Up, Mix Up',
        artist: 'Bob Marley',
        duration: const Duration(milliseconds: 302640),
      );
      expect(lrc, '[00:01.00] album cut');
    });

    test('rejects matches from a different-length recording', () async {
      final client = lrclib([hit(287, lrc: '[00:01.00] single edit')]);
      final lrc = await client.findLrc(
        title: 'Mix Up, Mix Up',
        artist: 'Bob Marley',
        duration: const Duration(milliseconds: 302640),
      );
      expect(lrc, isNull);
    });
  });

  group('resolveLyrics', () {
    const plain = Lyrics(synced: false, lines: [LyricLine('words')]);
    const synced = Lyrics(synced: true, lines: [LyricLine('words', Duration.zero)]);
    const online = Lyrics(synced: true, lines: [LyricLine('online', Duration.zero)], credit: 'LRCLIB');

    test('keeps synced server lyrics without going online', () async {
      var asked = false;
      final l = await resolveLyrics(() async => synced, () async {
        asked = true;
        return online;
      });
      expect(l, same(synced));
      expect(asked, isFalse);
    });

    test('upgrades plain server lyrics to synced online ones', () async {
      expect(await resolveLyrics(() async => plain, () async => online), same(online));
    });

    test('falls back to plain when the lookup misses or fails', () async {
      expect(await resolveLyrics(() async => plain, () async => null), same(plain));
      expect(
        await resolveLyrics(() async => plain, () async => throw DioException(requestOptions: RequestOptions())),
        same(plain),
      );
    });

    test('still goes online when the server has none or is unreachable', () async {
      expect(await resolveLyrics(() async => null, () async => online), same(online));
      expect(
        await resolveLyrics(
          () async => throw const SubsonicException(SubsonicErrorKind.unreachable, 'x'),
          () async => online,
        ),
        same(online),
      );
    });

    test('stays with the server when the online lookup is off', () async {
      expect(await resolveLyrics(() async => plain, null), same(plain));
    });
  });

  group('TrackSwipe', () {
    Future<List<String>> swipe(WidgetTester tester, Offset by) async {
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 300,
              height: 60,
              child: TrackSwipe(
                onNext: () => calls.add('next'),
                onPrevious: () => calls.add('previous'),
                child: const ColoredBox(key: Key('content'), color: Colors.red, child: Text('Song')),
              ),
            ),
          ),
        ),
      );
      await tester.timedDrag(find.byType(TrackSwipe), by, const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      return calls;
    }

    testWidgets('swipe left skips to the next track', (tester) async {
      expect(await swipe(tester, const Offset(-150, 0)), ['next']);
    });

    testWidgets('swipe right goes to the previous track', (tester) async {
      expect(await swipe(tester, const Offset(150, 0)), ['previous']);
    });

    testWidgets('a short drag springs back without changing track', (tester) async {
      expect(await swipe(tester, const Offset(-40, 0)), isEmpty);
      expect(tester.getTopLeft(find.byKey(const Key('content'))).dx, tester.getTopLeft(find.byType(TrackSwipe)).dx);
    });
  });
}
