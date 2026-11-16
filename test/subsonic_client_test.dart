import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/data/subsonic/models.dart';
import 'package:sonar/data/subsonic/subsonic_client.dart';

import 'support/fake_server.dart';

void main() {
  group('auth', () {
    test('token is md5(password + salt) with a fresh salt, and the password never appears', () {
      final t = fakeServer({});
      final a = t.client.buildUrl('ping');
      final b = t.client.buildUrl('ping');
      final q = a.queryParameters;

      expect(q['u'], 'alice');
      expect(q['v'], '1.16.1');
      expect(q['c'], 'sonar');
      expect(q['f'], 'json');
      expect(q['s']!.length, greaterThanOrEqualTo(6));
      expect(q['t'], md5.convert(utf8.encode('s3cret!${q['s']}')).toString());
      expect(q['s'], isNot(b.queryParameters['s']));
      expect(a.toString(), isNot(contains('s3cret')));
      expect(q.containsKey('p'), isFalse);
      expect(a.path, '/rest/ping');
    });
  });

  group('normaliseUrl', () {
    test('adds https and strips trailing slash', () {
      expect(SubsonicClient.normaliseUrl(' host.ts.net/ '), 'https://host.ts.net');
    });

    test('rejects plain http', () {
      expect(
        () => SubsonicClient.normaliseUrl('http://host.ts.net'),
        throwsA(isA<SubsonicException>().having((e) => e.kind, 'kind', SubsonicErrorKind.notHttps)),
      );
    });

    test('allows plain http only to this same computer', () {
      expect(SubsonicClient.normaliseUrl('http://localhost:4533/'), 'http://localhost:4533');
      expect(SubsonicClient.normaliseUrl('http://127.0.0.1:4533'), 'http://127.0.0.1:4533');
      for (final elsewhere in ['http://192.168.1.20:4533', 'http://localhost.evil.com', 'http://127.0.0.1.nip.io']) {
        expect(
          () => SubsonicClient.normaliseUrl(elsewhere),
          throwsA(isA<SubsonicException>()),
          reason: '$elsewhere is not this computer',
        );
      }
    });
  });

  group('responses', () {
    test('error code 40 maps to bad credentials', () async {
      final t = fakeServer({
        'ping': {
          'subsonic-response': {
            'status': 'failed',
            'error': {'code': 40, 'message': 'Wrong username or password'},
          },
        },
      });
      await expectLater(
        t.client.ping(),
        throwsA(isA<SubsonicException>().having((e) => e.kind, 'kind', SubsonicErrorKind.badCredentials)),
      );
    });

    test('other server errors surface error.message', () async {
      final t = fakeServer({
        'getAlbum': {
          'subsonic-response': {
            'status': 'failed',
            'error': {'code': 70, 'message': 'Album not found'},
          },
        },
      });
      await expectLater(
        t.client.getAlbum('x'),
        throwsA(isA<SubsonicException>().having((e) => e.message, 'message', 'Album not found')),
      );
    });

    test('unreachable server reports offline and a network hint', () async {
      final t = fakeServer({})..adapter.offline = true;
      await expectLater(
        t.client.ping(),
        throwsA(
          isA<SubsonicException>()
              .having((e) => e.kind, 'kind', SubsonicErrorKind.unreachable)
              .having((e) => e.message, 'message', contains('Check your network')),
        ),
      );
      expect(t.reach, [false]);
    });

    test('cached reads are served back when the server goes away', () async {
      final t = fakeServer({
        'getAlbum': ok({
          'album': {
            'id': 'al1',
            'name': 'Blue',
            'artist': 'Joni',
            'songCount': 1,
            'duration': 200,
            'song': [
              {'id': 's1', 'title': 'All I Want', 'duration': 200, 'track': 1},
            ],
          },
        }),
      });
      final online = await t.client.getAlbum('al1');
      expect(online.songs.single.title, 'All I Want');
      expect(t.reach, [true]);

      t.adapter.offline = true;
      final offline = await t.client.getAlbum('al1');
      expect(offline.name, 'Blue');
      expect(offline.songs.single.duration, const Duration(seconds: 200));
      expect(t.reach, [true, false]);

      // Uncached endpoints still fail.
      await expectLater(t.client.getAlbum('other'), throwsA(isA<SubsonicException>()));
    });

    test('cache keys exclude auth params so they survive new salts', () async {
      final t = fakeServer({
        'getPlaylists': ok({
          'playlists': {'playlist': []},
        }),
      });
      await t.client.getPlaylists();
      await t.client.getPlaylists();
      expect(t.cache.store.keys, ['getPlaylists?']);
    });
  });

  group('endpoints', () {
    test('getArtists flattens the index', () async {
      final t = fakeServer({
        'getArtists': ok({
          'artists': {
            'index': [
              {
                'name': 'A',
                'artist': [
                  {'id': 'a1', 'name': 'ABBA', 'albumCount': 3},
                ],
              },
              // Single-element lists may arrive as a bare object.
              {
                'name': 'B',
                'artist': {'id': 'b1', 'name': 'Bowie'},
              },
            ],
          },
        }),
      });
      final artists = await t.client.getArtists();
      expect(artists.map((a) => a.name), ['ABBA', 'Bowie']);
      expect(artists.first.albumCount, 3);
    });

    test('scrobble sends submission flag', () async {
      final t = fakeServer({});
      await t.client.scrobble('s1', submission: false);
      await t.client.scrobble('s1', submission: true);
      expect(t.adapter.requests.map((u) => u.queryParameters['submission']), ['false', 'true']);
    });

    test('stream URL only caps bitrate when asked', () {
      final t = fakeServer({});
      expect(t.client.streamUrl('s1').queryParameters.containsKey('maxBitRate'), isFalse);
      expect(t.client.streamUrl('s1', maxBitRate: 192).queryParameters['maxBitRate'], '192');
    });

    test('createPlaylist repeats songId params', () async {
      final t = fakeServer({});
      await t.client.createPlaylist('Mix', songIds: ['a', 'b']);
      expect(t.adapter.requests.single.queryParametersAll['songId'], ['a', 'b']);
    });

    test('lyrics prefer the synced entry', () async {
      final t = fakeServer({
        'getLyricsBySongId': ok({
          'lyricsList': {
            'structuredLyrics': [
              {
                'synced': false,
                'line': [
                  {'value': 'plain'},
                ],
              },
              {
                'synced': true,
                'line': [
                  {'start': 0, 'value': 'one'},
                  {'start': 1500, 'value': 'two'},
                ],
              },
            ],
          },
        }),
      });
      final lyrics = await t.client.getLyrics('s1');
      expect(lyrics!.synced, isTrue);
      expect(lyrics.lines.last.start, const Duration(milliseconds: 1500));
    });
  });

  group('library scope (Discover kept apart)', () {
    Map<String, Object> songs(String key, List<String> ids) => ok({
      key: {
        'song': [for (final id in ids) Song(id: id, title: id).toJson()],
      },
    });

    Future<Map<String, List<String>?>> folderIdsAsked(LibraryScope scope) async {
      final t = fakeServer({}, scope: scope, withCache: false);
      await t.client.getAlbumList2(AlbumListType.newest);
      await t.client.getAlbumsByGenre('Reggae');
      await t.client.getRandomSongs();
      await t.client.getArtists();
      await t.client.search3('x');
      await t.client.getStarred2();
      return {for (final r in t.adapter.requests) r.pathSegments.last: r.queryParametersAll['musicFolderId']};
    }

    test('every library call names the libraries shown', () async {
      final asked = await folderIdsAsked(LibraryScope(folders: ['1']));
      expect(asked.keys, containsAll(['getAlbumList2', 'getRandomSongs', 'getArtists', 'search3', 'getStarred2']));
      expect(asked.values, everyElement(['1']));
    });

    test('several libraries are each named, as Navidrome takes them', () async {
      final asked = await folderIdsAsked(LibraryScope(folders: ['1', '3']));
      expect(asked.values, everyElement(['1', '3']));
    });

    test('no scope: every library, no folder named', () async {
      final asked = await folderIdsAsked(LibraryScope());
      expect(asked.values, everyElement(isNull));
    });

    test('similar and top songs leave out the hidden ones', () async {
      final scope = LibraryScope(hidden: {'d1'});
      final t = fakeServer({
        'getSimilarSongs2': songs('similarSongs2', ['a', 'd1', 'b']),
        'getTopSongs': songs('topSongs', ['d1', 'c']),
      }, scope: scope);
      expect([for (final s in await t.client.getSimilarSongs2('x')) s.id], ['a', 'b']);
      expect([for (final s in await t.client.getTopSongs('X')) s.id], ['c']);
      scope.hidden.clear(); // Kept: changed in place.
      expect([for (final s in await t.client.getSimilarSongs2('x')) s.id], ['a', 'd1', 'b']);
    });

    test('songsIn reads one library a page at a time, whatever the scope', () async {
      final adapter = _PagedSongs(5);
      final t = fakeServer(
        {},
        scope: LibraryScope(folders: ['1']),
        adapter: adapter,
      );
      final all = await t.client.songsIn('2', page: 2);
      expect([for (final s in all) s.id], ['s0', 's1', 's2', 's3', 's4']);
      expect([for (final r in adapter.requests) r.queryParameters['songOffset']], ['0', '2', '4']);
      expect({for (final r in adapter.requests) r.queryParameters['musicFolderId']}, {'2'});
      expect(all.first.size, 1000, reason: 'the file size, for the space limit');
      expect(all.first.created, DateTime.utc(2026, 11, 16));
    });

    test('getMusicFolders lists the libraries', () async {
      final t = fakeServer({
        'getMusicFolders': ok({
          'musicFolders': {
            'musicFolder': [
              {'id': 1, 'name': 'Music Library'},
              {'id': 2, 'name': 'Discover'},
            ],
          },
        }),
      });
      expect(await t.client.getMusicFolders(), [(id: '1', name: 'Music Library'), (id: '2', name: 'Discover')]);
    });
  });

  test('Song round-trips through JSON for queue persistence', () {
    const s = Song(
      id: '1',
      title: 'T',
      album: 'A',
      albumId: 'al',
      artist: 'Ar',
      artistId: 'ar',
      track: 3,
      duration: Duration(seconds: 61),
      coverArt: 'c',
      starred: true,
    );
    final back = Song.fromJson(s.toJson());
    expect(back.toJson(), s.toJson());
  });
}

/// [count] songs in a library, answered a page at a time as search3 does.
class _PagedSongs extends FakeAdapter {
  _PagedSongs(this.count) : super({});
  final int count;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    final q = options.uri.queryParameters;
    final from = int.parse(q['songOffset'] ?? '0');
    final page = int.parse(q['songCount'] ?? '20');
    responses['search3'] = ok({
      'searchResult3': {
        'song': [
          for (var i = from; i < count && i < from + page; i++)
            {'id': 's$i', 'title': 'Song $i', 'size': 1000, 'created': '2026-11-16T00:00:00Z'},
        ],
      },
    });
    return super.fetch(options, requestStream, cancelFuture);
  }
}
