// Get music (Soulbeet) screens, from the recorded replies in
// test/fixtures/soulbeet, saved as build/screens/g*.png.
//
//   flutter test test/visual --dart-define=SCREENSHOTS=true
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/data/soulbeet/get_music_search.dart';
import 'package:sonar/data/soulbeet/soulbeet_client.dart';
import 'package:sonar/data/soulbeet/soulbeet_downloads.dart';
import 'package:sonar/data/soulbeet/soulbeet_models.dart';
import 'package:sonar/core/theme.dart';
import 'package:sonar/data/subsonic/models.dart';
import 'package:sonar/state/providers.dart';
import 'package:sonar/state/soulbeet_providers.dart';

import 'harness.dart';

Object? _reply(String name) =>
    (jsonDecode(File('test/fixtures/soulbeet/$name.json').readAsStringSync()) as Map)['response'];

List<SbTrack> _tracks(String name) => [
  for (final t in ((_reply(name)! as Map)['results']! as List).cast<SbJson>()) SbTrack.fromJson(t),
];

const _ohYeah = 'eb30b1a0-3a0a-47cb-b2b1-0856f0cb6aa8';

List<SbAlbum> _albums(String name) => [
  for (final a in ((_reply(name)! as Map)['results']! as List).cast<SbJson>()) SbAlbum.fromJson(a),
];

/// Answers from the recordings instead of a server.
class _RecordedDownloads extends SoulbeetDownloads {
  _RecordedDownloads()
    : super(
        client: SoulbeetClient(base: Uri.parse('http://127.0.0.1:9'), username: 'me', password: 'x'),
      );

  @override
  Stream<SbSourceSearch> findSources(SbAlbum album) async* {
    yield SbSourceSearch.fromJson(_reply('download_search_poll_done')! as SbJson);
  }

  @override
  Future<List<SbMatch>> matches(AlbumDownload d) async => [
    for (final c in ((_reply('import_choices')! as Map)['candidates']! as List).cast<SbJson>()) SbMatch.fromJson(c),
  ];

  @override
  Future<void> watch() async {}

  /// What Download asked for: the album, and the songs when only some.
  final asked = <({SbAlbum album, List<SbTrack> songs})>[];

  @override
  Future<AlbumDownload> download(
    SbAlbum album, {
    int? trackCount,
    SbSource? chosen,
    List<SbTrack> songs = const [],
  }) async {
    asked.add((album: album, songs: songs));
    final d = AlbumDownload.debug('asked-${asked.length}', album: album, songs: songs);
    debugAdd(d);
    return d;
  }
}

SbProgress _file(int i, String state, {int transferred = 0, double speed = 0, String? batch}) => SbProgress.fromJson({
  'id': 'f$i',
  'source': 'peer1',
  'item': 'music\\Album\\0$i.flac',
  'size': 30000000,
  'transferred': transferred,
  'state': state,
  'percent': transferred / 300000,
  'speed': speed,
  'batch_id': batch,
});

_RecordedDownloads _seeded(SbAlbum legalize, SbAlbum exodus) {
  final d = _RecordedDownloads();
  final now = DateTime.now();
  AlbumDownload album(String key, SbAlbum? a, AlbumPhase phase, int minutesAgo, {String? label}) => AlbumDownload.debug(
    key,
    album: a,
    label: label,
    releaseId: a?.mbid,
    started: now.subtract(Duration(minutes: minutesAgo)),
  )..phase = phase;

  final downloading = album('b1', legalize, AlbumPhase.downloading, 0)
    ..source = 'peer1'
    ..quality = 'flac';
  for (var i = 0; i < 9; i++) {
    downloading.files['f$i'] = _file(
      i,
      i < 3 ? 'Completed' : (i == 3 ? 'InProgress' : 'Queued'),
      transferred: i < 3 ? 30000000 : (i == 3 ? 12000000 : 0),
      speed: i == 3 ? 2400000 : 0,
    );
  }
  final retrying = album('b2', exodus, AlbumPhase.importing, 3)..retriedWithRelease = true;
  retrying.files['x'] = _file(0, 'Importing', transferred: 30000000);
  final unsure = album('b3', null, AlbumPhase.needsMatch, 6, label: 'Kaya')
    ..error = 'No close match (8 candidates)'
    ..source = 'peer2';
  unsure.files['y'] = _file(0, 'ImportSkipped', transferred: 30000000);
  final done = album('b4', null, AlbumPhase.imported, 12, label: 'Burnin\'')..libraryAlbumId = 'al2';
  done.files['z'] = _file(0, 'Imported', transferred: 30000000);
  final failed = album('b5', null, AlbumPhase.failed, 20, label: 'Catch a Fire')..error = 'Transfer rejected: Banned';
  for (final a in [downloading, retrying, unsure, done, failed]) {
    d.debugAdd(a);
  }
  return d;
}

SbAlbum _found(String group, String title, String artist, {bool pressed = true}) =>
    SbAlbum.found(pressing: pressed ? 'p-$group' : null, groupId: group, title: title, artist: artist);

/// "kanye west": tributes by name, his albums (without pressings) by artist.
final _kanye = GetMusicResults(
  albums: [
    _found('g-cruel', 'Cruel Summer', 'Various Artists'),
    _found('g-lullaby', 'Lullaby Renditions of Kanye West', 'Rockabye Baby!'),
    _found('g-8bit', '8-Bit Versions of Kanye West', '8-Bit Misfits'),
  ],
  byArtist: [
    _found('g-late', 'Late Registration', 'Kanye West', pressed: false),
    _found('g-yeezus', 'Yeezus', 'Kanye West', pressed: false),
    _found('g-demos', 'Yeezus Demos', 'Kanye West', pressed: false),
  ],
  artist: 'Ye (Kanye West)',
  listeners: const {'g-cruel': 14571, 'g-lullaby': 71, 'g-8bit': 4, 'g-late': 49758, 'g-yeezus': 30000, 'g-demos': 12},
  done: true,
);

void main() {
  final legalize = _albums('search_album').single;
  final exodus = _albums('search_album_no_artist');
  final marley = exodus.firstWhere((a) => a.artist.startsWith('Bob Marley'));
  final results = [legalize, marley, ...exodus.where((a) => !identical(a, marley)).take(6)];

  // Albums found through an artist wait here for their pressing.
  var pressing = Completer<void>();
  setUp(() => pressing = Completer<void>());

  List<Override> overrides({required SoulbeetDownloads downloads}) => [
    soulbeetAvailableProvider.overrideWithValue(true),
    soulbeetHealthProvider.overrideWith((_) async => SbHealth.fromJson(_reply('system_health')! as SbJson)),
    soulbeetDownloadsProvider.overrideWith((_) => downloads),
    soulbeetSearchProvider.overrideWith(
      (_, raw) => Stream.value(
        raw.toLowerCase().contains('pure colo')
            ? GetMusicResults(
                songs: _tracks('search_track_pure_colour'),
                respelled: 'Steve Lacy - pure colour',
                done: true,
              )
            : raw.toLowerCase().contains('jpeg')
            ? GetMusicResults(byArtist: _albums('search_album_by_artist'), artist: 'JPEGMAFIA', done: true)
            : raw.toLowerCase().contains('kanye')
            ? _kanye
            : GetMusicResults(albums: results, done: true),
      ),
    ),
    albumSongsProvider.overrideWith((_, album) async {
      if (album.id == _ohYeah) return SbAlbumDetail.fromJson(_reply('album_oh_yeah')! as SbJson);
      // Each album as itself, with the recorded album's songs; an artist's
      // album waits for its pressing.
      final recorded = SbAlbumDetail.fromJson(_reply('album')! as SbJson);
      if (album.needsPressing) {
        await pressing.future;
        return SbAlbumDetail(
          SbAlbum.found(
            pressing: 'pressing-of-${album.groupId}',
            groupId: album.groupId!,
            title: album.title,
            artist: album.artist,
          ),
          recorded.tracks,
        );
      }
      return SbAlbumDetail(album, recorded.tracks);
    }),
    // Late Registration is partly yours: one of its songs.
    albumProvider.overrideWith(
      (_, id) async => id == 'al-late'
          ? const Album(
              id: 'al-late',
              name: 'Late Registration',
              artist: 'Kanye West',
              songs: [Song(id: 's1', title: 'Legalize It')],
            )
          : throw StateError('no album $id'),
    ),
    libraryAlbumForProvider.overrideWith(
      (_, a) async => a.artist.startsWith('Bob Marley')
          ? const Album(id: 'al2', name: 'Exodus', artist: 'Bob Marley & The Wailers', coverArt: 'c2')
          : a.title == 'Late Registration'
          ? const Album(id: 'al-late', name: 'Late Registration', artist: 'Kanye West')
          : null,
    ),
  ];

  testWidgets('render get music on the phone', skip: !screenshotsEnabled, (tester) async {
    final downloads = _seeded(legalize, exodus.first);
    final h = await pumpSonar(tester, extra: (_) => overrides(downloads: downloads));
    h.router.go('/search');
    await h.shot('g01_search_with_get_music');
    expect(find.text('Get music'), findsOneWidget);

    h.router.push('/search/get-music', extra: 'Peter Tosh - Legalize It');
    await h.shot('g02_get_music_results');
    expect(find.text('Yours'), findsOneWidget);
    expect(find.text('Legalize It'), findsWidgets);

    // A result with no download yet opens to Download / Choose source.
    await tester.tap(find.text(results[3].title).at(2));
    await h.shot('g03_album_sheet');
    expect(find.text('Choose source'), findsOneWidget);
    expect(find.text('Burial'), findsOneWidget);

    await tester.tap(find.text('Choose source'));
    await h.shot('g04_choose_source');
    expect(find.text('Best'), findsOneWidget);
    // Close the source picker, then the album sheet.
    await tester.tapAt(const Offset(20, 40));
    await h.settle();
    await tester.tapAt(const Offset(20, 40));
    await h.settle();
    expect(find.text('Choose source'), findsNothing);

    h.router.go('/search');
    await h.settle();
    h.router.push('/search/get-music/downloads');
    await h.shot('g05_downloads');
    expect(find.text('Pick a match'), findsOneWidget);
    expect(find.text('Open album'), findsOneWidget);
    expect(find.textContaining('Filing it as the release you picked'), findsOneWidget);
    expect(find.textContaining('Transfer rejected'), findsOneWidget);

    await tester.tap(find.text('Pick a match'));
    await h.shot('g06_pick_a_match');
    expect(find.textContaining('9/9 songs'), findsWidgets);

    // A song's name finds the album it's on, opened with the song picked out.
    await tester.tapAt(const Offset(20, 40));
    await h.settle();
    h.router.go('/search');
    await h.settle();
    h.router.push('/search/get-music', extra: 'Steve Lacy - Pure Color');
    await h.shot('g09_song_results');
    expect(find.text('Top result'), findsOneWidget);
    await tester.tap(find.text('pure colour'));
    await h.shot('g10_song_album_sheet');
    expect(find.text('Steve Lacy'), findsOneWidget, reason: "the album's artist, not the song's");
    await h.close();
  });

  Future<Harness> open(WidgetTester tester, String search, {SoulbeetDownloads? downloads}) async {
    final h = await pumpSonar(tester, extra: (_) => overrides(downloads: downloads ?? _seeded(legalize, exodus.first)));
    h.router.go('/search');
    await h.settle(4);
    h.router.push('/search/get-music', extra: search);
    await h.settle(6);
    return h;
  }

  testWidgets('a song as the top result opens its album, named for the album, the song picked out', (tester) async {
    final h = await open(tester, 'Steve Lacy - Pure Color');
    expect(find.text('Also searched "Steve Lacy - pure colour"'), findsOneWidget);
    expect(find.text('Top result'), findsOneWidget);
    expect(find.text('Song · Steve Lacy, Erykah Badu'), findsOneWidget);
    expect(find.text('Songs'), findsNothing, reason: 'the only song is the top result');

    await tester.tap(find.text('pure colour'));
    await h.settle(6);
    expect(find.text('Steve Lacy'), findsOneWidget, reason: "the album's artist, not the song's");
    expect(find.text('2026 · 10 songs · 40 min'), findsOneWidget);
    final picked = tester.widget<Text>(find.text('pure colour').last);
    expect(picked.style?.color, SonarColors.accentDefault, reason: 'the song searched for, picked out');
    final other = tester.widget<Text>(find.text('doom'));
    expect(other.style?.color, isNot(SonarColors.accentDefault));
    await h.close();
  });

  testWidgets('"kanye west": the artist on top, his albums in a row, the filler behind See all', (tester) async {
    final h = await open(tester, 'kanye west');
    if (screenshotsEnabled) await h.shot('g11_ranked_artist');
    expect(find.text('Ye (Kanye West)'), findsOneWidget);
    expect(find.text('Artist'), findsOneWidget);
    expect(find.text('Albums'), findsOneWidget);
    double x(String t) => tester.getTopLeft(find.text(t)).dx;
    expect(x('Late Registration'), lessThan(x('Yeezus')), reason: 'most listened first');
    expect(x('Yeezus'), lessThan(x('Cruel Summer')));
    expect(find.text('Various Artists'), findsOneWidget, reason: 'each card names its artist');
    for (final filler in ['Yeezus Demos', 'Lullaby Renditions of Kanye West', '8-Bit Versions of Kanye West']) {
      expect(find.text(filler, skipOffstage: false), findsNothing, reason: '$filler: hardly anyone listens');
    }

    await tester.tap(find.text('See all 6'));
    await h.settle();
    if (screenshotsEnabled) await h.shot('g12_see_all_albums');
    for (final t in ['Late Registration', 'Yeezus', 'Cruel Summer', 'Lullaby Renditions of Kanye West']) {
      expect(find.text(t, skipOffstage: false), findsOneWidget, reason: '$t, once See all is tapped');
    }
    await h.close();
  });

  testWidgets("tapping the artist shows all their albums", (tester) async {
    final h = await open(tester, 'kanye west');
    await tester.tap(find.text('Ye (Kanye West)'));
    await h.settle();
    expect(find.text('See all 6'), findsNothing);
    expect(find.text('Yeezus Demos', skipOffstage: false), findsOneWidget);
    await h.close();
  });

  testWidgets('a search fires once typing pauses, not on every key', (tester) async {
    final searched = <String>[];
    final h = await pumpSonar(
      tester,
      extra: (_) => [
        ...overrides(downloads: _seeded(legalize, exodus.first)),
        soulbeetSearchProvider.overrideWith((_, raw) {
          searched.add(raw);
          return Stream.value(GetMusicResults(query: raw, albums: results, done: true));
        }),
      ],
    );
    h.router.go('/search');
    await h.settle(4);
    h.router.push('/search/get-music');
    await h.settle(4);
    final field = find.byType(TextField);
    for (final typed in ['k', 'ka', 'kan', 'kany', 'kanye']) {
      await tester.enterText(field, typed);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(searched, isEmpty, reason: 'still typing');
    await tester.pump(const Duration(milliseconds: 600));
    await h.settle();
    expect(searched, ['kanye']);
    await tester.enterText(field, 'kanye west');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await h.settle();
    expect(searched, ['kanye', 'kanye west'], reason: 'Enter searches at once');
    await tester.pump(const Duration(seconds: 1));
    expect(searched, hasLength(2), reason: 'and the pause after it searches nothing more');
    await h.close();
  });

  testWidgets("an artist's album finds its pressing before it can download", (tester) async {
    final h = await open(tester, 'kanye west');
    await tester.tap(find.text('Yeezus'));
    await h.settle(4);
    FilledButton downloadButton() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Download'));
    expect(downloadButton().onPressed, isNull, reason: 'no pressing to download yet');
    expect(find.text('Burial'), findsNothing, reason: 'songs come with the pressing');

    pressing.complete();
    await h.settle(6);
    expect(downloadButton().onPressed, isNotNull);
    expect(find.text('Burial'), findsOneWidget, reason: "the pressing's songs");
    await h.close();
  });

  testWidgets('songs picked on an album download alone, with the ones you have', (tester) async {
    final downloads = _seeded(legalize, exodus.first);
    final h = await open(tester, 'kanye west', downloads: downloads);
    pressing.complete();
    await tester.tap(find.text('Late Registration'));
    await h.settle(6);
    expect(find.text('You have 1 of its 9 songs.'), findsOneWidget);
    expect(find.text('Tap songs to download just those.'), findsOneWidget);

    final ownedRow = find.ancestor(of: find.text('Legalize It').last, matching: find.byType(InkWell)).first;
    expect(tester.widget<InkWell>(ownedRow).onTap, isNull, reason: 'a song you have is not one to pick');
    await tester.tap(find.text('Legalize It').last);
    await h.settle();
    expect(find.textContaining('Download 1 song'), findsNothing, reason: 'a song you have is not picked');

    await tester.tap(find.text('Burial'));
    await tester.tap(find.text('No Sympathy'));
    await h.settle();
    expect(find.text('Download 2 songs'), findsOneWidget);
    expect(find.textContaining('you already have from this album download again too'), findsOneWidget);
    if (screenshotsEnabled) await h.shot('g13_pick_songs');
    await tester.tap(find.text('No Sympathy'));
    await h.settle();
    expect(find.text('Download 1 song'), findsOneWidget, reason: 'tapping again unpicks');

    await tester.tap(find.text('Download 1 song'));
    await h.settle(4);
    final asked = downloads.asked.single;
    expect(asked.album.id, 'pressing-of-g-late', reason: 'the pressing, not the album found without one');
    expect(asked.songs.map((t) => t.title), ['Legalize It', 'Burial'], reason: 'the one picked, and the one you have');
    await h.close();
  });

  testWidgets('Clear unpicks every song, and Download is the whole album again', (tester) async {
    final downloads = _seeded(legalize, exodus.first);
    final h = await open(tester, 'kanye west', downloads: downloads);
    pressing.complete();
    await tester.tap(find.text('Yeezus'));
    await h.settle(6);
    await tester.tap(find.text('Burial'));
    await h.settle();
    await tester.tap(find.text('Clear'));
    await h.settle();
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await h.settle(4);
    expect(downloads.asked.single.songs, isEmpty);
    await h.close();
  });

  testWidgets('render get music on the PC', skip: !screenshotsEnabled, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final downloads = _seeded(legalize, exodus.first);
    final h = await pumpSonar(
      tester,
      size: const Size(1440, 900),
      devicePixelRatio: 1,
      padding: FakeViewPadding.zero,
      extra: (_) => overrides(downloads: downloads),
    );
    h.router.go('/home');
    await h.settle();
    await tester.tap(find.text('Get music'));
    await h.settle();
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Peter Tosh - Legalize It');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await h.shot('g07_pc_get_music', pixelRatio: 1);
    expect(find.text('Yours'), findsOneWidget);
    await tester.tap(find.byTooltip('Downloads'));
    await h.shot('g08_pc_downloads', pixelRatio: 1);
    await h.close();
    debugDefaultTargetPlatformOverride = null;
  });
}
