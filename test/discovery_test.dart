import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/audio/playback_source.dart';
import 'package:sonar/data/discovery.dart';
import 'package:sonar/data/subsonic/models.dart';
import 'package:sonar/data/subsonic/subsonic_client.dart';

import 'support/fake_server.dart';

Song _s(String id, String artist, {String? artistId}) => Song(id: id, title: id, artist: artist, artistId: artistId);

Album _a(String id, String artistId, int plays) =>
    Album(id: id, name: id, artist: 'Artist $artistId', artistId: artistId, coverArt: 'cover-$id', playCount: plays);

List<String> _ids(List<Song> songs) => songs.map((s) => s.id).toList();

/// Answers by endpoint and id, which the shared fake can't.
class _Routed implements HttpClientAdapter {
  _Routed(this.respond);
  final Map<String, Object?> Function(String endpoint, Map<String, String> q) respond;
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? _, Future<void>? _) async {
    requests.add(o.uri);
    final body = {
      'subsonic-response': {'status': 'ok', ...respond(o.uri.pathSegments.last, o.uri.queryParameters)},
    };
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

(SubsonicClient, _Routed) _client(Map<String, Object?> Function(String endpoint, Map<String, String> q) respond) {
  final adapter = _Routed(respond);
  return (SubsonicClient(testCreds, dio: Dio()..httpClientAdapter = adapter), adapter);
}

Map<String, Object?> _songs(String key, List<Song> songs) => {
  key: {'song': songs.map((s) => s.toJson()).toList()},
};

void main() {
  group('queue shaping', () {
    test('uniqueSongs drops repeats and excluded ids, keeping the first copy', () {
      final songs = [_s('a', 'X'), _s('b', 'Y'), _s('a', 'X'), _s('c', 'Z')];
      expect(_ids(uniqueSongs(songs, exclude: ['c'])), ['a', 'b']);
    });

    test('spreadArtists avoids back-to-back artists where it can', () {
      final songs = [_s('1', 'A'), _s('2', 'A'), _s('3', 'A'), _s('4', 'B'), _s('5', 'B'), _s('6', 'C')];
      final out = spreadArtists(songs);
      expect(out.map((s) => s.id).toSet(), songs.map((s) => s.id).toSet());
      for (var i = 1; i < out.length; i++) {
        expect(out[i].artist, isNot(out[i - 1].artist), reason: 'repeat at $i: ${out.map((s) => s.artist)}');
      }
    });

    test('interleave puts a top song every third slot, then lets the rest run', () {
      final top = [_s('t1', 'A'), _s('t2', 'A'), _s('t3', 'A')];
      final rest = [_s('o1', 'B'), _s('o2', 'B'), _s('o3', 'B'), _s('o4', 'B')];
      expect(_ids(interleave(top, rest)), ['t1', 'o1', 'o2', 't2', 'o3', 'o4', 't3']);
    });
  });

  group('Home rows', () {
    test('topArtists sums plays across albums, skipping unplayed and artist-less ones', () {
      final albums = [
        _a('x1', 'x', 30),
        _a('y1', 'y', 25),
        _a('y2', 'y', 20), // y: 45 in total, ahead of x
        _a('z1', 'z', 0),
        const Album(id: 'v', name: 'Various', playCount: 99),
      ];
      final seeds = topArtists(albums);
      expect(seeds.map((s) => s.artistId), ['y', 'x']);
      expect(seeds.first.coverArt, 'cover-y1', reason: 'art comes from their most played album');
    });

    test('rediscover keeps played albums that are not among the recent ones', () {
      final frequent = [_a('a', 'x', 9), _a('b', 'x', 7), _a('c', 'x', 5), _a('d', 'x', 0)];
      expect(rediscover(frequent, [_a('b', 'x', 7)]).map((a) => a.id), ['a', 'c']);
    });

    test('unplayed keeps only albums with no plays', () {
      expect(unplayed([_a('a', 'x', 3), _a('b', 'x', 0), _a('c', 'x', 0)]).map((a) => a.id), ['b', 'c']);
    });

    test('mixSubtitle names the artist and the two they share the mix with most', () {
      const seed = MixSeed(artistId: 'ar1', artist: 'Juniper Vale');
      final songs = [_s('1', 'Juniper Vale'), _s('2', 'Fernhill'), _s('3', 'Sol'), _s('4', 'Sol'), _s('5', 'Quiet')];
      expect(mixSubtitle(seed, songs), 'Juniper Vale, Sol, Fernhill and more');
      expect(mixSubtitle(seed, [_s('1', 'Juniper Vale')]), 'Juniper Vale');
    });
  });

  group('autoplay', () {
    test('only tops up on the last track, with nothing repeating', () {
      bool go({bool enabled = true, bool repeating = false, int index = 4, int length = 5}) =>
          shouldAutoplay(enabled: enabled, repeating: repeating, index: index, length: length);
      expect(go(), isTrue);
      expect(go(index: 3), isFalse, reason: 'not the last track yet');
      expect(go(repeating: true), isFalse, reason: 'repeat already keeps it going');
      expect(go(enabled: false), isFalse);
      expect(go(index: 0, length: 0), isFalse);
    });

    test('appends similar songs that are not already in the queue', () {
      final queue = [_s('q1', 'A'), _s('q2', 'B')];
      final similar = [_s('q2', 'B'), _s('n1', 'C'), _s('n1', 'C'), _s('n2', 'D')];
      expect(_ids(autoplayPicks(similar, queue)), ['n1', 'n2']);
      expect(autoplayPicks([for (var i = 0; i < 40; i++) _s('n$i', 'A$i')], queue).length, 20);
    });
  });

  group('radio', () {
    test('song radio starts on the song, then similar ones without it', () async {
      final seed = _s('s1', 'A', artistId: 'ar1');
      final (client, _) = _client(
        (e, q) => e == 'getSimilarSongs2' ? _songs('similarSongs2', [_s('s1', 'A'), _s('s2', 'B'), _s('s3', 'C')]) : {},
      );
      expect(_ids(await songRadio(client, seed)), ['s1', 's2', 's3']);
    });

    test('song radio falls back to the artist when the track has no matches', () async {
      final seed = _s('s1', 'A', artistId: 'ar1');
      final (client, adapter) = _client(
        (e, q) => e == 'getSimilarSongs2' && q['id'] == 'ar1' ? _songs('similarSongs2', [_s('s9', 'B')]) : {},
      );
      expect(_ids(await songRadio(client, seed)), ['s1', 's9']);
      expect(adapter.requests.map((u) => u.queryParameters['id']), ['s1', 'ar1']);
    });

    test('artist radio mixes the artist’s top songs into similar artists', () async {
      final (client, adapter) = _client(
        (e, q) => switch (e) {
          'getTopSongs' => _songs('topSongs', [_s('t1', 'A'), _s('t2', 'A')]),
          'getSimilarSongs2' => _songs('similarSongs2', [_s('o1', 'B'), _s('o2', 'C'), _s('o3', 'D')]),
          _ => {},
        },
      );
      final radio = await artistRadio(client, 'ar1', 'A');
      expect(_ids(radio), ['t1', 'o1', 'o2', 't2', 'o3']);
      final topCall = adapter.requests.firstWhere((u) => u.pathSegments.last == 'getTopSongs');
      expect(topCall.queryParameters['artist'], 'A', reason: 'getTopSongs takes the name');
    });
  });

  group('mixes', () {
    Map<String, Object?> library(String e, Map<String, String> q) => switch (e) {
      'getTopSongs' => _songs('topSongs', [for (var i = 0; i < 20; i++) _s('own$i', 'Seed', artistId: 'ar1')]),
      'getSimilarSongs2' => _songs('similarSongs2', [
        for (var i = 0; i < 60; i++) _s('o$i', 'Other ${i % 6}', artistId: 'x${i % 6}'),
        _s('own0', 'Seed', artistId: 'ar1'), // the seed turning up among "similar"
      ]),
      _ => {},
    };
    const seed = MixSeed(artistId: 'ar1', artist: 'Seed');

    test('a third the artist, the rest others, no repeats', () async {
      final (client, _) = _client(library);
      final mix = await artistMix(client, seed, now: DateTime(2026, 10, 30));
      expect(mix.length, 30);
      expect(_ids(mix).toSet().length, 30);
      expect(mix.where((s) => s.artistId == 'ar1').length, 10);
    });

    test('same order all day, a new one tomorrow', () async {
      final (client, _) = _client(library);
      final morning = await artistMix(client, seed, now: DateTime(2026, 10, 30, 8));
      final evening = await artistMix(client, seed, now: DateTime(2026, 10, 30, 22));
      final tomorrow = await artistMix(client, seed, now: DateTime(2026, 10, 31, 8));
      expect(_ids(evening), _ids(morning));
      expect(_ids(tomorrow), isNot(_ids(morning)));
    });
  });

  group('API', () {
    test('similar songs, top songs and artist info parse; artists outside the library drop out', () async {
      final server = fakeServer({
        'getSimilarSongs2': ok({
          'similarSongs2': {
            'song': [
              {'id': 's1', 'title': 'One'},
            ],
          },
        }),
        'getTopSongs': ok({
          'topSongs': {
            'song': [
              {'id': 't1', 'title': 'Hit'},
            ],
          },
        }),
        'getArtistInfo2': ok({
          'artistInfo2': {
            'similarArtist': [
              {'id': 'ar2', 'name': 'In Library'},
              {'name': 'Not In Library'},
            ],
          },
        }),
      });
      expect(_ids(await server.client.getSimilarSongs2('s0', count: 7)), ['s1']);
      expect(server.adapter.requests.last.queryParameters['count'], '7');
      expect(_ids(await server.client.getTopSongs('Juniper Vale')), ['t1']);
      expect(server.adapter.requests.last.queryParameters['artist'], 'Juniper Vale');
      final info = await server.client.getArtistInfo2('ar1');
      expect(info.similarArtists.map((a) => a.name), ['In Library']);
    });
  });

  test('radio has no page to go back to; mixes do', () {
    expect(const PlaybackSource(SourceKind.radio, 's1', 'X Radio').path, isNull);
    expect(const PlaybackSource(SourceKind.mix, 'ar1', 'X Mix').path, 'mix/ar1');
  });
}
