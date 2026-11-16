// Discover's app side (docs/DISCOVER_PLAN.md): what it downloads, when it
// stops, keep / remove, and downloads carried across app restarts. Deezer,
// MusicBrainz, Soulbeet and Sonar Connect are stand-ins here; each has its
// own tests against recorded replies or the real relay.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/connect/connect_client.dart';
import 'package:sonar/data/deezer/deezer_client.dart';
import 'package:sonar/data/discover/discover.dart';
import 'package:sonar/data/musicbrainz/musicbrainz_client.dart';
import 'package:sonar/data/soulbeet/soulbeet_client.dart';
import 'package:sonar/data/soulbeet/soulbeet_downloads.dart';
import 'package:sonar/data/soulbeet/soulbeet_models.dart';
import 'package:sonar/data/subsonic/models.dart';

import 'support/fake_server.dart';

Future<void> until(bool Function() ok, String what) async {
  for (var i = 0; i < 200; i++) {
    if (ok()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out waiting for: $what');
}

/// Deezer: who's like whom, and each artist's most played songs.
class _Deezer extends Fake implements DeezerClient {
  final relatedTo = <String, List<String>>{};
  final topOf = <String, List<SbTrack>>{};
  final askedTop = <String>[];

  @override
  Future<List<DeezerArtist>> searchArtists(String words) async => [DeezerArtist('dz-$words', words)];

  @override
  Future<List<DeezerArtist>> related(DeezerArtist artist) async => [
    for (final name in relatedTo[artist.name] ?? const <String>[]) DeezerArtist('dz-$name', name),
  ];

  @override
  Future<List<SbTrack>> topSongs(DeezerArtist artist) async {
    askedTop.add(artist.name);
    return topOf[artist.name] ?? const [];
  }

  /// Deezer's `record_type` by album id (`album` unless set).
  final kindOf = <String, String>{};

  @override
  Future<DeezerAlbumInfo> album(String id) async =>
      DeezerAlbumInfo(title: 'Album $id', artist: '', kind: kindOf[id] ?? 'album');
}

/// A Deezer song on Deezer album [album].
SbTrack _dz(String title, String artist, String album) =>
    SbTrack.deezer(id: 'dz-$title', title: title, artist: artist, albumId: album, albumTitle: 'Album $album');

/// MusicBrainz: releases by the Deezer album (or MusicBrainz release) they
/// stand for, and what a song search finds.
class _MusicBrainz extends Fake implements MusicBrainzClient {
  final releases = <String, SbAlbumDetail>{};
  final songSearch = <String, List<SbTrack>>{};

  @override
  Future<SbAlbumDetail> songsOf(SbAlbum album, {MbTurn turn = MbTurn.now, MbCancel? cancel}) async {
    final r = releases[album.deezerId ?? album.mbid ?? album.id];
    if (r == null) throw const MusicBrainzException('MusicBrainz doesn\'t have this album.');
    return r;
  }

  @override
  Future<List<SbTrack>> searchSongs(
    String title, {
    String? artist,
    List<String> artistIds = const [],
    MbTurn turn = MbTurn.now,
    MbCancel? cancel,
  }) async => songSearch[title] ?? const [];
}

SbAlbumDetail _release(String mbid, String title, String artist, List<String> songs, {List<String> kinds = const []}) =>
    SbAlbumDetail(SbAlbum.found(pressing: mbid, groupId: 'g-$mbid', title: title, artist: artist, kinds: kinds), [
      for (final (i, s) in songs.indexed)
        SbTrack.fromJson({'id': 'rec-$mbid-$i', 'title': s, 'artist': artist, 'album_id': mbid, 'album_title': title}),
    ]);

/// Soulbeet's downloads, recording what was asked.
class _Downloads extends SoulbeetDownloads {
  _Downloads([this.prefix = 'batch'])
    : super(
        client: SoulbeetClient(base: Uri.parse('http://127.0.0.1:9'), username: 'u', password: 'p'),
      );

  final asked = <({SbAlbum album, List<SbTrack> songs, bool forDiscover})>[];
  final resumed = <({String batchId, String releaseId, List<String> items})>[];
  String? failWith;

  /// Batch ids are `<prefix>-1`, `<prefix>-2`...
  final String prefix;

  @override
  Future<AlbumDownload> download(
    SbAlbum album, {
    int? trackCount,
    SbSource? chosen,
    List<SbTrack> songs = const [],
    bool forDiscover = false,
  }) async {
    asked.add((album: album, songs: songs, forDiscover: forDiscover));
    final d = AlbumDownload.debug('$prefix-${asked.length}', album: album, songs: songs, forDiscover: forDiscover)
      ..phase = failWith == null ? AlbumPhase.downloading : AlbumPhase.failed
      ..error = failWith;
    debugAdd(d);
    return d;
  }

  @override
  Future<AlbumDownload> resumeDiscover({
    required String batchId,
    required String releaseId,
    required List<String> items,
    required String label,
    required DateTime started,
    Duration quietFor = Duration.zero,
  }) async {
    resumed.add((batchId: batchId, releaseId: releaseId, items: items));
    final d = AlbumDownload.debug(batchId, label: label, releaseId: releaseId, forDiscover: true)
      ..phase = AlbumPhase.importing;
    debugAdd(d);
    return d;
  }

  /// [d]'s file shows up on the feed.
  void fileArrives(AlbumDownload d, String item) {
    d.files['f-$item'] = SbProgress.fromJson({
      'id': 'f-$item',
      'source': 'peer',
      'item': item,
      'size': 1000,
      'transferred': 10,
      'state': 'InProgress',
      'percent': 1,
      'speed': 1.0,
      'batch_id': d.key,
    });
    debugAdd(d);
  }
}

/// Navidrome: the libraries, Discover's songs (library 2), and the artists
/// in the others.
class _Navidrome extends FakeAdapter {
  _Navidrome() : super({});
  var folders = [(1, 'Music Library'), (2, 'Discover')];
  final discover = <Song>[];
  var owned = <String>['Kirk Franklin'];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    final q = options.uri.queryParameters;
    responses['getMusicFolders'] = ok({
      'musicFolders': {
        'musicFolder': [
          for (final (id, name) in folders) {'id': id, 'name': name},
        ],
      },
    });
    responses['search3'] = ok({
      'searchResult3': {
        'song': [
          if (q['musicFolderId'] == '2')
            for (final s in discover.skip(int.parse(q['songOffset'] ?? '0')).take(int.parse(q['songCount']!)))
              s.toJson(),
        ],
      },
    });
    responses['getArtists'] = ok({
      'artists': {
        'index': [
          {
            'artist': [
              for (final (i, a) in owned.indexed) {'id': 'ar$i', 'name': a},
            ],
          },
        ],
      },
    });
    return super.fetch(options, requestStream, cancelFuture);
  }
}

Song _song(String id, String title, String artist, String album, {int ageDays = 0, int size = 30 << 20}) => Song(
  id: id,
  title: title,
  artist: artist,
  album: album,
  size: size,
  created: DateTime.now().subtract(Duration(days: ageDays, minutes: int.parse(id.replaceAll(RegExp(r'\D'), '0')))),
);

void main() {
  late _Deezer dz;
  late _MusicBrainz mb;
  late _Downloads downloads;
  late _Navidrome nd;
  late Map<String, Object?> store;
  late List<List<String>> foldersSet;
  late Set<String> hidden;
  DiscoverServer? server;
  late List<List<String>> kept, removed;
  late Map<String, String> refuse;
  var mayTopUp = true;

  setUp(() {
    dz = _Deezer()
      ..relatedTo['Kirk Franklin'] = ['Kirk Franklin & The Family', 'Fred Hammond', 'Marvin Sapp']
      ..topOf['Fred Hammond'] = [
        _dz('No Weapon', 'Fred Hammond', '100'),
        _dz('Jesus Be a Fence', 'Fred Hammond', '101'),
      ]
      ..topOf['Marvin Sapp'] = [_dz('Never Would Have Made It', 'Marvin Sapp', '200')];
    mb = _MusicBrainz()
      ..releases['100'] = _release('mb-100', 'Pages of Life', 'Fred Hammond', ['Intro', 'No Weapon'])
      ..releases['101'] = _release('mb-101', 'Speak Those Things', 'Fred Hammond', ['Jesus Be a Fence'])
      ..releases['200'] = _release('mb-200', 'Thirsty', 'Marvin Sapp', ['Never Would Have Made It']);
    downloads = _Downloads();
    nd = _Navidrome();
    store = {};
    foldersSet = [];
    hidden = {};
    server = const DiscoverServer(library: '2');
    kept = [];
    removed = [];
    refuse = {};
    mayTopUp = true;
  });

  tearDown(() => downloads.dispose());

  DiscoverResult change(List<List<String>> log, List<String> ids) {
    log.add(ids);
    final done = [
      for (final id in ids)
        if (!refuse.containsKey(id)) id,
    ];
    nd.discover.removeWhere((s) => done.contains(s.id));
    return DiscoverResult(done, {for (final id in ids) id: ?refuse[id]});
  }

  Discover make({_Downloads? using}) {
    final client = fakeServer({}, adapter: nd, withCache: false).client;
    final d = Discover(
      library: () => client,
      server: () async => server,
      keepSongs: (ids) async => change(kept, ids),
      removeSongs: (ids) async => change(removed, ids),
      downloads: using ?? downloads,
      deezer: dz,
      musicBrainz: mb,
      played: () async => ['Kirk Franklin'],
      read: () async => store['state'] == null ? null : jsonDecode(store['state']! as String),
      write: (state) async => store['state'] = jsonEncode(state),
      onFolders: foldersSet.add,
      hidden: hidden,
      mayTopUp: () => mayTopUp,
      resumeQuiet: Duration.zero,
    );
    addTearDown(d.dispose);
    return d;
  }

  /// Turns Discover on with [s] (which tops up), and waits for it to finish.
  Future<Discover> on([DiscoverSettings s = const DiscoverSettings(on: true), _Downloads? using]) async {
    final d = make(using: using)..settings = s;
    await until(() => !d.toppingUp, 'the top-up');
    return d;
  }

  List<String> titlesAsked() => [
    for (final a in downloads.asked)
      for (final s in a.songs) s.title,
  ];

  group('what Discover is', () {
    test('off on the server: nothing hidden, every library shown', () async {
      server = null;
      hidden.add('stale');
      final d = make();
      await d.refresh();
      expect(d.available, isFalse);
      expect(foldersSet.last, isEmpty);
      expect(hidden, isEmpty);
    });

    test('on: library screens show every library but Discover\'s; its songs are hidden from similar songs', () async {
      nd.folders = [(1, 'Music Library'), (2, 'Discover'), (3, 'Audiobooks')];
      nd.discover.addAll([_song('s1', 'Old', 'A', 'X', ageDays: 3), _song('s2', 'New', 'B', 'Y')]);
      final d = make();
      await d.refresh();
      expect((d.available, d.libraryId), (true, '2'));
      expect(foldersSet.last, ['1', '3']);
      expect([for (final s in d.songs) s.title], ['New', 'Old'], reason: 'newest first');
      expect(hidden, {'s1', 's2'});
    });
  });

  group('topping up', () {
    test('the top song of each artist like the ones played, as its MusicBrainz release, into Discover', () async {
      final d = await on();
      expect(titlesAsked(), ['No Weapon', 'Never Would Have Made It']);
      expect([for (final a in downloads.asked) a.album.mbid], ['mb-100', 'mb-200']);
      expect(downloads.asked.every((a) => a.forDiscover), isTrue);
      expect(dz.askedTop, isNot(contains('Kirk Franklin & The Family')), reason: 'already in the library');
      expect(d.downloading, 2);
      final saved = jsonDecode(store['state']! as String) as Map;
      expect(
        [for (final p in saved['pending'] as List) ((p as Map)['key'], p['releaseId'])],
        [('batch-1', 'mb-100'), ('batch-2', 'mb-200')],
      );
      expect(d.note, DiscoverNote.added);
    });

    test('off, or while a PC does the topping up: nothing is downloaded', () async {
      await on(const DiscoverSettings());
      mayTopUp = false;
      final d = await on();
      await d.topUp();
      expect(downloads.asked, isEmpty);
    });

    test('a top-up starts at most a few, and never past the song limit', () async {
      for (var i = 0; i < 8; i++) {
        dz.relatedTo['Kirk Franklin']!.add('Artist $i');
        dz.topOf['Artist $i'] = [_dz('Song $i', 'Artist $i', 'a$i')];
        mb.releases['a$i'] = _release('mb-a$i', 'Album $i', 'Artist $i', ['Song $i']);
      }
      await on();
      expect(downloads.asked, hasLength(5), reason: 'a batch');

      downloads.asked.clear();
      store.clear();
      nd.discover.addAll([for (var i = 0; i < 24; i++) _song('s$i', 'T$i', 'Someone', 'Al$i')]);
      final d = await on(const DiscoverSettings(on: true, maxSongs: 25));
      expect(downloads.asked, hasLength(1), reason: '24 of 25 already');
      await d.topUp();
      expect(downloads.asked, hasLength(1), reason: 'the one downloading counts');
      expect(d.note, DiscoverNote.full);
    });

    test('...nor past the space limit, counting songs still downloading', () async {
      nd.discover.add(_song('s1', 'Big', 'Someone', 'Al', size: 1024 * 1024 * 1024 - (50 << 20)));
      final d = await on(const DiscoverSettings(on: true, maxGb: 1));
      expect(downloads.asked, hasLength(1), reason: 'room for one more song of ~35 MB');
      await d.topUp();
      expect(downloads.asked, hasLength(1));
      expect(d.full, isTrue);
    });

    test('skips songs removed before, artists with two removed, and albums already in Discover', () async {
      server = const DiscoverServer(
        library: '2',
        removed: [
          RemovedSong(artist: 'Fred Hammond', title: 'No Weapon'),
          RemovedSong(artist: 'Marvin Sapp', title: 'A'),
          RemovedSong(artist: 'Marvin Sapp', title: 'B'),
        ],
      );
      dz.relatedTo['Kirk Franklin']!.add('Tye Tribbett');
      dz.topOf['Tye Tribbett'] = [_dz('Bless Me', 'Tye Tribbett', '300'), _dz('Victory', 'Tye Tribbett', '301')];
      mb
        ..releases['300'] = _release('mb-300', 'Stand Out', 'Tye Tribbett', ['Bless Me'])
        ..releases['301'] = _release('mb-301', 'Victory Live', 'Tye Tribbett', ['Victory']);
      nd.discover.add(_song('s1', 'Other', 'Tye Tribbett', 'Stand Out'));
      await on();
      expect(titlesAsked(), ['Jesus Be a Fence', 'Victory']);
      expect(dz.askedTop, isNot(contains('Marvin Sapp')));
    });

    test('songs removed only to make room say nothing against their artist', () async {
      server = const DiscoverServer(
        library: '2',
        removed: [
          RemovedSong(artist: 'Marvin Sapp', title: 'A'),
          RemovedSong(artist: 'Marvin Sapp', title: 'B'),
        ],
      );
      store['state'] = jsonEncode({
        'pending': <Object>[],
        'roomed': ['marvinsapp|a', 'marvinsapp|b'],
      });
      await on();
      expect(titlesAsked(), contains('Never Would Have Made It'));
    });

    test('at most two songs by one artist waiting in Discover', () async {
      nd.discover.addAll([_song('s1', 'One', 'Fred Hammond', 'P'), _song('s2', 'Two', 'Fred Hammond', 'Q')]);
      await on();
      expect(titlesAsked(), ['Never Would Have Made It']);
    });

    test('a Deezer album MusicBrainz doesn\'t know: the album a song search finds, never a compilation', () async {
      mb.releases.remove('200');
      mb.songSearch['Never Would Have Made It'] = [
        SbTrack.fromJson({'id': 'r1', 'title': 'Never Would Have Made It', 'album_id': 'mb-c', 'album_title': 'WOW'}),
        SbTrack.fromJson({'id': 'r2', 'title': 'Never Would Have Made It', 'album_id': 'mb-t', 'album_title': 'T'}),
      ];
      mb
        ..releases['mb-c'] = _release(
          'mb-c',
          'WOW Gospel',
          'Various',
          ['Never Would Have Made It'],
          kinds: ['Compilation'],
        )
        ..releases['mb-t'] = _release('mb-t', 'Thirsty', 'Marvin Sapp', ['Never Would Have Made It']);
      await on();
      expect(downloads.asked.last.album.mbid, 'mb-t');
    });

    test('never what looks like a compilation, even unmarked: Deezer\'s type, Various Artists, a hits title', () async {
      dz
        ..kindOf['100'] =
            'compile' // Fred's first song: on to his second.
        ..relatedTo['Kirk Franklin']!.add('Aswad')
        ..topOf['Aswad'] = [_dz('Don\'t Turn Around', 'Aswad', '400')];
      mb
        ..releases['200'] = _release('mb-200', 'Strictly the Best 18', 'Various Artists', ['Never Would Have Made It'])
        ..releases['400'] = _release('mb-400', 'Roots Rocking: The Island Anthology', 'Aswad', ['Don\'t Turn Around'])
        ..songSearch['Don\'t Turn Around'] = [
          SbTrack.fromJson({
            'id': 'r',
            'title': 'Don\'t Turn Around',
            'album_id': 'mb-dt',
            'album_title': 'Distant Thunder',
          }),
        ]
        ..releases['mb-dt'] = _release('mb-dt', 'Distant Thunder', 'Aswad', ['Don\'t Turn Around']);
      await on();
      expect(titlesAsked(), ['Jesus Be a Fence', 'Don\'t Turn Around']);
      expect([for (final a in downloads.asked) a.album.mbid], ['mb-101', 'mb-dt']);
    });

    test('nothing MusicBrainz knows, or Soulbeet refusing: nothing found, saying why', () async {
      mb.releases.clear();
      final d = await on();
      expect(downloads.asked, isEmpty);
      expect(d.note, DiscoverNote.nothingFound);

      mb.releases['200'] = _release('mb-200', 'Thirsty', 'Marvin Sapp', ['Never Would Have Made It']);
      downloads.failWith = 'Nobody is sharing it';
      await d.topUp();
      expect(d.lastError, 'Nobody is sharing it');
      expect(d.downloading, 0);
    });
  });

  group('when full', () {
    setUp(() {
      // 25 songs: the five oldest are three days old, the rest from today.
      nd.discover.addAll([
        for (var i = 0; i < 25; i++) _song('s$i', 'T$i', 'Someone', 'Al$i', ageDays: i >= 20 ? 3 : 0),
      ]);
    });

    test('waits for songs to be kept or removed', () async {
      final d = await on(const DiscoverSettings(on: true, maxSongs: 25));
      expect(downloads.asked, isEmpty);
      expect(removed, isEmpty);
      expect(d.note, DiscoverNote.full);
    });

    test('Make room: removes the oldest, never one from the last day, to fit a top-up', () async {
      final d = await on(const DiscoverSettings(on: true, maxSongs: 25, makeRoom: true));
      expect(removed.single, ['s24', 's23', 's22', 's21', 's20']);
      expect(titlesAsked(), hasLength(2));
      expect(hidden, isNot(contains('s24')));
      expect(d.songs, hasLength(20));
    });

    test('Make room with every song new: nothing removed', () async {
      for (final (i, s) in nd.discover.toList().indexed) {
        nd.discover[i] = _song(s.id, s.title, s.artist, s.album);
      }
      final d = await on(const DiscoverSettings(on: true, maxSongs: 25, makeRoom: true));
      expect(downloads.asked, isEmpty);
      expect(removed, isEmpty);
      expect(d.note, DiscoverNote.full);
    });
  });

  group('downloads across app restarts', () {
    test('what it needs is kept as the files show up, and picked up next time', () async {
      final first = await on(const DiscoverSettings(on: true, maxSongs: 25));
      downloads.fileArrives(downloads.byKey('batch-1')!, '@@peer\\Fred\\02 No Weapon.flac');
      await until(() => (store['state']! as String).contains('No Weapon.flac'), 'the item kept');
      first.dispose();

      final later = _Downloads('later');
      addTearDown(later.dispose);
      final d = make(using: later)..settings = const DiscoverSettings(on: true, maxSongs: 25);
      await until(() => later.resumed.length == 2, 'both picked up');
      await until(() => !d.toppingUp, 'the top-up');
      expect((later.resumed.first.batchId, later.resumed.first.releaseId), ('batch-1', 'mb-100'));
      expect(later.resumed.first.items, ['@@peer\\Fred\\02 No Weapon.flac']);
      final again = [
        for (final a in later.asked)
          for (final s in a.songs) s.title,
      ];
      expect(again, isNot(contains('No Weapon')), reason: 'not downloaded again');
      expect(again, isNot(contains('Never Would Have Made It')));

      // It arrives in Navidrome's Discover library: done.
      nd.discover.add(_song('s9', 'No Weapon', 'Fred Hammond', 'Pages of Life'));
      await d.refresh();
      final left = [for (final p in d.pending) p.title];
      expect(left, contains('Never Would Have Made It'));
      expect(left, isNot(contains('No Weapon')));
    });

    test('given up on: a download that failed, or one too old', () async {
      store['state'] = jsonEncode({
        'pending': [
          DiscoverPending(
            key: 'old',
            title: 'Gone',
            artist: 'A',
            album: 'B',
            releaseId: 'r',
            started: DateTime.now().subtract(const Duration(days: 3)),
          ).toJson(),
        ],
      });
      final d = await on();
      expect([for (final p in d.pending) p.key], ['batch-1', 'batch-2']);
      expect(downloads.resumed, isEmpty);

      downloads.byKey('batch-1')!
        ..phase = AlbumPhase.failed
        ..error = 'Import failed';
      await d.refresh();
      expect([for (final p in d.pending) p.key], ['batch-2']);
      expect(d.lastError, 'Import failed');
    });
  });

  group('keep and remove', () {
    setUp(() => nd.discover.addAll([_song('s1', 'One', 'A', 'X'), _song('s2', 'Two', 'B', 'Y')]));

    test('kept or removed: gone from Discover and from what\'s hidden', () async {
      final d = make();
      await d.refresh();
      expect(await d.keep(d.songs.firstWhere((s) => s.id == 's1')), isNull);
      expect(await d.remove(d.songs.single), isNull);
      expect(kept, [
        ['s1'],
      ]);
      expect(removed, [
        ['s2'],
      ]);
      expect(d.songs, isEmpty);
      expect(hidden, isEmpty);
    });

    test('refused: says why, and the song stays', () async {
      refuse['s1'] = 'your library already has a file there';
      final d = make();
      await d.refresh();
      expect(await d.keep(d.songs.firstWhere((s) => s.id == 's1')), 'your library already has a file there');
      expect(d.songs.map((s) => s.id), contains('s1'));
      expect(hidden, contains('s1'));
    });
  });

  test('settings: unknown limits fall back, and only raising one tops up', () async {
    expect(DiscoverSettings.fromJson({'on': true, 'maxSongs': 7, 'maxGb': 3}).maxSongs, 50);
    expect(DiscoverSettings.fromJson({'maxGb': 5}).maxGb, 5);
    final d = await on(const DiscoverSettings(on: true, maxSongs: 25));
    expect(downloads.asked, hasLength(2));
    d.settings = const DiscoverSettings(on: true, maxSongs: 25, makeRoom: true);
    expect(d.toppingUp, isFalse);
    d.settings = const DiscoverSettings(on: true, maxSongs: 50);
    expect(d.toppingUp, isTrue);
    await until(() => !d.toppingUp, 'the top-up');
  });
}
