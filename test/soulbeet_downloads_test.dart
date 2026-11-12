import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/data/soulbeet/soulbeet_client.dart';
import 'package:sonar/data/soulbeet/soulbeet_downloads.dart';
import 'package:sonar/data/soulbeet/soulbeet_models.dart';

import 'support/fake_soulbeet.dart';

/// Waits for [ok], failing with [what] after a few seconds.
Future<void> until(bool Function() ok, String what) async {
  for (var i = 0; i < 300; i++) {
    if (ok()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('timed out waiting for: $what');
}

/// A progress frame for files `transfer-0..n-1` of batch `b1`, all in [state].
Map<String, Object?> progress(
  Object state, {
  int files = 3,
  String? batch = 'b1',
  String prefix = 'transfer',
  int percent = 50,
  String? error,
  bool? retryable,
  String? kept,
}) => {
  'Progress': [
    for (var i = 0; i < files; i++)
      {
        'id': '$prefix-$i',
        'source': 'peer1',
        'item':
            r'music\Peter Tosh\Legalize It\'
            '0$i.flac',
        'size': 1000,
        'transferred': percent * 10,
        'state': state,
        'percent': percent,
        'speed': 2048.0,
        'error': error,
        'backend': 'slskd',
        'batch_id': batch,
        'batch_label': 'Legalize It',
        'local_path': kept,
        'import_output': null,
        'retryable': retryable ?? state == 'ImportSkipped',
        'can_choose_import': state == 'ImportSkipped',
      },
  ],
};

SbAlbum legalizeIt() =>
    SbAlbum.fromJson(((soulbeetFixture('search_album')['response']! as Map)['results']! as List).first as SbJson);

void main() {
  late FakeSoulbeet server;
  late SoulbeetClient client;
  late SoulbeetDownloads downloads;
  var rescans = 0;
  String? libraryId;

  setUp(() async {
    server = await FakeSoulbeet.start();
    rescans = 0;
    libraryId = null;
    client = SoulbeetClient(base: server.base, username: FakeSoulbeet.username, password: FakeSoulbeet.password);
    downloads = SoulbeetDownloads(
      client: client,
      rescan: () async {
        rescans++;
        return true;
      },
      findInLibrary: (title, artist) async => libraryId,
      pollEvery: const Duration(milliseconds: 10),
      searchFor: const Duration(seconds: 1),
      reconnectDelays: const [Duration(milliseconds: 50)],
      lingerAfterDone: const Duration(milliseconds: 200),
      lookupRetryAfter: const Duration(milliseconds: 100),
    );
  });

  tearDown(() async {
    downloads.dispose();
    client.close();
    await server.close();
  });

  Future<AlbumDownload> started() async {
    final d = await downloads.download(legalizeIt());
    await until(() => server.sockets.isNotEmpty, 'the live feed to open');
    return d;
  }

  test('takes the best FLAC copy itself, not Soulbeet\'s pick', () async {
    final d = await started();
    expect(server.bodiesFor('/api/auto-download'), isEmpty);
    final queued = (server.bodiesFor('/api/downloads/queue').single! as Map)['req'] as Map;
    final files = queued['items'] as List;
    expect(files, isNotEmpty);
    expect(files.every((f) => (f as Map)['quality'] == 'flac'), isTrue);
    expect(d.quality, 'flac');
    expect(d.phase, AlbumPhase.downloading);
  });

  test('downloading -> importing -> imported, then a rescan and Open album', () async {
    final d = await started();
    server.push(progress('InProgress'));
    await until(() => d.files.length == 3 && d.phase == AlbumPhase.downloading, 'files to show up');
    expect(d.key, 'b1', reason: 'the batch id replaces the local one');
    expect(d.fraction, closeTo(0.5, 0.01));
    expect(d.speed, 3 * 2048.0);
    server.push(progress('Completed', percent: 100));
    await until(() => d.phase == AlbumPhase.importing, 'all files in, waiting for the import');
    server.push(progress('Importing', percent: 100));
    libraryId = 'nd-album-1';
    server.push(progress('Imported', percent: 100));
    await until(() => d.phase == AlbumPhase.imported, 'imported');
    await until(() => d.libraryAlbumId == 'nd-album-1', 'found in Navidrome');
    expect(rescans, 1);
    expect(downloads.activeCount, 0);
  });

  test('no complete lossless copy: Soulbeet picks', () async {
    final poll = soulbeetFixture('download_search_poll_done')['response']! as Map<String, Object?>;
    server.overrides['/api/download/search/poll'] = (
      200,
      {
        ...poll,
        'groups': [
          for (final g in (poll['groups']! as List).cast<Map<String, Object?>>()) {...g, 'quality': 'm4a'},
        ],
      },
    );
    final d = await started();
    final auto = (server.bodiesFor('/api/auto-download').single! as Map)['req'] as Map;
    expect(auto['folder_path'], '/music');
    expect(d.key, 'batch-1');
    server.push({
      'AutoDownload': {
        'PickedSource': {'batch_id': 'batch-1', 'source': 'peer4', 'score': 1.0, 'quality': 'm4a', 'track_count': 9},
      },
    });
    await until(() => d.quality == 'm4a', 'Soulbeet\'s pick shown');
    expect(d.source, 'peer4');
  });

  test('a skipped import is retried with the release the user picked', () async {
    final d = await started();
    server.push(progress('Completed', percent: 100));
    await until(() => d.files.length == 3, 'files');
    server.push(progress('ImportSkipped', percent: 100, error: 'No close match (8 candidates)'));
    await until(() => server.bodiesFor('/api/downloads/retry-import').isNotEmpty, 'the retry');
    final retry = server.bodiesFor('/api/downloads/retry-import').single! as Map;
    expect(retry['choice'], {'MusicBrainz': 'e7d77d74-15e5-49a6-ba72-5b60b911ca2a'});
    expect(d.phase, AlbumPhase.importing);
    // A late "skipped" frame before the retry starts doesn't undo it.
    server.push(progress('ImportSkipped', percent: 100, error: 'No close match (8 candidates)'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(d.phase, AlbumPhase.importing);
    expect(server.bodiesFor('/api/downloads/retry-import'), hasLength(1), reason: 'only one automatic retry');
    server.push(progress('Importing', percent: 100));
    server.push(progress('Imported', percent: 100));
    await until(() => d.phase == AlbumPhase.imported, 'imported');
  });

  test('skipped again after the retry: the user picks a match', () async {
    final d = await started();
    server.push(progress('ImportSkipped', percent: 100, error: 'No close match'));
    await until(() => server.bodiesFor('/api/downloads/retry-import').isNotEmpty, 'the retry');
    server.push(progress('Importing', percent: 100));
    server.push(progress('ImportSkipped', percent: 100, error: 'Still no close match'));
    await until(() => d.phase == AlbumPhase.needsMatch, 'asks the user');
    expect(d.error, 'Still no close match');
    final matches = await downloads.matches(d);
    expect(matches, hasLength(8));
    await downloads.importWith(d, const SbChooseAsIs());
    expect((server.bodiesFor('/api/downloads/retry-import').last! as Map)['choice'], 'AsIs');
    expect(d.phase, AlbumPhase.importing);
  });

  // What Soulbeet sent when MusicBrainz kept answering 503 (2026-11-12).
  const lookupFailed =
      "Lookup failed in Acoustid: HTTPSConnectionPool(host='musicbrainz.org', port=443): "
      "Max retries exceeded (Caused by ResponseError('too many 503 error responses'))";
  Map<String, Object?> importFailed(String why) =>
      progress({'Failed': why}, percent: 100, error: why, retryable: true, kept: '/downloads/Legalize It [b1]');

  test('a failed MusicBrainz lookup is imported again by itself, once, without downloading', () async {
    final d = await started();
    server.push(progress('Completed', percent: 100));
    await until(() => d.files.length == 3, 'files');
    server.push(importFailed(lookupFailed));
    await until(() => d.retriedLookup, 'the lookup failure seen');
    expect(d.phase, AlbumPhase.importing, reason: 'waiting to try again, not failed');
    expect(server.bodiesFor('/api/downloads/retry-import'), isEmpty, reason: 'not straight away');
    await until(() => server.bodiesFor('/api/downloads/retry-import').isNotEmpty, 'the retry');
    expect((server.bodiesFor('/api/downloads/retry-import').single! as Map)['choice'], 'Auto');
    expect(server.bodiesFor('/api/downloads/queue'), hasLength(1));
    server.push(progress('Importing', percent: 100));
    server.push(progress('Imported', percent: 100));
    await until(() => d.phase == AlbumPhase.imported, 'imported');
  });

  test('failing again after that: Try again imports again, still without downloading', () async {
    final d = await started();
    server.push(importFailed(lookupFailed));
    await until(() => server.bodiesFor('/api/downloads/retry-import').isNotEmpty, 'the automatic retry');
    server.push(progress('Importing', percent: 100));
    server.push(importFailed(lookupFailed));
    await until(() => d.phase == AlbumPhase.failed, 'failed after one retry');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(server.bodiesFor('/api/downloads/retry-import'), hasLength(1), reason: 'only one automatic retry');
    expect(d.importFailed, isTrue);
    expect(d.error, startsWith('Lookup failed'));
    await downloads.tryAgain(d);
    expect(server.bodiesFor('/api/downloads/retry-import'), hasLength(2));
    expect(server.bodiesFor('/api/downloads/queue'), hasLength(1), reason: 'the files are already here');
    expect(d.phase, AlbumPhase.importing);
    // The old "failed" rows until the retry's first event don't undo it.
    server.push(importFailed(lookupFailed));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(d.phase, AlbumPhase.importing);
  });

  test('an import that failed some other way waits for Try again', () async {
    final d = await started();
    server.push(importFailed('beets exited with code 1'));
    await until(() => d.phase == AlbumPhase.failed, 'failed');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(server.bodiesFor('/api/downloads/retry-import'), isEmpty);
    expect(d.importFailed, isTrue);
  });

  test('Try again after a failed download downloads again', () async {
    final d = await started();
    server.push(progress({'Failed': 'Transfer rejected: Banned'}, percent: 0, retryable: true));
    await until(() => d.phase == AlbumPhase.failed, 'failed');
    expect(d.importFailed, isFalse, reason: 'nothing arrived to import');
    await downloads.tryAgain(d);
    expect(server.bodiesFor('/api/downloads/queue'), hasLength(2));
    expect(server.bodiesFor('/api/downloads/retry-import'), isEmpty);
  });

  test('cancel stops the files still coming', () async {
    final d = await started();
    server.push(progress('InProgress'));
    await until(() => d.files.length == 3, 'files');
    await downloads.cancel(d);
    expect(server.bodiesFor('/api/downloads/cancel'), hasLength(3));
    expect(d.phase, AlbumPhase.cancelled);
    expect(downloads.activeCount, 0);
  });

  test('all files failing fails the album, saying why', () async {
    final d = await started();
    server.push(progress({'Failed': 'Transfer rejected: Banned'}, percent: 0));
    await until(() => d.phase == AlbumPhase.failed, 'failed');
    expect(d.error, 'Transfer rejected: Banned');
  });

  test('the feed comes back after a drop while something is downloading', () async {
    final d = await started();
    server.push(progress('InProgress'));
    await until(() => d.files.isNotEmpty, 'files');
    await server.dropSockets();
    await until(() => server.sockets.isNotEmpty, 'reconnected');
    server.push(progress('Completed', percent: 100));
    await until(() => d.phase == AlbumPhase.importing, 'events after the reconnect');
  });

  test('albums started somewhere else show up too', () async {
    await downloads.watch();
    await until(() => server.sockets.isNotEmpty, 'feed');
    server.push(progress('InProgress', batch: 'web-batch', prefix: 'other'));
    await until(() => downloads.albums.isNotEmpty, 'the other album');
    final a = downloads.albums.single;
    expect(a.title, 'Legalize It');
    expect(a.album, isNull);
    expect(a.phase, AlbumPhase.downloading);
  });

  test('a file\'s event arriving before the queue reply joins its album', () async {
    // The server sends the first progress while answering the queue call.
    server.onRequest = (path, _) {
      if (path == '/api/downloads/queue') server.push(progress('InProgress'));
    };
    final d = await started();
    await until(() => d.files.length == 3, 'files folded in');
    expect(downloads.albums, hasLength(1));
    expect(d.key, 'b1');
  });

  test('...even when that early event has no batch id', () async {
    server.onRequest = (path, _) {
      if (path == '/api/downloads/queue') server.push(progress('InProgress', batch: null));
    };
    final d = await started();
    await until(() => d.files.length == 3, 'files folded in');
    expect(downloads.albums, hasLength(1), reason: 'no stray album left behind');
    expect(downloads.albums.single.album, isNotNull);
  });

  test('downloading the same album twice reuses the first', () async {
    final a = await started();
    final b = await downloads.download(legalizeIt());
    expect(identical(a, b), isTrue);
    expect(server.bodiesFor('/api/downloads/queue'), hasLength(1));
  });

  const unanswered = {'search_id': 'search-1', 'groups': <Object>[], 'has_more': false, 'state': 'Completed'};
  String? searchedArtist(Object? body) => (((body! as Map)['data'] as Map)['album'] as Map)['artist'] as String?;

  test('a search nobody answers is tried again under a shorter artist name', () async {
    // Soulseek peers ignore some phrases ("Kanye West"); the shorter name gets answers.
    server.onRequest = (path, body) {
      if (path != '/api/download/search/start') return;
      if (searchedArtist(body) == 'Peter Tosh') {
        server.overrides['/api/download/search/poll'] = (200, unanswered);
      } else {
        server.overrides.remove('/api/download/search/poll');
      }
    };
    final d = await started();
    expect(server.bodiesFor('/api/download/search/start').map(searchedArtist), ['Peter Tosh', 'Peter']);
    expect(server.bodiesFor('/api/auto-download'), isEmpty);
    expect(d.quality, 'flac');
    expect(d.phase, AlbumPhase.downloading);
    expect(d.album!.artist, 'Peter Tosh', reason: 'the album is still shown as itself');
  });

  test('"Choose source" tries the shorter name too, without a "nothing found" in between', () async {
    server.onRequest = (path, body) {
      if (path != '/api/download/search/start') return;
      if (searchedArtist(body) == 'Peter Tosh') {
        server.overrides['/api/download/search/poll'] = (200, unanswered);
      } else {
        server.overrides.remove('/api/download/search/poll');
      }
    };
    final seen = await downloads.findSources(legalizeIt()).toList();
    expect(seen.where((r) => r.done && r.sources.isEmpty), isEmpty);
    expect(seen.last.sources, isNotEmpty);
  });

  test('only lossy copies under the shorter name: Soulbeet picks, under that name', () async {
    final poll = soulbeetFixture('download_search_poll_done')['response']! as Map<String, Object?>;
    final lossy = {
      ...poll,
      'groups': [
        for (final g in (poll['groups']! as List).cast<Map<String, Object?>>()) {...g, 'quality': 'm4a'},
      ],
    };
    server.onRequest = (path, body) {
      if (path != '/api/download/search/start') return;
      server.overrides['/api/download/search/poll'] = (200, searchedArtist(body) == 'Peter Tosh' ? unanswered : lossy);
    };
    await started();
    final auto = (server.bodiesFor('/api/auto-download').single! as Map)['req'] as Map;
    expect(((auto['query'] as Map)['album'] as Map)['artist'], 'Peter');
  });

  test('nobody sharing it under any name fails clearly, without Soulbeet searching again', () async {
    server.overrides['/api/download/search/poll'] = (200, unanswered);
    final d = await downloads.download(legalizeIt());
    expect(server.bodiesFor('/api/download/search/start').map(searchedArtist), ['Peter Tosh', 'Peter']);
    expect(server.bodiesFor('/api/auto-download'), isEmpty);
    expect(d.phase, AlbumPhase.failed);
    expect(d.error, contains('Nobody on Soulseek'));
  });

  test('no music folder is a clear failure', () async {
    server.overrides['/api/folders'] = (200, <Object>[]);
    final d = await downloads.download(legalizeIt());
    expect(d.phase, AlbumPhase.failed);
    expect(d.error, contains('no music folder'));
  });
}
