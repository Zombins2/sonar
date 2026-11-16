import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/data/soulbeet/soulbeet_client.dart';
import 'package:sonar/data/soulbeet/soulbeet_downloads.dart';
import 'package:sonar/data/soulbeet/soulbeet_models.dart';
import 'package:sonar/data/soulbeet/source_pick.dart';

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

  test('some songs: Soulbeet finds those alone, and beets files them as the album', () async {
    final tracks = SbAlbumDetail.fromJson(soulbeetFixture('album')['response']! as SbJson).tracks;
    final songs = [tracks[1], tracks[3]];
    final d = await downloads.download(legalizeIt(), songs: songs);
    await until(() => server.sockets.isNotEmpty, 'the live feed to open');
    expect(server.bodiesFor('/api/download/search/start'), isEmpty, reason: 'no copy of the whole album is looked for');
    final query = ((server.bodiesFor('/api/auto-download').single! as Map)['req'] as Map)['query'] as Map;
    expect(query['album'], legalizeIt().request);
    expect(query['tracks'], [songs[0].raw, songs[1].raw], reason: "Soulbeet's Track, as its album lookup sent it");
    expect((d.key, d.label, d.phase), ('batch-1', 'Legalize It · 2 songs', AlbumPhase.downloading));

    // beets won't file part of an album unasked (missing songs make it
    // unsure): it's filed as the album's release.
    server.push(progress('ImportSkipped', files: 2, batch: 'batch-1', percent: 100, error: 'No close match'));
    await until(() => server.bodiesFor('/api/downloads/retry-import').isNotEmpty, 'the retry');
    final retry = server.bodiesFor('/api/downloads/retry-import').single! as Map;
    expect(retry['choice'], {'MusicBrainz': 'e7d77d74-15e5-49a6-ba72-5b60b911ca2a'});
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

  group('Discover', () {
    const discoverFolder = {'id': 'f-discover', 'user_id': 'u1', 'name': 'Discover', 'path': '/music-discover'};
    final library = (soulbeetFixture('folders')['response']! as List).single! as Map<String, Object?>;
    List<SbTrack> oneSong() => [SbAlbumDetail.fromJson(soulbeetFixture('album')['response']! as SbJson).tracks[1]];

    /// The files queued, as `(sharer's path, target folder)`.
    List<(String, String)> queued() => [
      for (final b in server.bodiesFor('/api/downloads/queue'))
        for (final f in (((b! as Map)['req'] as Map)['items'] as List))
          ('${(f as Map)['id']}', '${((b as Map)['req'] as Map)['target_folder']}'),
    ];

    test('a Discover song goes to its own folder, made the first time', () async {
      final d = await downloads.download(legalizeIt(), songs: oneSong(), forDiscover: true);
      expect(server.bodiesFor('/api/folders').whereType<Map>().single, {'name': 'Discover', 'path': '/music-discover'});
      expect(queued().single.$2, '/music-discover');
      expect(d.forDiscover, isTrue);
    });

    test('with both folders there, each download takes its own, whichever is listed first', () async {
      server.overrides['/api/folders'] = (200, [discoverFolder, library]);
      await downloads.download(legalizeIt(), songs: oneSong());
      await downloads.download(legalizeIt(), songs: oneSong(), forDiscover: true);
      expect(((server.bodiesFor('/api/auto-download').single! as Map)['req'] as Map)['folder_path'], '/music');
      expect(queued().single.$2, '/music-discover');
      expect(server.bodiesFor('/api/folders').whereType<Map>(), isEmpty, reason: 'nothing made');
    });

    test('a Discover song is taken from a copy of its own album: that one file, lossless', () async {
      final d = await downloads.download(legalizeIt(), songs: oneSong(), forDiscover: true);
      expect(server.bodiesFor('/api/download/search/start'), hasLength(1), reason: 'its album looked for');
      expect(server.bodiesFor('/api/auto-download'), isEmpty, reason: 'not any copy found by its name');
      expect(queued(), [(r'music\Peter Tosh\Legalize It\18 Burial.flac', '/music-discover')]);
      expect((d.source, d.quality, d.phase), ('peer1', 'flac', AlbumPhase.downloading));
    });

    test('only on compilations: not downloaded, saying why (beets would file it as one)', () async {
      final poll = soulbeetFixture('download_search_poll_done')['response']! as Map<String, Object?>;
      server.overrides['/api/download/search/poll'] = (
        200,
        {
          ...poll,
          'groups': [
            for (final g in (poll['groups']! as List).cast<Map<String, Object?>>())
              {...g, 'title': 'Reggae Hits Volume 3'},
          ],
        },
      );
      final d = await downloads.download(legalizeIt(), songs: oneSong(), forDiscover: true);
      expect(d.phase, AlbumPhase.failed);
      expect(d.error, contains('"Burial" from Legalize It'));
      expect(server.bodiesFor('/api/downloads/queue'), isEmpty);
      expect(server.bodiesFor('/api/auto-download'), isEmpty);
    });

    test('an imported Discover song is rescanned in, but not looked for in the library', () async {
      libraryId = 'nd-album-1';
      final d = await downloads.download(legalizeIt(), songs: oneSong(), forDiscover: true);
      await until(() => server.sockets.isNotEmpty, 'the live feed to open');
      server.push(progress('Imported', files: 1, batch: 'batch-1', percent: 100));
      await until(() => d.phase == AlbumPhase.imported, 'imported');
      await until(() => rescans == 1, 'the rescan');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(d.libraryAlbumId, isNull);
    });

    group('picking up a download from before the app closed', () {
      Future<AlbumDownload> resume({List<String> items = const ['@@share\\a\\01.flac']}) => downloads.resumeDiscover(
        batchId: 'b1',
        releaseId: 'rel-1',
        items: items,
        label: 'Country Road',
        started: DateTime(2026, 11, 16),
        quietFor: const Duration(milliseconds: 300),
      );

      test('nothing heard from it: its skipped import is filed as the release', () async {
        final d = await resume();
        final retry = server.bodiesFor('/api/downloads/retry-import').single! as Map;
        expect(retry, {
          'item': '@@share\\a\\01.flac',
          'choice': {'MusicBrainz': 'rel-1'},
        });
        expect((d.key, d.forDiscover, d.phase), ('b1', true, AlbumPhase.importing));
        server.push(progress('Importing', percent: 100));
        server.push(progress('Imported', percent: 100));
        await until(() => d.phase == AlbumPhase.imported, 'imported');
      });

      test('still going: left to finish, then filed as the release when skipped', () async {
        final resumed = resume();
        await until(() => server.sockets.isNotEmpty, 'the live feed to open');
        // Every file in, beets about to import: still "importing", so only
        // the files having shown up say it's under way.
        server.push(progress('Completed', percent: 100));
        final d = await resumed;
        expect(d.phase, AlbumPhase.importing);
        expect(server.bodiesFor('/api/downloads/retry-import'), isEmpty, reason: 'not while it\'s under way');
        expect(d.files, hasLength(3));
        server.push(progress('ImportSkipped', percent: 100, error: 'No close match'));
        await until(() => server.bodiesFor('/api/downloads/retry-import').isNotEmpty, 'the retry');
        expect((server.bodiesFor('/api/downloads/retry-import').single! as Map)['choice'], {'MusicBrainz': 'rel-1'});
      });

      test('Soulbeet no longer has it (it restarted): failed, saying why', () async {
        server.overrides['/api/downloads/retry-import'] = (404, 'Import not found');
        final d = await resume();
        expect(d.phase, AlbumPhase.failed);
        expect(d.error, 'Import not found');
      });

      test('no file seen before the app closed: nothing to retry with', () async {
        final d = await resume(items: const []);
        expect(server.bodiesFor('/api/downloads/retry-import'), isEmpty);
        expect(d.phase, AlbumPhase.failed);
      });
    });
  });

  group('pickSongs: where a song alone comes from', () {
    String? from(List<SbSource> copies, {String album = 'Legalize It', List<String> songs = const ['Burial']}) {
      final p = pickSongs(copies, album: album, songs: songs);
      return p == null ? null : '${p.source.user}: ${[for (final f in p.files) f.title].join(', ')}';
    }

    test('a copy of its album, never a compilation that has it too', () {
      expect(
        from([
          _copy('a', 'Reggae Hits 3', ['Burial']),
          _copy('b', 'Legalize It', ['Legalize It', 'Burial']),
        ]),
        'b: Burial',
      );
      expect(
        from([
          _copy('a', 'Reggae Hits 3', ['Burial']),
        ]),
        isNull,
      );
    });

    test('lossless before a quicker lossy copy', () {
      expect(
        from([
          _copy('mp3', 'Legalize It', ['Burial'], quality: 'mp3'),
          _copy('flac', 'Legalize It', ['Burial'], queue: 9),
        ]),
        'flac: Burial',
      );
    });

    test('every song asked for, or not that copy', () {
      final copies = [
        _copy('a', 'Legalize It', ['Burial']),
        _copy('b', 'Legalize It', ['Burial', 'No Sympathy']),
      ];
      expect(from(copies, songs: ['Burial', 'No Sympathy']), 'b: Burial, No Sympathy');
    });

    test('longer forms of a name count, short names must match whole', () {
      expect(
        from(
          [
            _copy('a', 'BULLY (Deluxe)', ['BULLY']),
          ],
          album: 'BULLY',
          songs: ['BULLY'],
        ),
        'a: BULLY',
      );
      expect(
        from(
          [
            _copy('a', 'Super Ape', ['Chase the Devil feat. Jahdan']),
          ],
          album: 'Super Ape',
          songs: ['Chase the Devil'],
        ),
        'a: Chase the Devil feat. Jahdan',
      );
      expect(
        from(
          [
            _copy('a', 'Yeezus', ['Ye']),
          ],
          album: 'Ye',
          songs: ['Ye'],
        ),
        isNull,
        reason: 'Ye is not Yeezus',
      );
    });
  });

  test('a login with no music folder yet gets one made, then downloads into it', () async {
    // Soulbeet keeps folders per user; a new login has none (recorded 2026-11-12).
    server.overrides['/api/folders'] = (200, <Object>[]);
    final d = await downloads.download(legalizeIt());
    expect(server.bodiesFor('/api/folders').whereType<Map>().single, {'name': 'Music', 'path': '/music'});
    final queued = (server.bodiesFor('/api/downloads/queue').single! as Map)['req'] as Map;
    expect(queued['target_folder'], '/music');
    expect(d.phase, AlbumPhase.downloading);
  });

  test('Soulbeet refusing to make the folder fails clearly', () async {
    server.overrides['/api/folders'] = (200, <Object>[]);
    server.overrides['POST /api/folders'] = (500, 'Failed to create directory: Permission denied');
    final d = await downloads.download(legalizeIt());
    expect(d.phase, AlbumPhase.failed);
    expect(d.error, contains('Permission denied'));
    expect(server.bodiesFor('/api/downloads/queue'), isEmpty);
  });

  test('a download shows on the result it started from: its pressing, the album, or Deezer\'s copy', () {
    final list = SoulbeetDownloads(
      client: SoulbeetClient(base: Uri.parse('http://127.0.0.1:9'), username: 'u', password: 'p'),
    );
    addTearDown(list.dispose);
    final pressed = SbAlbum.found(pressing: 'p1', groupId: 'g1', title: 'BULLY', artist: 'Ye', deezerId: '949');
    list.debugAdd(AlbumDownload.debug('k', album: pressed, releaseId: 'p1'));
    expect(list.forFound(SbAlbum.deezer(id: '949', title: 'BULLY', artist: 'Kanye West'))?.key, 'k');
    expect(list.forFound(SbAlbum.found(groupId: 'g1', title: 'BULLY', artist: 'Ye'))?.key, 'k');
    expect(list.forFound(SbAlbum.deezer(id: '1010', title: 'BULLY - DELUXE', artist: 'Kanye West')), isNull);
    expect(list.forFound(SbAlbum.found(pressing: 'p2', groupId: 'g2', title: 'X', artist: 'Y')), isNull);
  });
}

/// One sharer's copy: a folder titled [title] holding [songs].
SbSource _copy(String user, String title, List<String> songs, {String quality = 'flac', int queue = 0}) =>
    SbSource.fromJson({
      'source': user,
      'title': title,
      'item_count': songs.length,
      'quality': quality,
      'score': 0.95,
      'items': [
        for (final s in songs)
          {
            'id': '$user/$title/$s.$quality',
            'title': s,
            'quality': quality,
            'size': 1000,
            'backend_data': '{"hasFreeUploadSlot": true, "queueLength": $queue}',
          },
      ],
    });
