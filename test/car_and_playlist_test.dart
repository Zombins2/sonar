import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/audio/car_browser.dart';
import 'package:sonar/audio/playback_source.dart';
import 'package:sonar/data/subsonic/subsonic_client.dart';

import 'support/fake_server.dart';

final albumResponse = ok({
  'album': {
    'id': 'al1',
    'name': 'Exodus',
    'artist': 'Bob Marley',
    'coverArt': 'c1',
    'song': [
      {'id': 's1', 'title': 'Natural Mystic', 'duration': 208},
      {'id': 's2', 'title': 'So Much Things to Say', 'duration': 188},
      {'id': 's3', 'title': 'Guiltiness', 'duration': 199},
    ],
  },
});

void main() {
  group('Android Auto menu', () {
    test('root lists the five folders, none playable', () async {
      final car = CarBrowser(fakeServer({}).client, null);
      final root = await car.children(AudioService.browsableRootId);
      expect(root.map((m) => m.title), ['Recently played', 'Recently added', 'Favorites', 'Playlists', 'Downloads']);
      expect(root.every((m) => m.playable == false), isTrue);
    });

    test('album folders browse into albums, then playable tracks', () async {
      final t = fakeServer({
        'getAlbumList2': ok({
          'albumList2': {
            'album': [
              {'id': 'al1', 'name': 'Exodus', 'artist': 'Bob Marley'},
            ],
          },
        }),
        'getAlbum': albumResponse,
      });
      final car = CarBrowser(t.client, null);

      final albums = await car.children('albums:newest');
      expect(albums.single.id, 'album:al1');
      expect(albums.single.playable, isFalse);
      expect(t.adapter.requests.last.queryParameters['type'], 'newest');

      final tracks = await car.children('album:al1');
      expect(tracks.map((m) => m.id), ['play:album:al1:0', 'play:album:al1:1', 'play:album:al1:2']);
      expect(tracks.every((m) => m.playable == true), isTrue);
    });

    test('a picked track resolves to the whole album, starting there, with the album as source', () async {
      final car = CarBrowser(fakeServer({'getAlbum': albumResponse}).client, null);
      final r = await car.resolve('play:album:al1:2');
      expect(r!.songs.map((s) => s.id), ['s1', 's2', 's3']);
      expect(r.index, 2);
      expect(r.source, const PlaybackSource(SourceKind.album, 'al1', ''));
      expect(r.source.title, 'Exodus');
    });

    test('unknown ids resolve to nothing', () async {
      final car = CarBrowser(fakeServer({}).client, null);
      expect(await car.resolve('album:al1'), isNull);
      expect(await car.children('nonsense'), isEmpty);
    });
  });

  group('playlist editing', () {
    test('replacing tracks sends playlistId and songIds in order, no name', () async {
      final t = fakeServer({});
      await t.client.replacePlaylistSongs('pl1', ['c', 'a', 'b']);
      final q = t.adapter.requests.single;
      expect(q.pathSegments.last, 'createPlaylist');
      expect(q.queryParameters['playlistId'], 'pl1');
      expect(q.queryParametersAll['songId'], ['c', 'a', 'b']);
      expect(q.queryParameters.containsKey('name'), isFalse);
    });

    test('rename and delete hit the right endpoints', () async {
      final t = fakeServer({});
      await t.client.renamePlaylist('pl1', 'Road Trip');
      await t.client.deletePlaylist('pl1');
      final [rename, delete] = t.adapter.requests;
      expect(rename.pathSegments.last, 'updatePlaylist');
      expect(rename.queryParameters['name'], 'Road Trip');
      expect(delete.pathSegments.last, 'deletePlaylist');
      expect(delete.queryParameters['id'], 'pl1');
    });

    test('a failed edit surfaces the server message', () async {
      final t = fakeServer({
        'deletePlaylist': {
          'subsonic-response': {
            'status': 'failed',
            'error': {'code': 50, 'message': 'Not authorized'},
          },
        },
      });
      await expectLater(
        t.client.deletePlaylist('pl1'),
        throwsA(isA<SubsonicException>().having((e) => e.message, 'message', 'Not authorized')),
      );
    });
  });
}
