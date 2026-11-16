// What Get music suggests before a search: albums by artists Deezer pairs
// with the ones played most, against a fake Deezer answering with recorded
// replies (test/fixtures/deezer: Kirk Franklin's related artists) and made-up
// ones for the edges.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/data/deezer/deezer_client.dart';
import 'package:sonar/data/discovery.dart';
import 'package:sonar/data/soulbeet/get_music_suggestions.dart';
import 'package:sonar/data/soulbeet/soulbeet_client.dart';
import 'package:sonar/data/subsonic/subsonic_client.dart';
import 'package:sonar/state/providers.dart';
import 'package:sonar/state/soulbeet_providers.dart';

import 'support/fake_deezer.dart';
import 'support/fake_server.dart';

Map<String, Object?> _artists(List<(int, String)> found) => {
  'data': [
    for (final (id, name) in found) {'id': id, 'name': name, 'nb_fan': 10},
  ],
};

Map<String, Object?> _albums(List<(int, String, String)> found) => {
  'data': [
    for (final (id, title, kind) in found) {'id': id, 'title': title, 'record_type': kind, 'fans': 100 - id % 100},
  ],
};

/// Navidrome answering the suggestions' few questions.
class _Library implements HttpClientAdapter {
  _Library({required this.newest, required this.artists});
  final List<String> newest;
  final List<String> artists;
  final asked = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? _, Future<void>? _) async {
    final endpoint = o.uri.pathSegments.last;
    asked.add('$endpoint ${o.uri.queryParameters['type'] ?? ''}'.trim());
    final Map<String, Object?> body = switch (endpoint) {
      'getAlbumList2' => {
        'albumList2': {
          'album': [
            for (final (i, a) in newest.indexed) {'id': 'al$i', 'name': 'Album $i', 'artist': a, 'artistId': 'ar$i'},
          ],
        },
      },
      'getArtists' => {
        'artists': {
          'index': [
            {
              'name': '#',
              'artist': [
                for (final (i, a) in artists.indexed) {'id': 'ar$i', 'name': a},
              ],
            },
          ],
        },
      },
      _ => {},
    };
    return ResponseBody.fromString(
      jsonEncode({
        'subsonic-response': {'status': 'ok', ...body},
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late FakeDeezer deezer;
  late DeezerClient dz;

  setUp(() async {
    deezer = await FakeDeezer.start();
    dz = DeezerClient(base: deezer.base, quotaWait: const Duration(milliseconds: 10));
  });
  tearDown(() async {
    dz.close();
    await deezer.close();
  });

  Future<MusicSuggestions> suggest(List<String> played, {List<String> owned = const [], int perRow = 6}) =>
      suggestMusic(dz, played: played, owned: [...played, ...owned], perRow: perRow).last;
  List<String> artistsIn(SuggestionRow row) => [for (final a in row.albums) a.artist];
  int relatedAsked() => deezer.requests.where((r) => r.path.endsWith('/related')).length;

  test("Kirk Franklin: his related artists' best-known albums, leaving out who's owned", () async {
    final s = await suggest(['Kirk Franklin'], owned: ['Jonathan McReynolds']);
    expect(s.done, isTrue);
    final row = s.rows.single;
    expect(row.because, 'Kirk Franklin');
    expect(artistsIn(row), [
      'Fred Hammond',
      'Marvin Sapp',
      'Donnie McClurkin',
      'Deitrick Haddon',
      'Tye Tribbett',
      'Israel & New Breed',
    ], reason: 'Kirk Franklin & The Family is him; Jonathan McReynolds is owned; six a row');
    expect(row.albums.first.title, 'I Will Trust', reason: "Fred Hammond's most followed album");
    expect(row.albums.first.deezerId, isNotNull, reason: 'opens like an album found on Deezer');
    expect(relatedAsked(), 1);
  });

  test('fewer a row when asked', () async {
    final row = (await suggest(['Kirk Franklin'], perRow: 2)).rows.single;
    expect(artistsIn(row), ['Fred Hammond', 'Jonathan McReynolds']);
  });

  test('rows come in as each played artist is looked at', () async {
    deezer.queued['/search/artist'] = [
      _artists([(1, 'Zed')]),
    ];
    deezer.queued['/artist/1/related'] = [
      _artists([(2, 'Ann')]),
    ];
    deezer.queued['/artist/2/albums'] = [
      _albums([(20, 'Debut', 'album')]),
    ];
    final steps = await suggestMusic(dz, played: ['Zed', 'Kirk Franklin'], owned: const []).toList();
    expect(
      [for (final s in steps) '${s.rows.map((r) => r.because).join(', ')}${s.done ? ' (done)' : ''}'],
      ['Zed', 'Zed, Kirk Franklin', 'Zed, Kirk Franklin (done)'],
    );
  });

  test('a studio album before a compilation or a hits set, and an artist whose albums fail is left out', () async {
    deezer.queued['/search/artist'] = [
      _artists([(1, 'Zed')]),
    ];
    deezer.queued['/artist/1/related'] = [
      _artists([(2, 'Ann'), (3, 'Bob'), (4, 'Cee'), (5, 'Dee')]),
    ];
    // Most followed first (the made-up fans fall as the ids rise).
    deezer.queued['/artist/2/albums'] = [
      _albums([(20, 'Live Set', 'compile'), (21, 'Debut', 'album')]),
    ];
    deezer.queued['/artist/3/albums'] = [
      _albums([(30, 'Only Hits', 'compile')]),
    ];
    // Cee's albums: no recording, so Deezer's "no data" error.
    deezer.queued['/artist/5/albums'] = [
      _albums([(50, 'The Best Of Dee', 'album'), (51, 'Roots', 'album')]),
    ];
    final row = (await suggest(['Zed'])).rows.single;
    expect(
      [for (final a in row.albums) '${a.artist}: ${a.title}'],
      ['Ann: Debut', 'Bob: Only Hits', 'Dee: Roots'],
      reason: 'Deezer calls "The Best Of Dee" an album',
    );
  });

  test('an artist already suggested is not suggested again', () async {
    deezer.queued['/search/artist'] = [
      _artists([(1, 'Zed')]),
      _artists([(5, 'Yan')]),
    ];
    deezer.queued['/artist/1/related'] = [
      _artists([(2, 'Ann'), (3, 'Bob')]),
    ];
    deezer.queued['/artist/5/related'] = [
      _artists([(3, 'Bob'), (6, 'Cat')]),
    ];
    deezer.queued['/artist/2/albums'] = [
      _albums([(20, 'A1', 'album')]),
    ];
    deezer.queued['/artist/3/albums'] = [
      _albums([(30, 'B1', 'album')]),
    ];
    deezer.queued['/artist/6/albums'] = [
      _albums([(60, 'C1', 'album')]),
    ];
    final s = await suggest(['Zed', 'Yan']);
    expect([for (final r in s.rows) '${r.because}: ${artistsIn(r).join(', ')}'], ['Zed: Ann, Bob', 'Yan: Cat']);
  });

  test("a played artist Deezer doesn't have by that name gets no row, and the next still does", () async {
    deezer.queued['/search/artist'] = [
      _artists([(1, 'Zedd')]),
    ];
    final s = await suggest(['Zed', 'Kirk Franklin']);
    expect([for (final r in s.rows) r.because], ['Kirk Franklin']);
    expect(relatedAsked(), 1, reason: 'no related artists asked for the wrong Zed');
  });

  test('Deezer failing for one played artist leaves the others', () async {
    deezer.queued['/search/artist'] = [
      {
        'error': {'type': 'Exception', 'message': 'broken', 'code': 100},
      },
    ];
    final s = await suggest(['Zed', 'Kirk Franklin']);
    expect([for (final r in s.rows) r.because], ['Kirk Franklin']);
    expect(s.done, isTrue);
  });

  test('Deezer down: nothing suggested, and done', () async {
    deezer.down = true;
    final s = await suggest(['Kirk Franklin']);
    expect(s.rows, isEmpty);
    expect(s.done, isTrue);
  });

  test('a short owned name must match whole: owning Ye leaves Yeat suggestible', () async {
    deezer.queued['/search/artist'] = [
      _artists([(1, 'Zed')]),
    ];
    deezer.queued['/artist/1/related'] = [
      _artists([(2, 'Yeat'), (3, 'Ye')]),
    ];
    deezer.queued['/artist/2/albums'] = [
      _albums([(20, 'Lyfe', 'album')]),
    ];
    final row = (await suggest(['Zed'], owned: ['Ye'])).rows.single;
    expect(artistsIn(row), ['Yeat']);
  });

  group('built around', () {
    test('the most played artists, each once, four at most, never Various Artists', () {
      expect(suggestionSeeds(['A', 'Various Artists', 'B', 'a', 'C', 'D', 'E'], ['N']), ['A', 'B', 'C', 'D']);
    });

    test('before anything is played, the artists of the albums added last', () {
      expect(suggestionSeeds([], ['N', 'M', 'N']), ['N', 'M']);
    });
  });

  group('from the library', () {
    Future<(MusicSuggestions, _Library)> fromLibrary({required List<MixSeed> top, bool soulbeet = true}) async {
      final library = _Library(
        newest: ['Kirk Franklin', 'Various Artists'],
        artists: ['Kirk Franklin', 'Fred Hammond'],
      );
      final container = ProviderContainer(
        overrides: [
          clientProvider.overrideWithValue(SubsonicClient(testCreds, dio: Dio()..httpClientAdapter = library)),
          soulbeetClientProvider.overrideWithValue(
            soulbeet ? SoulbeetClient(base: Uri.parse('http://127.0.0.1:9'), username: 'u', password: 'p') : null,
          ),
          mixSeedsProvider.overrideWith((_) async => top),
          deezerClientProvider.overrideWithValue(dz),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(getMusicSuggestionsProvider, (_, _) {});
      addTearDown(sub.close);
      for (var i = 0; i < 200 && container.read(getMusicSuggestionsProvider).valueOrNull?.done != true; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return (container.read(getMusicSuggestionsProvider).requireValue, library);
    }

    test('nothing played yet: around the newest albums, leaving out artists the library has', () async {
      final (s, library) = await fromLibrary(top: const []);
      final row = s.rows.single;
      expect(row.because, 'Kirk Franklin');
      expect(artistsIn(row), isNot(contains('Fred Hammond')), reason: 'in the library');
      expect(artistsIn(row).first, 'Jonathan McReynolds');
      expect(library.asked, containsAll(['getAlbumList2 newest', 'getArtists']));
    });

    test('around the most played, without asking for the newest', () async {
      final (s, library) = await fromLibrary(
        top: const [MixSeed(artistId: 'ar0', artist: 'Kirk Franklin')],
      );
      expect(s.rows.single.because, 'Kirk Franklin');
      expect(library.asked, isNot(contains('getAlbumList2 newest')));
    });

    test('no Soulbeet: nothing suggested, and neither the library nor Deezer asked', () async {
      final (s, library) = await fromLibrary(
        top: const [MixSeed(artistId: 'ar0', artist: 'Kirk Franklin')],
        soulbeet: false,
      );
      expect(s.rows, isEmpty);
      expect(s.done, isTrue);
      expect(library.asked, isEmpty);
      expect(deezer.requests, isEmpty);
    });
  });
}
