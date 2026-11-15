// Get music's search on Deezer, and what's picked looked up on MusicBrainz,
// against fakes answering with replies recorded from the real ones
// (test/fixtures/deezer, test/fixtures/musicbrainz).
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/data/deezer/deezer_client.dart';
import 'package:sonar/data/musicbrainz/musicbrainz_client.dart';
import 'package:sonar/data/soulbeet/get_music_search.dart';
import 'package:sonar/data/soulbeet/soulbeet_models.dart';

import 'support/fake_deezer.dart';
import 'support/fake_musicbrainz.dart';

const _bully = '949407771', _bullyDeluxe = '1010171471';

void main() {
  late FakeDeezer deezer;
  late FakeMusicBrainz server;
  late DeezerClient dz;
  late MusicBrainzClient mb;

  setUp(() async {
    deezer = await FakeDeezer.start();
    server = await FakeMusicBrainz.start();
    dz = DeezerClient(base: deezer.base, quotaWait: const Duration(milliseconds: 10));
    mb = MusicBrainzClient(
      musicBrainz: server.base,
      listenBrainz: server.base,
      spacing: const Duration(milliseconds: 40),
      busyWait: const Duration(milliseconds: 10),
      deezer: dz,
    );
  });
  tearDown(() async {
    mb.close();
    dz.close();
    await deezer.close();
    await server.close();
  });

  /// [raw] as Get music searches it: Deezer, else MusicBrainz.
  Future<GetMusicResults> find(String raw) => findMusic(dz, mb, raw).last;
  List<String> titles(List<Object> found) => [for (final x in found) x is SbAlbum ? x.title : (x as SbTrack).title];
  String? topTitle(GetMusicResults r) => switch (r.topResult) {
    final TopArtist a => 'artist ${a.name}',
    final SbAlbum a => 'album ${a.title} by ${a.artist}',
    final SbTrack s => 'song ${s.title} by ${s.artist}',
    _ => null,
  };
  // The MusicBrainz searches made for the results (not looking up what's
  // likeliest picked, once done).
  List<(String, String)> musicBrainzSearches() => [
    for (final s in server.searches)
      if (!s.$2.startsWith('barcode:') && s.$1 != 'artist') s,
  ];

  group('searched on Deezer', () {
    test('"kanye bully": BULLY on top, found though MusicBrainz credits Ye', () async {
      final r = await find('kanye bully');
      expect(r.source, GetMusicSource.deezer);
      expect(topTitle(r), 'album BULLY by Kanye West');
      expect(titles(r.albums).take(2), ['BULLY', 'BULLY - DELUXE'], reason: 'the singles of it are left out');
      expect(titles(r.songs).first, 'BULLY (feat. CeeLo Green)');
      expect(
        titles(r.songs).where((t) => t == 'BULLY (feat. CeeLo Green)'),
        hasLength(1),
        reason: 'on the album and its deluxe pressing, listed once',
      );
      expect(r.artist, isNull, reason: 'no artist goes by "kanye bully"');
      expect(musicBrainzSearches(), isEmpty, reason: 'Deezer found it');
    });

    test('"kayne bully", misspelled, finds it all the same', () async {
      expect(topTitle(await find('kayne bully')), 'album BULLY by Kanye West');
    });

    test('"Kanye - Bully" searches both together, and BULLY is the name searched', () async {
      final r = await find('Kanye - Bully');
      expect(deezer.requests.map((q) => q.asked['q']).nonNulls.toSet(), {'Kanye Bully'});
      expect(r.query, 'Bully');
      expect(topTitle(r), 'album BULLY by Kanye West');
    });

    test('"kirk franklin love theory": the song, by its name and its artist\'s together', () async {
      final r = await find('kirk franklin love theory');
      expect(topTitle(r), 'song Love Theory by Kirk Franklin');
      expect(titles(r.albums), isNot(contains('Love Theory')), reason: 'a single: its song is found as a song');
      expect(titles(r.albums), contains('LONG LIVE LOVE'));
    });

    test('"kirk franklin": his card, his albums most followed first, his most played songs', () async {
      final r = await find('kirk franklin');
      expect(topTitle(r), 'artist Kirk Franklin');
      expect((r.topResult! as TopArtist).picture?.path, contains('2660594522987c3cf1ae90a879531cbc'));
      expect(titles(r.byArtist).take(4), [
        'Hello Fear',
        'The Essential Kirk Franklin',
        'Losing My Religion',
        'LONG LIVE LOVE',
      ]);
      expect(
        titles(r.byArtist).where((t) => t == 'Losing My Religion'),
        hasLength(1),
        reason: 'Deezer has a clean and an explicit copy',
      );
      expect(titles(r.songs).take(3), ['This Time', 'TOGETHER', 'I Smile']);
      expect(r.done, isTrue);
    });

    test('"kanye" is Kanye West, the most followed artist whose name starts so, not "Kanye"', () async {
      final r = await find('kanye');
      expect(topTitle(r), 'artist Kanye West');
      expect(titles(r.byArtist).first, 'My Beautiful Dark Twisted Fantasy');
      expect(titles(r.songs).first, 'Flashing Lights');
    });

    test('"bully" is not the band Bully: the best songs found are others\'', () async {
      final r = await find('bully');
      expect(r.artist, isNull);
      expect(topTitle(r), 'album BULLY by Kanye West');
    });

    test('too many requests at once: asked again', () async {
      deezer.queued['/search'] = [
        {
          'error': {'type': 'Exception', 'message': 'Quota limit exceeded', 'code': 4},
        },
      ];
      final r = await find('kanye bully');
      expect(topTitle(r), 'album BULLY by Kanye West');
      expect(deezer.requests.where((q) => q.path == '/search'), hasLength(2));
    });
  });

  group('MusicBrainz instead', () {
    test('when Deezer can\'t be reached', () async {
      deezer.down = true;
      final r = await find('kanye west');
      expect(r.source, GetMusicSource.musicBrainz);
      expect(r.artist, 'Ye (Kanye West)');
    });

    test('when Deezer finds nothing', () async {
      final r = await find('kanye west');
      expect(deezer.requests.map((q) => q.path), containsAll(['/search', '/search/album']));
      expect(r.source, GetMusicSource.musicBrainz, reason: '"kanye west" wasn\'t recorded from Deezer');
      expect(r.artist, 'Ye (Kanye West)');
    });

    test('never when Deezer found something', () async {
      await find('kirk franklin');
      expect(musicBrainzSearches(), isEmpty);
    });
  });

  group('what\'s picked, on MusicBrainz', () {
    SbAlbum picked(String id, String title) =>
        SbAlbum.deezer(id: id, title: title, artist: 'Kanye West', cover: Uri.parse('https://cdn.example/c.jpg'));

    test('by its barcode, in one request: the official pressing, keeping where it was found', () async {
      final album = picked(_bully, 'BULLY');
      expect(album.needsPressing, isTrue);
      final pressed = await mb.pressingOf(album);
      expect(pressed.mbid, '5fe938fb-e0a9-48ad-96f7-e950d8635aeb');
      expect(pressed.groupId, '56327267-51fb-472c-919e-d6ca258ebab2');
      expect(pressed.artist, 'Ye', reason: 'as MusicBrainz credits it, for beets');
      expect(pressed.needsPressing, isFalse);
      expect(pressed.deezerId, _bully, reason: 'so the result shows its download');
      expect(pressed.cover, album.cover);
      expect(server.searches, [('release', 'barcode:656465138828 OR barcode:0656465138828')]);
    });

    test('its songs come from that pressing', () async {
      final detail = await mb.songsOf(picked(_bully, 'BULLY'));
      expect(detail.album.mbid, '5fe938fb-e0a9-48ad-96f7-e950d8635aeb');
      expect(detail.album.deezerId, _bully);
      expect(detail.tracks, hasLength(18));
      expect(detail.tracks.every((t) => t.albumId == '5fe938fb-e0a9-48ad-96f7-e950d8635aeb'), isTrue);
    });

    test(
      'a barcode MusicBrainz lacks: by its name, by whoever goes by its artist\'s, brackets and dashes aside',
      () async {
        final pressed = await mb.pressingOf(picked(_bullyDeluxe, 'BULLY - DELUXE'));
        expect(pressed.groupId, 'dabbb756-f3e7-429b-8cf6-32efc2cecd10');
        expect(pressed.mbid, 'dd61c9ee-45bc-464c-ab3b-8fab8a05a5c9');
        expect(pressed.deezerId, _bullyDeluxe);
        expect(
          server.searches.where((s) => s.$1 == 'release-group').map((s) => s.$2).last,
          'releasegroup:"BULLY" AND (primarytype:album OR primarytype:ep) AND (arid:164f0d73-1234-4e2c-8743-d77bf2191051)',
          reason: 'an album, so not its single',
        );
      },
    );

    test('nowhere on MusicBrainz: says so', () async {
      deezer.queued['/album/42'] = [
        {
          'id': 42,
          'title': 'Nowhere',
          'upc': '000000000042',
          'record_type': 'album',
          'artist': {'name': 'Nobody'},
        },
      ];
      await expectLater(
        mb.pressingOf(SbAlbum.deezer(id: '42', title: 'Nowhere', artist: 'Nobody')),
        throwsA(isA<MusicBrainzException>().having((e) => e.message, 'message', contains('Search MusicBrainz'))),
      );
    });

    test('Deezer not answering about it: says so', () async {
      deezer.down = true;
      await expectLater(mb.pressingOf(picked(_bully, 'BULLY')), throwsA(isA<MusicBrainzException>()));
    });

    test('the likeliest picked are looked up ahead, once the search is done', () async {
      await find('kanye bully');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(server.searches, contains(('release', 'barcode:656465138828 OR barcode:0656465138828')));
    });
  });

  group('Deezer albums and songs', () {
    test('Sonar\'s notes never go to Soulbeet', () {
      final a = SbAlbum.deezer(id: '7', title: 'T', artist: 'A', cover: Uri.parse('https://cdn.example/c.jpg'));
      expect(a.request.keys, unorderedEquals(['id', 'title', 'artist', 'release_date']));
      final pressed = SbAlbum.found(pressing: 'p', groupId: 'g', title: 'T', artist: 'A', deezerId: '7');
      expect(pressed.request.keys, unorderedEquals(['id', 'title', 'artist', 'release_date', 'mbid']));
    });

    SbTrack song(String title, String artist) => SbTrack.deezer(id: title, title: title, artist: artist);

    test('the artist card: only when one of the best songs is theirs', () {
      const band = DeezerArtist('1', 'Bully', fans: 4017);
      expect(deezerArtistFor('bully', [band], [song('Bully', 'Shinedown'), song('BULLY', 'Kanye West')]), isNull);
      expect(deezerArtistFor('bully', [band], [song('Trying', 'Bully')]), band);
    });

    test('the artist card: the most followed of those with the name', () {
      const unknown = DeezerArtist('1', 'Kirk Franklin'), known = DeezerArtist('2', 'Kirk Franklin', fans: 287419);
      expect(deezerArtistFor('kirk franklin', [unknown, known], [song('I Smile', 'Kirk Franklin')]), known);
    });

    test('a song named as searched, featured artists aside, is the top result', () {
      final r = GetMusicResults(
        query: 'bully',
        albums: [SbAlbum.deezer(id: '1', title: 'Bully Pulpit', artist: 'A')],
        songs: [song('BULLY (feat. CeeLo Green)', 'Kanye West')],
        source: GetMusicSource.deezer,
      );
      expect((r.topResult! as SbTrack).title, 'BULLY (feat. CeeLo Green)');
    });

    test('searched under another name, still the Deezer album', () {
      final a = SbAlbum.deezer(
        id: '7',
        title: 'T',
        artist: 'Kanye West',
        cover: Uri.parse('https://cdn.example/c.jpg'),
      );
      final as = a.searchedAs('Kanye');
      expect((as.deezerId, as.cover, as.needsPressing), ('7', a.cover, true));
    });

    test('a song opens its Deezer album, with its cover', () {
      final s = SbTrack.deezer(
        id: '1',
        title: 'BULLY',
        artist: 'Kanye West',
        albumId: _bully,
        albumTitle: 'BULLY',
        seconds: 187,
        cover: Uri.parse('https://cdn.example/c.jpg'),
      );
      final album = s.onAlbum!;
      expect(
        (album.deezerId, album.title, album.cover?.host, album.needsPressing),
        (_bully, 'BULLY', 'cdn.example', true),
      );
      expect(s.duration, const Duration(seconds: 187));
      expect(SbTrack.deezer(id: '2', title: 'Loose', artist: 'A').onAlbum, isNull);
    });

    test('an album with no cover has none', () {
      expect(SbAlbum.fromJson({'id': 'x', 'title': 'T', 'sonar_cover': ''}).cover, isNull);
    });
  });
}
