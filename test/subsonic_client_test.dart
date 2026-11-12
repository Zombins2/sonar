import 'dart:convert';

import 'package:crypto/crypto.dart';
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
