// Get music's search, against a fake MusicBrainz and ListenBrainz answering
// with replies recorded from the real ones (test/fixtures/musicbrainz).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/data/musicbrainz/musicbrainz_client.dart';
import 'package:sonar/data/soulbeet/get_music_search.dart';
import 'package:sonar/data/soulbeet/soulbeet_client.dart';
import 'package:sonar/data/soulbeet/soulbeet_models.dart';
import 'package:sonar/state/soulbeet_providers.dart';

import 'support/fake_musicbrainz.dart';

const _ye = '164f0d73-1234-4e2c-8743-d77bf2191051';
const _jpegmafia = 'c42e60f4-4520-4954-b6e4-82bbdf532c11';

void main() {
  late FakeMusicBrainz server;
  late MusicBrainzClient mb;

  setUp(() async {
    server = await FakeMusicBrainz.start();
    mb = MusicBrainzClient(
      musicBrainz: server.base,
      listenBrainz: server.base,
      spacing: const Duration(milliseconds: 40),
      busyWait: const Duration(milliseconds: 10),
    );
  });
  tearDown(() async {
    mb.close();
    await server.close();
  });

  Future<GetMusicResults> search(String raw) => searchGetMusic(mb, raw).last;
  List<String> titles(List<SbAlbum> albums) => [for (final a in albums) a.title];

  group('an artist\'s name', () {
    test('"kanye west" lists Ye\'s albums, most listened first, all of them', () async {
      final r = await search('kanye west');
      expect(r.artist, 'Ye (Kanye West)', reason: 'MusicBrainz lists him as Ye; Kanye West is another of his names');
      expect(r.byArtist, hasLength(138), reason: 'both pages of his 141 albums, less 3 already listed by name');
      expect(
        server.searches.where((s) => s.$1 == 'release-group' && s.$2.startsWith('artist=')).map((s) => s.$2),
        [
          'artist=$_ye&type=album|ep&inc=artist-credits&limit=100&offset=0',
          'artist=$_ye&type=album|ep&inc=artist-credits&limit=100&offset=100',
        ],
        reason: '141 albums: two pages, then stop',
      );
      expect(titles(r.byArtist).take(4), [
        'Late Registration',
        'My Beautiful Dark Twisted Fantasy',
        'Graduation',
        'The College Dropout',
      ]);
      expect(
        titles(r.byArtist),
        containsAll(['Yeezus', '808s & Heartbreak']),
        reason: 'the search index leaves these out',
      );
      expect(server.searches.where((s) => s.$1 == 'release-group' && s.$2.startsWith('arid:')), isEmpty);
    });

    test('tributes with his name in their titles are minor next to his albums', () async {
      final r = await search('kanye west');
      bool minor(String title) => r.isMinor([...r.albums, ...r.byArtist].firstWhere((a) => a.title == title));
      expect(minor('Lullaby Renditions of Kanye West'), isTrue);
      expect(minor('The String Quartet Tribute to Kanye West'), isTrue);
      expect(minor('8-Bit Versions of Kanye West'), isTrue);
      expect(minor('Kanye West Presents Good Music: Cruel Summer'), isFalse, reason: '14,571 listeners');
      expect(minor('Yeezus'), isFalse);
      expect(r.albums.first.title, 'Kanye West Presents Good Music: Cruel Summer', reason: 'most listened first');
    });

    test('"jpeg mafia" is JPEGMAFIA, spaces and case aside', () async {
      final r = await search('jpeg mafia');
      expect(r.artist, 'JPEGMAFIA');
      expect(r.byArtist, hasLength(23));
      expect(r.byArtist.first.title, 'Veteran');
      expect(titles(r.byArtist), contains('SCARING THE HOES'));
    });

    test('a found artist\'s albums have no pressing until one is looked up', () async {
      final yeezus = (await search('kanye west')).byArtist.firstWhere((a) => a.title == 'Yeezus');
      expect(yeezus.needsPressing, isTrue);
      expect(yeezus.mbid, isNull);
      final pressed = await mb.pressingOf(yeezus);
      expect(pressed.needsPressing, isFalse);
      expect(pressed.id, '5b78aa6b-67be-43b5-8f56-a89116e48087', reason: 'the first official pressing');
      expect(pressed.mbid, pressed.id);
      expect((pressed.groupId, pressed.title, pressed.artist), (yeezus.groupId, 'Yeezus', 'Kanye West'));
      expect(pressed.request, {
        'id': '5b78aa6b-67be-43b5-8f56-a89116e48087',
        'title': 'Yeezus',
        'artist': 'Kanye West',
        'release_date': '2013-06-18',
        'mbid': '5b78aa6b-67be-43b5-8f56-a89116e48087',
      }, reason: 'what Soulbeet is asked to download, shaped as its own search sends it');
      expect(identical(await mb.pressingOf(pressed), pressed), isTrue);
    });

    test('an artist named in the search ("Artist - Album") is not looked up', () async {
      await search('Steve Lacy - Gemini Rights');
      expect(server.searches.map((s) => s.$1), isNot(contains('artist')));
    });

    test('albums listed by name are not listed again under the artist', () async {
      final r = await search('kanye west');
      final byName = {for (final a in r.albums) a.groupId};
      expect(r.byArtist.where((a) => byName.contains(a.groupId)), isEmpty);
      expect(titles(r.albums), contains('The Best of Kanye West'));
      expect(titles(r.byArtist), isNot(contains('The Best of Kanye West')));
    });
  });

  group('an artist\'s popular songs', () {
    const lateRegistration = 'c563d738-3841-31ce-b29d-ec6b40fd1e7b';
    const mbdtf = '5d6e21e1-deb5-428e-bb42-c2a567f3619b';
    const graduation = 'd44c50ad-61fd-3fce-95fc-27024d7f1d30';

    test('"kanye west": the most listened songs on his most listened albums, each on its album', () async {
      final r = await search('kanye west');
      expect(r.songs.take(5).map((s) => s.title), [
        'All of the Lights',
        'Power',
        'Dark Fantasy',
        'All of the Lights (interlude)',
        'Can’t Tell Me Nothing',
      ]);
      expect(r.songs, hasLength(popularSongs));
      final lights = r.songs.first;
      expect(
        (lights.artist, lights.album, r.listenersOf(lights)),
        ('Kanye West', 'My Beautiful Dark Twisted Fantasy', 123940),
      );
      expect(lights.onAlbum!.id, 'cd474271-bd7a-4d53-ba9e-e9d5bd7958cb', reason: 'the pressing Soulbeet downloads');
      expect(r.topResult, isA<TopArtist>(), reason: 'the artist is still the top result');
    });

    test('from his three most listened albums only', () async {
      await search('kanye west');
      expect(
        server.lookups.where((l) => l.$1.startsWith('release-group/')).map((l) => l.$1.split('/').last),
        [lateRegistration, mbdtf, graduation],
        reason: 'Late Registration, MBDTF and Graduation, not The College Dropout',
      );
    });

    test('listed as each album\'s songs land, not after all three', () async {
      final steps = await searchGetMusic(mb, 'kanye west').toList();
      final first = steps.firstWhere((s) => s.songs.isNotEmpty);
      expect(first.songs.map((s) => s.album).toSet(), {'Late Registration'});
      expect(steps.last.songs.first.title, 'All of the Lights');
    });

    test('the most listened, one of each title, none nobody has listened to, ten at most', () {
      SbTrack song(String id, String title) =>
          SbTrack.fromJson({'id': id, 'title': title, 'album_id': 'a', 'album_title': 'A'});
      final songs = [
        song('quiet', 'Stronger'),
        song('loud', 'STRONGER!'),
        song('unheard', 'Nobody'),
        for (var i = 0; i < 12; i++) song('s$i', 'Song $i'),
      ];
      // The quieter Stronger is second most listened: only its title leaves it out.
      final listened = {'quiet': 500, 'loud': 900, for (var i = 0; i < 12; i++) 's$i': 100 + i};
      final picked = pickPopular(songs, listened).map((s) => s.id).toList();
      expect(picked.first, 'loud', reason: 'most listened first; the quieter Stronger left out');
      expect(picked, isNot(contains('quiet')));
      expect(picked, isNot(contains('unheard')));
      expect(picked, hasLength(popularSongs));
      expect(picked.last, 's3', reason: 's11 down to s3 after Stronger');
    });

    test('ListenBrainz not answering leaves them out, and the search works', () async {
      server.listenBrainzDown = true;
      final r = await search('kanye west');
      expect(r.done, isTrue);
      expect(r.byArtist, isNotEmpty);
      expect(r.songs, isEmpty);
    });

    test('a slow artist lookup: his albums and popular songs still go before the song searches', () async {
      server.slow['/ws/2/artist'] = const Duration(milliseconds: 300);
      await search('kanye west');
      final order = [
        for (final r in server.requests)
          if (r.path.startsWith('/ws/2/')) r.path.substring(6).split('/').first,
      ];
      final firstSong = order.indexOf('recording');
      expect(order.sublist(0, 2), ['release-group', 'artist']);
      expect(
        order.indexOf('release'),
        lessThan(firstSong),
        reason: 'an album\'s songs looked up before any song search',
      );
      expect(
        order.sublist(2, firstSong),
        containsAllInOrder(['release-group', 'release-group', 'release-group', 'release']),
      );
    });
  });

  group('an album\'s name', () {
    test('finds the album as the pressing Soulbeet\'s own search picks', () async {
      final r = await search('Steve Lacy - Gemini Rights');
      final a = r.albums.single;
      expect(
        (a.id, a.groupId, a.title, a.artist, a.year),
        (
          '6d50b672-4f8e-4b7a-917b-1ded22808632',
          'ab1c1fd8-f769-4d78-90bc-4677f8ad8c22',
          'Gemini Rights',
          'Steve Lacy',
          '2022',
        ),
      );
      expect(a.needsPressing, isFalse);
      expect(r.listenersOf(a), 10900);
      expect(server.searches.first, (
        'release-group',
        'releasegroup:"Gemini Rights" AND (primarytype:album OR primarytype:ep) AND artist:"Steve Lacy"',
      ));
    });
  });

  group('a song\'s name', () {
    test('"Pure Color" finds "pure colour" on Oh yeah?, its other spelling', () async {
      final r = await search('Steve Lacy - Pure Color');
      expect(r.respelled, 'Steve Lacy - Pure Colour');
      final song = r.songs.single;
      expect(
        (song.title, song.artist, song.album, song.duration),
        ('pure colour', 'Steve Lacy feat. Erykah Badu', 'Oh yeah?', const Duration(minutes: 3, seconds: 7)),
      );
      expect(song.onAlbum!.id, 'eb30b1a0-3a0a-47cb-b2b1-0856f0cb6aa8');
      expect(r.listenersOf(song), 82);
    });
  });

  group('the way it\'s typed', () {
    const skyIsTheLimit = '571320d6-45b2-4c14-b193-1b5bfcbadfc3';

    test('"sky is the limit - rebelution": the song first, then its artist, is read that way round too', () async {
      final r = await search('sky is the limit - rebelution');
      final top = r.topResult;
      expect(top, isA<SbTrack>());
      top as SbTrack;
      expect(
        (top.id, top.title, top.artist, r.listenersOf(top)),
        (skyIsTheLimit, 'Sky Is the Limit', 'Rebelution', 3079),
      );
      expect(r.songs.map((s) => s.artist).toSet(), {'Rebelution'});
    });

    test('"sky is the limit rebelution": a song and its artist run together, only songs by that artist', () async {
      final r = await search('sky is the limit rebelution');
      expect(
        r.songs.map((s) => s.id).toSet(),
        {
          skyIsTheLimit,
          'a979023f-d299-4f85-86f7-dc33164a93ef',
          'b67a28b9-a3a0-4086-bc81-d14c9aaf2f2e',
          '4cb6df64-c379-457c-b4e0-4b1bb45784e5', // (Acoustic)
          '75394289-0b92-486f-b062-85f975e6c507', // (Dub)
          '9ffe7227-4689-4138-b8eb-be0cf09bc27e', // live at St. Augustine
        },
        reason: 'not "Rebelution" by Fist to the Sky, or the many other artists\' Sky Is the Limit',
      );
      expect((r.topResult! as SbTrack).id, skyIsTheLimit, reason: 'the most listened of them');
      expect(r.allAlbums, isEmpty, reason: 'other artists\' albums called Sky Is the Limit are noise');
    });

    test('songs found each way are listed together', () async {
      final loose = musicBrainzFixture('loose_songs_sky_is_the_limit_rebelution')['response'];
      final byName = {
        'recordings': [
          {
            'id': 'by-name',
            'title': 'Sky Is the Limit Rebelution',
            'artist-credit': [
              {'name': 'Somebody', 'joinphrase': ''},
            ],
            'releases': [
              {
                'id': 'r-by-name',
                'title': 'Somebody\'s Album',
                'status': 'Official',
                'release-group': {'primary-type': 'Album'},
              },
            ],
          },
        ],
      };
      server.queued['/ws/2/recording'] = [(200, loose), (200, byName)];
      final r = await search('sky is the limit rebelution');
      expect(r.songs.map((s) => s.id), containsAll([skyIsTheLimit, 'by-name']));
    });

    test('a loose song search finds a song by any of its credited artists, by credit or name', () async {
      Map<String, Object?> song(String id, List<(String, String)> credit) => {
        'id': id,
        'title': 'Otis',
        'artist-credit': [
          for (final (asCredited, name) in credit)
            {
              'name': asCredited,
              'joinphrase': ' & ',
              'artist': {'name': name},
            },
        ],
        'releases': [
          {
            'id': 'r-$id',
            'title': 'Watch the Throne',
            'status': 'Official',
            'release-group': {'primary-type': 'Album'},
          },
        ],
      };
      final reply = {
        'recordings': [
          song('both', [('JAY-Z', 'JAY-Z'), ('Kanye West', 'Ye')]),
          song('other', [('Otis Redding', 'Otis Redding')]),
        ],
      };
      Future<List<String>> found(String words) async {
        server.queued['/ws/2/recording'] = [(200, reply)];
        return [for (final s in await mb.searchSongsLoosely(words)) s.id];
      }

      expect(await found('otis kanye west'), ['both'], reason: 'the second artist, as credited');
      expect(await found('ye otis'), ['both'], reason: 'by the name MusicBrainz lists him under');
      expect(await found('jay-z otis'), ['both']);
    });

    test('"rebelution peace of mind": an album and its artist run together', () async {
      final r = await search('rebelution peace of mind');
      expect(titles(r.allAlbums), ['Peace of Mind'], reason: 'not Pitbull\'s "Rebelution" (5867 listeners)');
      expect(r.allAlbums.single.artist, 'Rebelution');
    });

    test('a loose album search keeps albums and EPs, never singles', () async {
      Map<String, Object?> group(String id, String? kind) => {
        'id': id,
        'score': 100,
        'title': 'Peace of Mind',
        'primary-type': ?kind,
        'artist-credit': [
          {'name': 'Rebelution', 'joinphrase': ''},
        ],
        'releases': [
          {'id': 'r-$id', 'status': 'Official'},
        ],
      };
      server.queued['/ws/2/release-group'] = [
        (
          200,
          {
            'release-groups': [
              group('album', 'Album'),
              group('ep', 'EP'),
              group('single', 'Single'),
              group('none', null),
            ],
          },
        ),
      ];
      final found = await mb.searchAlbumsLoosely('rebelution peace of mind');
      expect(found.map((a) => a.groupId), ['album', 'ep']);
    });

    test('one word is searched as typed, not loosely too', () async {
      await search('rebelution');
      expect(server.searches.where((s) => s.$2 == 'rebelution' && s.$1 != 'artist'), isEmpty);
      expect(server.requests.where((r) => (r.asked as Map?)?['dismax'] != null), isEmpty);
    });
  });

  group('ranking', () {
    test('only the last step is done, and every step is in listener order', () async {
      final steps = await searchGetMusic(mb, 'kanye west').toList();
      expect(steps.where((s) => s.done), hasLength(1));
      expect(steps.last.done, isTrue);
      for (final s in steps) {
        for (final list in [s.albums, s.byArtist]) {
          final counts = [for (final a in list) s.listenersOf(a)];
          expect(counts, [...counts]..sort((a, b) => b.compareTo(a)));
        }
      }
    });

    test('the artist comes before songs, so their albums show sooner', () async {
      await search('kanye west');
      expect(server.searches.map((s) => s.$1).toList(), [
        'release-group',
        'artist',
        'release-group',
        'release-group',
        'recording',
        'recording',
        'release-group',
      ]);
      expect(
        server.searches.skip(4).map((s) => s.$2),
        ['kanye west', 'recording:"kanye west"', 'kanye west'],
        reason: 'songs as typed (free text) first, then by name, then albums as typed',
      );
    });

    test('nothing is minor when ListenBrainz does not answer, and the order is MusicBrainz\'s', () async {
      server.listenBrainzDown = true;
      final r = await search('jpeg mafia');
      expect(r.byArtist, hasLength(23));
      expect(r.byArtist.where(r.isMinor), isEmpty);
      final recorded = (musicBrainzFixture('albums_by_jpegmafia')['response']! as Map)['release-groups']! as List;
      expect(titles(r.byArtist), [for (final g in recorded) (g as Map)['title']]);
    });

    test('isMinor: under 1% of the best match\'s listeners', () {
      final a = SbAlbum.found(pressing: 'p1', groupId: 'g1', title: 'A', artist: 'X');
      final b = SbAlbum.found(pressing: 'p2', groupId: 'g2', title: 'B', artist: 'X');
      final c = SbAlbum.found(pressing: 'p3', groupId: 'g3', title: 'C', artist: 'X');
      final r = GetMusicResults(albums: [a, b, c], listeners: const {'g1': 1000, 'g2': 10, 'g3': 9});
      expect([r.isMinor(a), r.isMinor(b), r.isMinor(c)], [false, false, true]);
    });
  });

  group('MusicBrainz', () {
    test('asks at most once per spacing, and says who is asking', () async {
      await search('kanye west');
      final mbRequests = server.requests.where((r) => r.path.startsWith('/ws/2/')).toList();
      for (var i = 1; i < mbRequests.length; i++) {
        expect(
          mbRequests[i].at.difference(mbRequests[i - 1].at),
          greaterThanOrEqualTo(const Duration(milliseconds: 35)),
        );
      }
      expect(server.requests.map((r) => r.agent).toSet(), {MusicBrainzClient.userAgent});
    });

    test('asks again when busy, and says so when it stays busy', () async {
      server.queued['/ws/2/release-group'] = [
        (503, {'error': 'busy'}),
        (503, {'error': 'busy'}),
      ];
      final r = await search('Steve Lacy - Gemini Rights');
      expect(r.albums.single.title, 'Gemini Rights');

      server.queued['/ws/2/release-group'] = List.filled(4, (503, {'error': 'busy'}), growable: true);
      await expectLater(
        searchGetMusic(mb, 'Nobody - Nothing Kept'),
        emitsError(isA<MusicBrainzException>().having((e) => e.message, 'message', contains('busy'))),
      );
    });

    test('the album search failing fails the search; a later part failing is left out', () async {
      server.queued['/ws/2/recording'] = [(500, 'boom')];
      final r = await search('Steve Lacy - Pure Color');
      expect(r.done, isTrue);
      expect(r.songs.single.title, 'pure colour', reason: 'the first spelling failed; the second still answered');
    });

    test('quotes in a name are searched as part of it', () async {
      await search('Say "Hi" \\ Bye');
      expect(server.searches.first.$2, startsWith(r'releasegroup:"Say \"Hi\" \\ Bye"'));
      expect(server.searches[1], ('artist', r'Say \"Hi\" \\ Bye'));
    });

    test('artists: by any of their names, at most two', () async {
      expect((await mb.findArtists('KANYE WEST')).map((a) => (a.id, a.name, a.matchedAs)), [(_ye, 'Ye', 'Kanye West')]);
      expect((await mb.findArtists('jpeg mafia')).map((a) => (a.id, a.matchedAs)), [(_jpegmafia, null)]);
      expect(await mb.findArtists('  '), isEmpty);
    });
  });

  group('pressings (hand-made replies: no recorded album lists another pressing first)', () {
    Map<String, Object?> group(List<Map<String, Object?>> releases) => {
      'id': 'g1',
      'title': 'T',
      'first-release-date': '2001',
      'artist-credit': [
        {'name': 'A', 'joinphrase': ' & '},
        {'name': 'B', 'joinphrase': ''},
      ],
      'releases': releases,
    };

    test('an album found by name is its first official pressing', () async {
      server.queued['/ws/2/release-group'] = [
        (
          200,
          {
            'release-groups': [
              group([
                {'id': 'boot', 'status': 'Bootleg'},
                {'id': 'off', 'status': 'Official'},
              ]),
              group([
                {'id': 'promo', 'status': 'Promotion'},
              ]),
            ],
          },
        ),
      ];
      final albums = await mb.searchAlbums('T');
      expect(albums.map((a) => (a.id, a.artist)), [('off', 'A & B'), ('promo', 'A & B')]);
    });

    test('an artist\'s album, opened, is its first official pressing', () async {
      server.queued['/ws/2/release-group/g1'] = [
        (
          200,
          {
            'releases': [
              {'id': 'boot', 'status': 'Bootleg'},
              {'id': 'off', 'status': 'Official'},
              {'id': 'off2', 'status': 'Official'},
            ],
          },
        ),
      ];
      final album = SbAlbum.found(groupId: 'g1', title: 'T', artist: 'A');
      expect((await mb.pressingOf(album)).id, 'off');
    });

    test('a song is on its official album before a single, an EP or a bootleg', () async {
      Map<String, Object?> release(String id, String status, String type, String date) => {
        'id': id,
        'title': id,
        'status': status,
        'date': date,
        'release-group': {'primary-type': type},
      };
      server.queued['/ws/2/recording'] = [
        (
          200,
          {
            'recordings': [
              {
                'id': 'r1',
                'title': 'Song',
                'length': 187000,
                'artist-credit': [
                  {'name': 'A'},
                ],
                'releases': [
                  release('single', 'Official', 'Single', '2025-01-01'),
                  release('bootleg-album', 'Bootleg', 'Album', '2020-01-01'),
                  release('ep', 'Official', 'EP', '2025-06-01'),
                  release('album-later', 'Official', 'Album', '2027-01-01'),
                  release('album', 'Official', 'Album', '2026-07-17'),
                ],
              },
            ],
          },
        ),
      ];
      final song = (await mb.searchSongs('Song')).single;
      expect((song.album, song.duration), ('album', const Duration(minutes: 3, seconds: 7)));
    });
  });

  group('like a music app', () {
    test('"kanye west": the top result is the artist, his most listened album its cover', () async {
      final r = await search('kanye west');
      final top = r.topResult! as TopArtist;
      expect((top.name, top.cover!.title), ('Ye (Kanye West)', 'Late Registration'));
    });

    test('an album or song with exactly the name searched beats an artist less listened', () async {
      final r = GetMusicResults(
        query: 'bully',
        albums: [SbAlbum.found(pressing: 'p1', groupId: 'g-ye', title: 'BULLY', artist: 'Ye')],
        byArtist: [SbAlbum.found(groupId: 'g-band', title: 'Feels Like', artist: 'Bully')],
        artist: 'Bully',
        listeners: const {'g-ye': 900, 'g-band': 500},
      );
      expect((r.topResult! as SbAlbum).title, 'BULLY');
      final band = GetMusicResults(
        query: 'bully',
        albums: r.albums,
        byArtist: r.byArtist,
        artist: 'Bully',
        listeners: const {'g-ye': 400, 'g-band': 500},
      );
      expect(band.topResult, isA<TopArtist>());
    });

    test('an album named in the search is the top result; a song when only a song is', () async {
      expect(((await search('Steve Lacy - Gemini Rights')).topResult! as SbAlbum).title, 'Gemini Rights');
      expect(((await search('Steve Lacy - Pure Color')).topResult! as SbTrack).title, 'pure colour');
    });

    test('filler: compilations, live and Various Artists albums few play, and anything minor', () async {
      final r = await search('kanye west');
      SbAlbum named(String t) => r.allAlbums.firstWhere((a) => a.title == t);
      expect(r.isFiller(named('Lullaby Renditions of Kanye West')), isTrue, reason: 'minor');
      expect(r.isFiller(named('Late Registration')), isFalse);
      expect(r.isFiller(named('Kanye West Presents Good Music: Cruel Summer')), isFalse, reason: '29% of the best');
      final kinds = r.allAlbums.where((a) => a.kinds.isNotEmpty).toList();
      expect(kinds, isNotEmpty, reason: 'MusicBrainz says which are compilations, live, mixtapes');
      for (final a in kinds) {
        expect(r.isFiller(a), r.listenersOf(a) * 10 < r.top, reason: '${a.title} ${a.kinds}');
      }
      final shown = r.allAlbums.where((a) => !r.isFiller(a)).toList();
      expect(shown.length, lessThan(r.allAlbums.length ~/ 3), reason: 'most of 140-odd albums are filler');
    });

    test('allAlbums: by name and by the artist, once each, most listened first', () async {
      final r = await search('kanye west');
      final all = r.allAlbums;
      expect(all.map((a) => a.groupId).toSet(), hasLength(all.length));
      expect(all.length, r.albums.length + r.byArtist.length);
      final counts = [for (final a in all) r.listenersOf(a)];
      expect(counts, [...counts]..sort((a, b) => b.compareTo(a)));
    });
  });

  group('responsive', () {
    test('an album\'s songs: its pressing, then its songs, shaped as Soulbeet sends them', () async {
      final yeezus = (await search('kanye west')).byArtist.firstWhere((a) => a.title == 'Yeezus');
      final detail = await mb.songsOf(yeezus);
      expect(detail.album.id, '5b78aa6b-67be-43b5-8f56-a89116e48087');
      expect(detail.album.needsPressing, isFalse);
      expect(detail.album.groupId, yeezus.groupId);
      expect(detail.tracks.map((t) => t.title).take(3), ['On Sight', 'Black Skinhead', 'I Am a God']);
      expect(detail.tracks, hasLength(10));
      final first = detail.tracks.first.raw;
      expect(first.keys.toSet(), {
        'id',
        'title',
        'artist',
        'album_id',
        'album_title',
        'release_date',
        'duration',
        'mbid',
        'release_mbid',
      }, reason: "Soulbeet's Track, to send back when downloading some songs");
      expect((first['album_id'], first['duration']), ('5b78aa6b-67be-43b5-8f56-a89116e48087', '02:37'));
    });

    test('the likeliest albums\' songs are fetched ahead, once the search is done', () async {
      // An album search: an artist's search fetches their top albums' songs
      // while it runs, for their popular songs.
      final r = await search('Steve Lacy - Gemini Rights');
      expect(server.lookups, isEmpty, reason: 'nothing fetched ahead while the search runs');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final likely = [for (final a in r.allAlbums.where((a) => !r.isFiller(a)).take(3)) 'release/${a.id}'];
      expect(likely, isNotEmpty);
      expect(server.lookups.map((l) => l.$1).toSet(), {...likely});
      expect(likely.first, 'release/${(r.topResult! as SbAlbum).id}');
    });

    test('an album opened twice needs no second request', () async {
      final yeezus = (await search('kanye west')).byArtist.firstWhere((a) => a.title == 'Yeezus');
      await mb.songsOf(yeezus);
      final sent = mb.sent;
      final again = await mb.songsOf(yeezus);
      expect(again.tracks, hasLength(10));
      expect(mb.sent, sent);
    });

    test('asked again, a search is answered from what was kept', () async {
      await search('kanye west');
      final sent = mb.sent;
      final listenRequests = server.requests.where((r) => r.path.startsWith('/1/')).length;
      final again = await search('kanye west');
      expect(again.byArtist, isNotEmpty);
      expect(mb.sent, sent, reason: 'no MusicBrainz request');
      expect(
        server.requests.where((r) => r.path.startsWith('/1/')).length,
        listenRequests,
        reason: 'no ListenBrainz one',
      );
    });

    test('what the screen waits for goes before the rest of a search, and fetching ahead last', () async {
      final asked = <String>[];
      final spare = mb.songsOf(
        SbAlbum.found(groupId: 'g1', title: 'T', artist: 'A'),
        turn: MbTurn.spare,
      );
      final soon = mb.searchSongs('Soon', turn: MbTurn.soon);
      final now = mb.searchAlbums('Now');
      unawaited(spare.then((_) => asked.add('spare'), onError: (_) => asked.add('spare')));
      unawaited(soon.then((_) => asked.add('soon')));
      unawaited(now.then((_) => asked.add('now')));
      await Future.wait([soon, now]);
      await spare.catchError((_) => SbAlbumDetail(SbAlbum.found(groupId: 'x', title: 'x', artist: 'x'), const []));
      // Asked together, by turn, even on an idle line: the first asked
      // doesn't go first just for being first.
      expect(asked, ['now', 'soon', 'spare']);
      expect(server.searches.map((s) => s.$2), [
        'releasegroup:"Now" AND (primarytype:album OR primarytype:ep)',
        'recording:"Soon"',
      ]);
    });

    test('a cancelled search\'s waiting requests drop out of line', () async {
      final cancel = MbCancel();
      final steps = searchGetMusic(mb, 'kanye west', cancel: cancel).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      cancel.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await steps.cancel();
      expect(server.searches.length, lessThanOrEqualTo(2), reason: 'what was sent already, nothing after');
    });

    test('leaving a search (or typing on) drops what it still has waiting', () async {
      final container = ProviderContainer(
        overrides: [
          soulbeetClientProvider.overrideWithValue(
            SoulbeetClient(base: Uri.parse('http://127.0.0.1:9'), username: 'u', password: 'p'),
          ),
          musicBrainzClientProvider.overrideWithValue(mb),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(soulbeetSearchProvider('kanye west'), (_, _) {});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      sub.close();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(server.searches.length, lessThanOrEqualTo(2), reason: 'what was sent already, nothing after');
    });

    test('songs are fetched in Soulbeet\'s length format, "mm:ss"', () async {
      final song = (await search('Steve Lacy - Pure Color')).songs.single;
      expect(song.raw['duration'], '03:07');
    });
  });

  test('songs on no album are not offered', () {
    final t = SbTrack.fromJson({'id': 'r1', 'title': 'Loose', 'artist': 'A'});
    expect(t.onAlbum, isNull);
  });

  test('respell: US and UK spellings, either way, keeping the case', () {
    expect(respell('pure color'), 'pure colour');
    expect(respell('Pure Colour'), 'Pure Color');
    expect(respell('My Favorite Things'), 'My Favourite Things');
    expect(respell('GREY SKIES'), 'GRAY SKIES');
    expect(respell('Back Catalogue'), 'Back Catalog');
    expect(respell('Theater of the Mind'), 'Theatre of the Mind');
    expect(respell('Legalize It'), isNull);
    expect(respell(''), isNull);
  });

  test('splitArtistQuery', () {
    expect(splitArtistQuery(' Peter Tosh - Legalize It '), ('Legalize It', 'Peter Tosh'));
    expect(splitArtistQuery('Jay-Z'), ('Jay-Z', null));
    expect(splitArtistQuery('Exodus'), ('Exodus', null));
  });
}
