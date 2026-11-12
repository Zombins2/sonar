// Get music (Soulbeet) screens, from the recorded replies in
// test/fixtures/soulbeet, saved as build/screens/g*.png.
//
//   flutter test test/visual --dart-define=SCREENSHOTS=true
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/data/soulbeet/soulbeet_client.dart';
import 'package:sonar/data/soulbeet/soulbeet_downloads.dart';
import 'package:sonar/data/soulbeet/soulbeet_models.dart';
import 'package:sonar/data/subsonic/models.dart';
import 'package:sonar/state/soulbeet_providers.dart';

import 'harness.dart';

Object? _reply(String name) =>
    (jsonDecode(File('test/fixtures/soulbeet/$name.json').readAsStringSync()) as Map)['response'];

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

void main() {
  final legalize = _albums('search_album').single;
  final exodus = _albums('search_album_no_artist');
  final marley = exodus.firstWhere((a) => a.artist.startsWith('Bob Marley'));
  final results = [legalize, marley, ...exodus.where((a) => !identical(a, marley)).take(6)];

  List<Override> overrides({required SoulbeetDownloads downloads}) => [
    soulbeetAvailableProvider.overrideWithValue(true),
    soulbeetHealthProvider.overrideWith((_) async => SbHealth.fromJson(_reply('system_health')! as SbJson)),
    soulbeetDownloadsProvider.overrideWith((_) => downloads),
    soulbeetAlbumSearchProvider.overrideWith((_, _) async => results),
    soulbeetAlbumDetailProvider.overrideWith((_, _) async => SbAlbumDetail.fromJson(_reply('album')! as SbJson)),
    libraryAlbumForProvider.overrideWith(
      (_, a) async => a.artist.startsWith('Bob Marley')
          ? const Album(id: 'al2', name: 'Exodus', artist: 'Bob Marley & The Wailers', coverArt: 'c2')
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
    expect(find.text('In your library'), findsOneWidget);
    expect(find.text('Legalize It'), findsWidgets);

    // A result with no download yet opens to Download / Choose source.
    await tester.tap(find.text(results[3].artist).first);
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
    expect(find.text('In your library'), findsOneWidget);
    await tester.tap(find.byTooltip('Downloads'));
    await h.shot('g08_pc_downloads', pixelRatio: 1);
    await h.close();
    debugDefaultTargetPlatformOverride = null;
  });
}
