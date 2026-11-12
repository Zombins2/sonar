import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/audio/playback_source.dart';
import 'package:sonar/audio/transitions.dart';
import 'package:sonar/data/subsonic/models.dart';

import 'support/fake_server.dart';
import 'support/player_harness.dart';

const _song = testSong;

void main() {
  group('crossfade rules', () {
    test('an album played in order runs on without a fade, across discs too', () {
      final t1 = _song('1', albumId: 'x', track: 1);
      expect(continuesAlbum(t1, _song('2', albumId: 'x', track: 2)), isTrue);
      expect(continuesAlbum(_song('9', albumId: 'x', track: 9), _song('10', albumId: 'x', track: 1, disc: 2)), isTrue);
      expect(continuesAlbum(t1, _song('3', albumId: 'x', track: 3)), isFalse, reason: 'skipped a track (shuffle)');
      expect(continuesAlbum(t1, _song('2', albumId: 'y', track: 2)), isFalse);
      expect(
        continuesAlbum(_song('a', albumId: 'x'), _song('b', albumId: 'x')),
        isFalse,
        reason: 'no track numbers',
      );
    });

    test('fades only when there is a next song and nothing says to stop', () {
      final a = _song('a', albumId: 'x', track: 1);
      final b = _song('b', albumId: 'y', track: 4);
      bool go({int seconds = 6, Song? next, bool repeatOne = false, bool stop = false}) =>
          shouldCrossfade(seconds: seconds, current: a, next: next, repeatOne: repeatOne, stopAfterTrack: stop);
      expect(go(next: b), isTrue);
      expect(go(next: b, seconds: 0), isFalse, reason: 'crossfade off');
      expect(go(), isFalse, reason: 'end of the queue');
      expect(go(next: b, repeatOne: true), isFalse);
      expect(go(next: b, stop: true), isFalse, reason: 'sleep timer set to the end of this track');
      expect(
        go(next: _song('a2', albumId: 'x', track: 2)),
        isFalse,
        reason: 'album continues',
      );
    });

    test('the fade starts on a whole second and shortens for short songs', () {
      expect(crossfadeStart(const Duration(seconds: 200, milliseconds: 700), 6), const Duration(seconds: 194));
      expect(crossfadeStart(const Duration(seconds: 10), 6), const Duration(seconds: 8), reason: 'a quarter of 10 s');
      expect(crossfadeStart(const Duration(seconds: 3), 6), isNull);
    });

    test('equal-power levels keep the overall loudness steady', () {
      expect(crossfadeLevels(0), (1.0, 0.0));
      final (out, incoming) = crossfadeLevels(1);
      expect(out, closeTo(0, 1e-9));
      expect(incoming, 1.0);
      for (final t in [0.1, 0.3, 0.5, 0.8]) {
        final (o, i) = crossfadeLevels(t);
        expect(o * o + i * i, closeTo(1, 1e-9));
      }
    });
  });

  group('volume levelling', () {
    const gain = ReplayGain(trackGain: -6, albumGain: -3);

    test('turns loud songs down, never up', () {
      expect(levelledVolume(gain, album: false), closeTo(0.501, 0.001));
      expect(levelledVolume(gain, album: true), closeTo(0.708, 0.001));
      expect(levelledVolume(const ReplayGain(trackGain: 4), album: false), 1);
      expect(levelledVolume(null, album: false), 1);
      expect(levelledVolume(const ReplayGain(trackGain: -6), album: true), closeTo(0.501, 0.001), reason: 'falls back');
    });

    test('album gain only for an album played in order', () {
      const album = PlaybackSource(SourceKind.album, 'al1', 'A');
      expect(preferAlbumGain(album, shuffled: false), isTrue);
      expect(preferAlbumGain(album, shuffled: true), isFalse);
      expect(preferAlbumGain(const PlaybackSource(SourceKind.playlist, 'p', 'P'), shuffled: false), isFalse);
      expect(preferAlbumGain(null, shuffled: false), isFalse);
    });

    test('reads OpenSubsonic replayGain, treating missing tags as none, and survives the saved queue', () {
      final song = Song.fromJson({
        'id': 's1',
        'title': 'T',
        'replayGain': {'trackGain': -7.5, 'albumGain': -6.1, 'trackPeak': 0.98},
      });
      expect(song.replayGain?.trackGain, -7.5);
      expect(Song.fromJson(song.toJson()).replayGain?.albumGain, -6.1);
      expect(Song.fromJson({'id': 's', 'title': 'T', 'replayGain': <String, Object>{}}).replayGain, isNull);
      expect(
        Song.fromJson({
          'id': 's',
          'title': 'T',
          'replayGain': {'trackGain': 0},
        }).replayGain,
        isNull,
      );
    });
  });

  test('stream URLs start part-way in only when asked, and never carry the password', () {
    final client = fakeServer({}).client;
    final url = client.streamUrl('s1', maxBitRate: 192, timeOffset: 194);
    expect(url.queryParameters['timeOffset'], '194');
    expect(client.streamUrl('s1').queryParameters.containsKey('timeOffset'), isFalse);
    expect(url.toString(), isNot(contains(testCreds.password)));
  });

  group('the player', () {
    final p = PlayerHarness();
    setUp(p.setUp);
    tearDown(p.tearDown);

    test('crossfades into a song from another album', () async {
      final h = await p.start([_song('a', albumId: 'x', track: 1), _song('b', albumId: 'y', track: 1)]);
      final main = p.platform.players.first;
      // A 20 s song with a 1 s fade: the tail loads at 17 s, the fade starts at 19 s.
      await h.seek(const Duration(seconds: 16, milliseconds: 400));
      await waitFor(() => h.currentSong?.id == 'b');
      final tail = p.tail!;
      expect(tail.loads.single.uris.single.queryParameters['id'], 'a', reason: 'the tail plays the outgoing song');
      expect(tail.loads.single.position, const Duration(seconds: 17));
      expect(main.seeks.last, (Duration.zero, 1), reason: 'the main player moved on to the next song');
      expect(main.volumes, contains(0.0), reason: 'silent while the tail carried the outgoing song');

      await waitFor(() => tail.disposed);
      expect(main.volumes.last, 1.0, reason: 'faded fully in');
      expect(tail.volumes.reduce(max), closeTo(1, 0.1));
      expect(tail.volumes.last, lessThan(0.25), reason: 'faded out before it stopped');
    });

    test('a transcoded stream is started part-way in by the server instead of seeking', () async {
      final h = await p.start([_song('a'), _song('b')], bitrate: 192);
      await h.seek(const Duration(seconds: 16, milliseconds: 400));
      await waitFor(() => p.tail?.loads.isNotEmpty ?? false);
      final load = p.tail!.loads.single;
      expect(load.uris.single.queryParameters['timeOffset'], '17');
      expect(load.uris.single.queryParameters['maxBitRate'], '192');
      expect(load.position ?? Duration.zero, Duration.zero);
      await waitFor(() => h.currentSong?.id == 'b');
    });

    test('the next track of the same album plays gapless, with no fade', () async {
      final h = await p.start([_song('a', albumId: 'x', track: 1), _song('b', albumId: 'x', track: 2)]);
      final main = p.platform.players.first;
      // Early enough that a crossfade would have loaded its tail.
      await h.seek(const Duration(seconds: 16, milliseconds: 400));
      await waitFor(() => h.currentSong?.id == 'b');
      expect(p.platform.players, hasLength(1), reason: 'no tail player');
      expect(main.volumes, isNot(contains(0.0)));
      expect(main.seeks.last.$2, isNull, reason: 'the player rolled over on its own');
    });

    test('pausing mid-fade stops the tail and brings the new song to full volume', () async {
      final h = await p.start([_song('a'), _song('b')]);
      final main = p.platform.players.first;
      await h.seek(const Duration(seconds: 16, milliseconds: 400));
      await waitFor(() => h.currentSong?.id == 'b');
      await h.pause();
      await waitFor(() => p.tail!.disposed, timeout: const Duration(milliseconds: 500));
      expect(main.volumes.last, 1.0);
    });

    test('levels each song with its own gain, or the album gain for an album in order', () async {
      const gain = ReplayGain(trackGain: -6, albumGain: -3);
      final songs = [_song('a', gain: gain), _song('b')];
      await p.start(songs);
      await waitFor(() => p.platform.players.first.volumes.isNotEmpty);
      expect(p.platform.players.first.volumes.last, closeTo(0.501, 0.001));

      await p.start(songs, source: const PlaybackSource(SourceKind.album, 'al', 'A'));
      final album = p.platform.players.last;
      await waitFor(() => album.volumes.isNotEmpty);
      expect(p.platform.players, hasLength(2));
      expect(album.volumes.last, closeTo(0.708, 0.001));
    });

    test('with levelling off the volume stays put', () async {
      await p.start([_song('a', gain: const ReplayGain(trackGain: -6)), _song('b')], level: false);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(p.platform.players.first.volumes.where((v) => v != 1), isEmpty);
    });
  });
}
