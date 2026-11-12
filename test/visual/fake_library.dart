import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A small made-up library served as Subsonic JSON, routed by endpoint and id,
/// so screens render exactly as they would against Navidrome.
class FakeLibrary {
  static const artists = [
    ('ar1', 'Juniper Vale', 'c1'),
    ('ar2', 'The Night Ferries', 'c2'),
    ('ar3', 'Sol Marina', 'c3'),
    ('ar4', 'Fernhill', 'c4'),
    ('ar5', 'Neon Psalms', 'c5'),
    ('ar6', 'Quiet Engine', 'c6'),
  ];

  // id, name, artist index, cover, year
  static const albums = [
    ('al1', 'Low Tide Letters', 0, 'c1', 2024),
    ('al2', 'Harbour Lights', 1, 'c2', 2022),
    ('al3', 'Golden Hour Radio', 2, 'c3', 2025),
    ('al4', 'Moss & Granite', 3, 'c4', 2019),
    ('al5', 'Afterglow Hymns', 4, 'c5', 2023),
    ('al6', 'Static Weather', 5, 'c6', 2021),
    ('al7', 'Red Signal', 1, 'c7', 2018),
    ('al8', 'Coastline Archive', 0, 'c8', 2020),
  ];

  static const _titles = [
    'Paper Boats',
    'Salt in the Wiring',
    'Slow Return',
    'Lanterns',
    'Undertow',
    'Glass Harbour',
    'Northbound',
    'Kept Light',
    'Small Hours',
    'Carry Me Home',
    'Weathervane',
  ];

  static Map<String, Object?> song(int album, int track) {
    final a = albums[album];
    final ar = artists[a.$3];
    return {
      'id': 's$album-$track',
      'title': _titles[(track + album * 3) % _titles.length],
      'album': a.$2,
      'albumId': a.$1,
      'artist': ar.$2,
      'artistId': ar.$1,
      'track': track + 1,
      'discNumber': 1,
      'duration': 150 + (track * 37 + album * 23) % 160,
      'coverArt': a.$4,
      'suffix': 'flac',
      'bitRate': 920,
      'year': a.$5,
    };
  }

  /// Plays per album: Moss & Granite and Coastline Archive were never played.
  static const plays = [42, 9, 17, 0, 6, 25, 3, 0];

  static Map<String, Object?> album(int i, {bool withSongs = false}) {
    final a = albums[i];
    final ar = artists[a.$3];
    final songs = [for (var t = 0; t < 9 + i % 3; t++) song(i, t)];
    return {
      'id': a.$1,
      'name': a.$2,
      'artist': ar.$2,
      'artistId': ar.$1,
      'coverArt': a.$4,
      'year': a.$5,
      'playCount': plays[i],
      'songCount': songs.length,
      'duration': songs.fold<int>(0, (t, s) => t + (s['duration'] as int)),
      if (withSongs) 'song': songs,
    };
  }

  static Map<String, Object?> playlist(int i, {bool withSongs = false}) {
    const names = ['Late Night Drive', 'Sunday Coffee', 'Gym Rotation', 'Rainy Day'];
    final songs = [for (var k = 0; k < 14; k++) song((k + i * 2) % albums.length, (k * 3 + i) % 9)];
    return {
      'id': 'pl$i',
      'name': names[i],
      'owner': 'alice',
      'songCount': songs.length,
      'duration': songs.fold<int>(0, (t, s) => t + (s['duration'] as int)),
      'coverArt': albums[(i * 3) % albums.length].$4,
      'changed': '2026-10-2${i}T10:00:00Z',
      if (withSongs) 'entry': songs,
    };
  }

  static Map<String, Object?> _ok(Map<String, Object?> body) => {
    'subsonic-response': {'status': 'ok', 'version': '1.16.1', ...body},
  };

  static const lrc = [
    (0, 'Paper boats on a silver line'),
    (6, 'Folded from the letters I never sent'),
    (12, 'Carry them out where the harbour bends'),
    (18, 'Let the low tide read them aloud'),
    (24, ''),
    (28, 'And if the water keeps them'),
    (33, 'I will learn to keep the quiet'),
    (39, 'Paper boats on a silver line'),
    (45, 'Every one a little lighter'),
  ];

  static Map<String, Object?> respond(String endpoint, Map<String, String> q) {
    int indexOf(String id, String prefix) => int.tryParse(id.replaceFirst(prefix, '')) ?? 0;
    switch (endpoint) {
      case 'getAlbumList2':
        final type = q['type'];
        final order = switch (type) {
          'byGenre' => [1, 4, 5, 2, 7],
          'recent' => [2, 0, 4, 6, 3],
          // Most played first, as Navidrome sorts it.
          'frequent' => [0, 5, 2, 1, 4, 6],
          'random' => [6, 3, 7, 1, 4],
          'starred' => [4, 2],
          _ => [for (var i = 0; i < albums.length; i++) i],
        };
        final offset = int.tryParse(q['offset'] ?? '0') ?? 0;
        return _ok({
          'albumList2': {
            'album': offset > 0 ? [] : [for (final i in order) album(i)],
          },
        });
      case 'getAlbum':
        return _ok({'album': album(indexOf(q['id']!, 'al') - 1, withSongs: true)});
      case 'getArtists':
        return _ok({
          'artists': {
            'index': [
              {
                'name': '#',
                'artist': [
                  for (final a in artists)
                    {
                      'id': a.$1,
                      'name': a.$2,
                      'coverArt': a.$3,
                      'albumCount': albums.where((x) => artists[x.$3] == a).length,
                    },
                ],
              },
            ],
          },
        });
      case 'getArtist':
        final ai = indexOf(q['id']!, 'ar') - 1;
        final a = artists[ai];
        return _ok({
          'artist': {
            'id': a.$1,
            'name': a.$2,
            'coverArt': a.$3,
            'album': [
              for (var i = 0; i < albums.length; i++)
                if (albums[i].$3 == ai) album(i),
            ],
          },
        });
      case 'getPlaylists':
        return _ok({
          'playlists': {
            'playlist': [for (var i = 0; i < 4; i++) playlist(i)],
          },
        });
      case 'getPlaylist':
        return _ok({'playlist': playlist(indexOf(q['id']!, 'pl'), withSongs: true)});
      case 'search3':
        final query = (q['query'] ?? '').toLowerCase();
        final songOffset = int.tryParse(q['songOffset'] ?? '0') ?? 0;
        final allSongs = [
          for (var i = 0; i < albums.length; i++)
            for (var t = 0; t < 5; t++) song(i, t),
        ];
        bool hit(Object? s) => query.isEmpty || '$s'.toLowerCase().contains(query);
        return _ok({
          'searchResult3': {
            'artist': [
              for (final a in artists)
                if (query.isNotEmpty && hit(a.$2)) {'id': a.$1, 'name': a.$2, 'coverArt': a.$3, 'albumCount': 2},
            ],
            'album': [
              for (var i = 0; i < albums.length; i++)
                if (query.isNotEmpty && (hit(albums[i].$2) || hit(artists[albums[i].$3].$2))) album(i),
            ],
            'song': songOffset > 0
                ? []
                : [
                    for (final s in allSongs)
                      if (hit(s['title']) || hit(s['artist'])) s,
                  ],
          },
        });
      case 'getStarred2':
        return _ok({
          'starred2': {
            'album': [album(4), album(2)],
            'song': [song(0, 0)],
          },
        });
      case 'getGenres':
        const genres = ['Indie Folk', 'Dream Pop', 'Electronic', 'Jazz', 'Reggae', 'Ambient', 'Hip-Hop', 'Soul'];
        return _ok({
          'genres': {
            'genre': [
              for (var i = 0; i < genres.length; i++)
                {'value': genres[i], 'albumCount': 12 - i, 'songCount': 90 - i * 7},
            ],
          },
        });
      case 'getRandomSongs':
        return _ok({
          'randomSongs': {
            'song': [for (var i = 0; i < 6; i++) song(i, i)],
          },
        });
      case 'getTopSongs':
        final artist = artists.indexWhere((a) => a.$2 == q['artist']);
        return _ok({
          'topSongs': {
            'song': [
              for (var i = 0; i < albums.length; i++)
                if (albums[i].$3 == artist)
                  for (var t = 0; t < 4; t++) song(i, t),
            ],
          },
        });
      case 'getSimilarSongs2':
        // Songs by everyone else, a few from each album.
        final skip = q['id']!.startsWith('ar') ? indexOf(q['id']!, 'ar') - 1 : -1;
        return _ok({
          'similarSongs2': {
            'song': [
              for (var t = 0; t < 4; t++)
                for (var i = 0; i < albums.length; i++)
                  if (albums[i].$3 != skip) song(i, t + 4),
            ],
          },
        });
      case 'getArtistInfo2':
        final ai = indexOf(q['id']!, 'ar') - 1;
        return _ok({
          'artistInfo2': {
            'similarArtist': [
              for (var k = 1; k <= 4; k++)
                {
                  'id': artists[(ai + k) % artists.length].$1,
                  'name': artists[(ai + k) % artists.length].$2,
                  'coverArt': artists[(ai + k) % artists.length].$3,
                },
              // Navidrome lists artists missing from the library without an id.
              {'name': 'Not In Library'},
            ],
          },
        });
      case 'getLyricsBySongId':
        return _ok({
          'lyricsList': {
            'structuredLyrics': [
              {
                'lang': 'eng',
                'synced': true,
                'line': [
                  for (final (t, l) in lrc) {'start': t * 1000, 'value': l},
                ],
              },
            ],
          },
        });
    }
    return _ok({});
  }
}

class FakeLibraryAdapter implements HttpClientAdapter {
  /// Holds getAlbum back, to catch a page in its loading state.
  Future<void>? holdAlbums;

  /// Every request, in order.
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    final endpoint = options.uri.pathSegments.last;
    if (endpoint == 'getAlbum' && holdAlbums != null) await holdAlbums;
    final body = FakeLibrary.respond(endpoint, options.uri.queryParameters);
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
