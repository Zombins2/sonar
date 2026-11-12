import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/data/soulbeet/soulbeet_client.dart';
import 'package:sonar/data/soulbeet/soulbeet_models.dart';
import 'package:sonar/data/soulbeet/source_pick.dart';

import 'support/fake_soulbeet.dart';

Object? reply(String fixture) => soulbeetFixture(fixture)['response'];
Object? sent(String fixture) => (soulbeetFixture(fixture)['request']! as Map)['body'];

void main() {
  // ---- The recorded replies parse (a Soulbeet update that renames a field
  // the app needs fails here, by name) ----------------------------------------------
  group('recorded replies', () {
    test('album search', () {
      final results = (reply('search_album')! as Map)['results']! as List;
      final a = SbAlbum.fromJson(results.first as SbJson);
      expect(a.title, 'Legalize It');
      expect(a.artist, 'Peter Tosh');
      expect(a.mbid, 'e7d77d74-15e5-49a6-ba72-5b60b911ca2a');
      expect(
        a.coverUrl().toString(),
        'https://coverartarchive.org/release/e7d77d74-15e5-49a6-ba72-5b60b911ca2a/front-250',
      );
    });

    test('album search without an artist, and track search', () {
      final albums = ((reply('search_album_no_artist')! as Map)['results']! as List).cast<SbJson>().map(
        SbAlbum.fromJson,
      );
      expect(albums, isNotEmpty);
      final tracks = ((reply('search_track')! as Map)['results']! as List)
          .cast<SbJson>()
          .map(SbTrack.fromJson)
          .toList();
      expect(tracks.first.title.toLowerCase(), contains('police'));
    });

    test('album tracks, with "mm:ss" lengths', () {
      final d = SbAlbumDetail.fromJson(reply('album')! as SbJson);
      expect(d.tracks, hasLength(9));
      expect(d.tracks.first.title, 'Legalize It');
      expect(d.tracks.first.duration, const Duration(minutes: 4, seconds: 41));
      expect(d.tracks.map((t) => t.duration!.inSeconds).reduce((a, b) => a + b), greaterThan(30 * 60));
    });

    test('folders and health', () {
      final f = SbFolder.fromJson((reply('folders')! as List).first as SbJson);
      expect(f.path, '/music');
      final h = SbHealth.fromJson(reply('system_health')! as SbJson);
      expect(h.ready, isTrue);
      expect(h.navidromeOnline, isTrue);
    });

    test('sources: quality, slot and speed from slskd\'s own fields', () {
      final s = SbSourceSearch.fromJson(reply('download_search_poll_done')! as SbJson);
      expect(s.done, isTrue);
      expect(s.sources, isNotEmpty);
      final first = s.sources.first;
      expect(first.user, 'peer1');
      expect(first.quality, 'flac');
      expect(first.lossless, isTrue);
      expect(first.itemCount, 9);
      expect(first.freeSlot, isTrue);
      expect(first.uploadSpeed, 4991388);
      expect(first.files.first.bitDepth, 16);
      expect(first.files.first.raw['backend_data'], isA<String>());
    });

    test('every recorded WebSocket frame decodes, none unknown', () {
      final frames = [
        ...(soulbeetFixture('downloads_updates_ws')['frames']! as List),
        ...(soulbeetFixture('downloads_updates_ws_retry')['frames']! as List),
      ];
      final events = frames.map(SbEvent.fromJson).toList();
      expect(events.whereType<SbUnknownEvent>(), isEmpty);
      final auto = events.whereType<SbAutoDownloadEvent>().map((e) => e.event.kind).toList();
      expect(auto, [SbAutoKind.searching, SbAutoKind.scoring, SbAutoKind.pickedSource, SbAutoKind.downloading]);
      final picked = events.whereType<SbAutoDownloadEvent>().firstWhere((e) => e.event.kind == SbAutoKind.pickedSource);
      expect(picked.event.quality, 'm4a');
      final states = {
        for (final e in events.whereType<SbProgressEvent>())
          for (final f in e.files) f.state.kind,
      };
      expect(
        states,
        containsAll([
          SbStateKind.queued,
          SbStateKind.inProgress,
          SbStateKind.completed,
          SbStateKind.importing,
          SbStateKind.importSkipped,
          SbStateKind.imported,
        ]),
      );
      final skipped = events
          .whereType<SbProgressEvent>()
          .expand((e) => e.files)
          .firstWhere((f) => f.state.kind == SbStateKind.importSkipped);
      expect(skipped.error, contains('No close match'));
      expect(skipped.canChooseImport, isTrue);
      expect(skipped.batchId, '9cbb02ba-17df-4961-8b6b-bf5710d57717');
      expect(skipped.fileName, '01 - Legalize It.m4a');
    });

    test('states with a value, and events Sonar doesn\'t know', () {
      expect(SbState.fromJson({'Failed': 'Peer offline'}).kind, SbStateKind.failed);
      expect(SbState.fromJson({'Failed': 'Peer offline'}).detail, 'Peer offline');
      expect(SbState.fromJson({'ImportQueued': 2}).detail, '2');
      expect(SbState.fromJson('Brand new').kind, SbStateKind.unknown);
      expect(SbEvent.fromJson({'SomethingNew': {}}), isA<SbUnknownEvent>());
      final replaced = SbEvent.fromJson({
        'Replaced': {
          'previous_item': 'a.flac',
          'entry': (soulbeetFixture('downloads_updates_ws')['frames']! as List).whereType<Map>().firstWhere(
            (f) => f.containsKey('Progress'),
          )['Progress'][0],
        },
      });
      expect(replaced, isA<SbReplacedEvent>());
    });

    test('import matches', () {
      final r = reply('import_choices')! as SbJson;
      final m = [for (final c in (r['candidates']! as List).cast<SbJson>()) SbMatch.fromJson(c)];
      expect(m, hasLength(8));
      expect(m.first.perMille, 880);
      expect(m.first.matchedTracks, 9);
      expect(m.first.totalTracks, 9);
    });

    test('a field the app needs going missing is named', () {
      expect(
        () => SbAlbum.fromJson({'title': 'x'}),
        throwsA(isA<SoulbeetFormatException>().having((e) => e.toString(), 'message', contains('"id"'))),
      );
    });
  });

  // ---- The client against a fake server ----------------------------------------------
  group('client', () {
    late FakeSoulbeet server;
    late SoulbeetClient client;
    final tokens = <String?>[];

    setUp(() async {
      server = await FakeSoulbeet.start();
      tokens.clear();
      client = SoulbeetClient(
        base: server.base,
        username: FakeSoulbeet.username,
        password: FakeSoulbeet.password,
        onToken: tokens.add,
      );
    });
    tearDown(() async {
      client.close();
      await server.close();
    });

    test('logs in once, then sends only the cookie', () async {
      await client.searchAlbums('Legalize It', artist: 'Peter Tosh');
      await client.folders();
      expect(server.logins, 1);
      expect(tokens, ['token-1']);
      final login = server.bodiesFor('/api/auth/login').single! as Map;
      expect(login.keys, unorderedEquals(['username', 'password']));
      // No other request carries the password.
      for (final (path, body) in server.requests) {
        if (path != '/api/auth/login') expect(jsonEncode(body), isNot(contains(FakeSoulbeet.password)));
      }
    });

    test('bodies are exactly what Soulbeet\'s own page sent', () async {
      await client.searchAlbums('Legalize It', artist: 'Peter Tosh');
      expect(server.bodiesFor('/api/metadata/search/album').single, sent('search_album'));
      await client.album('e7d77d74-15e5-49a6-ba72-5b60b911ca2a');
      expect(server.bodiesFor('/api/metadata/album').single, sent('album'));
      final album = SbAlbum.fromJson(((reply('search_album')! as Map)['results']! as List).first as SbJson);
      expect(await client.startSourceSearch(album), reply('download_search_start'));
      expect(server.bodiesFor('/api/download/search/start').single, sent('download_search_start'));
      await client.pollSources('a2466b9f-a2ef-4f6e-8216-61443897a33a');
      expect(server.bodiesFor('/api/download/search/poll').single, {
        'input': {'search_id': 'a2466b9f-a2ef-4f6e-8216-61443897a33a', 'backend': null},
      });
    });

    test('an empty artist is sent as null, like the page does', () async {
      await client.searchAlbums('Exodus', artist: '  ');
      expect(server.bodiesFor('/api/metadata/search/album').single, sent('search_album_no_artist'));
    });

    test('auto-download names the folder and returns the batch', () async {
      final album = SbAlbum.fromJson(((reply('search_album')! as Map)['results']! as List).first as SbJson);
      final folder = SbFolder.fromJson((reply('folders')! as List).first as SbJson);
      expect(await client.autoDownload(album, folder), 'batch-1');
      final req = (server.bodiesFor('/api/auto-download').single! as Map)['req'] as Map;
      expect(req['folder_id'], folder.id);
      expect(req['folder_path'], '/music');
      expect((req['query'] as Map)['album'], album.request);
      expect((req['query'] as Map)['album'], isNot(contains('kind')));
    });

    test('auto-download refused says why', () async {
      server.overrides['/api/auto-download'] = (200, {'Error': 'Folder not found'});
      final album = SbAlbum.fromJson(((reply('search_album')! as Map)['results']! as List).first as SbJson);
      final folder = SbFolder.fromJson((reply('folders')! as List).first as SbJson);
      await expectLater(
        client.autoDownload(album, folder),
        throwsA(isA<SoulbeetException>().having((e) => e.message, 'message', 'Folder not found')),
      );
    });

    test('queueing sends the files back unchanged', () async {
      final s = SbSourceSearch.fromJson(reply('download_search_poll_done')! as SbJson);
      final folder = SbFolder.fromJson((reply('folders')! as List).first as SbJson);
      final ids = await client.queue(s.sources.first.files, folder);
      expect(ids, hasLength(s.sources.first.files.length));
      final req = (server.bodiesFor('/api/downloads/queue').single! as Map)['req'] as Map;
      expect(req['target_folder'], '/music');
      expect(req['items'], [for (final f in s.sources.first.files) f.raw]);
    });

    test('retry with the release the user picked, as recorded', () async {
      final frames = soulbeetFixture('downloads_updates_ws')['frames']! as List;
      final skipped = SbEvent.fromJson(frames.lastWhere((f) => (f as Map).containsKey('Progress'))) as SbProgressEvent;
      await client.retryImport(skipped.files.first, const SbChooseRelease('e7d77d74-15e5-49a6-ba72-5b60b911ca2a'));
      expect(server.bodiesFor('/api/downloads/retry-import').single, sent('retry_import'));
      final matches = await client.importChoices(skipped.files.first);
      expect(matches, hasLength(8));
      expect(server.bodiesFor('/api/downloads/import-choices').single, sent('import_choices'));
      expect(
        const SbChooseMatch(SbMatch(dataSource: 'MusicBrainz', id: 'x', artist: '', title: '', perMille: 0)).toJson(),
        {
          'Candidate': {'data_source': 'MusicBrainz', 'id': 'x'},
        },
      );
      expect(const SbChooseAsIs().toJson(), 'AsIs');
    });

    test('an expired cookie logs in again once and carries on', () async {
      await client.folders();
      server.token = 'token-2';
      final f = await client.folders();
      expect(f.single.path, '/music');
      expect(server.logins, 2);
      expect(tokens, ['token-1', null, 'token-2']);
    });

    test('a saved cookie skips the login', () async {
      final saved = SoulbeetClient(
        base: server.base,
        username: FakeSoulbeet.username,
        password: 'wrong',
        token: 'token-1',
      );
      expect(await saved.health(), isA<SbHealth>());
      expect(server.logins, 0);
      saved.close();
    });

    test('the cookie kept from last time is used, and replaced when stale', () async {
      final kept = SoulbeetClient(
        base: server.base,
        username: FakeSoulbeet.username,
        password: FakeSoulbeet.password,
        savedToken: () async => 'token-1',
      );
      await kept.folders();
      expect(server.logins, 0);
      kept.close();
      final stale = SoulbeetClient(
        base: server.base,
        username: FakeSoulbeet.username,
        password: FakeSoulbeet.password,
        savedToken: () async => 'old-token',
        onToken: tokens.add,
      );
      await stale.folders();
      expect(server.logins, 1);
      expect(tokens, [null, 'token-1']);
      stale.close();
    });

    test('a wrong password is a bad login, not a crash', () async {
      final bad = SoulbeetClient(base: server.base, username: FakeSoulbeet.username, password: 'wrong');
      await expectLater(
        bad.folders(),
        throwsA(isA<SoulbeetException>().having((e) => e.kind, 'kind', SoulbeetErrorKind.badLogin)),
      );
      bad.close();
    });

    test('nobody listening is unreachable', () async {
      final port = server.base.port;
      await server.close();
      final gone = SoulbeetClient(
        base: Uri.parse('http://127.0.0.1:$port'),
        username: 'me',
        password: 'x',
        timeout: const Duration(seconds: 3),
      );
      await expectLater(
        gone.folders(),
        throwsA(isA<SoulbeetException>().having((e) => e.kind, 'kind', SoulbeetErrorKind.unreachable)),
      );
      gone.close();
      server = await FakeSoulbeet.start();
    });

    test('the live feed replays the recorded frames as events', () async {
      server.frames = soulbeetFixture('downloads_updates_ws')['frames']! as List;
      final events = await (await client.updates())
          .take(server.frames.length)
          .toList()
          .timeout(const Duration(seconds: 10));
      expect(events.whereType<SbUnknownEvent>(), isEmpty);
      expect(events.whereType<SbProgressEvent>().last.files.first.state.kind, SbStateKind.importSkipped);
    });

    test('the live feed logs in again when its cookie expired', () async {
      await client.folders();
      server.token = 'token-2';
      server.frames = [
        {
          'AutoDownload': {
            'Downloading': {'batch_id': 'b'},
          },
        },
      ];
      final first = await (await client.updates()).first.timeout(const Duration(seconds: 10));
      expect(first, isA<SbAutoDownloadEvent>());
      expect(server.logins, 2);
    });
  });

  // ---- Which copy to download ------------------------------------------------------
  group('pickSource', () {
    SbSource src(
      String user, {
      String quality = 'flac',
      int items = 9,
      double score = 1,
      bool free = true,
      int speed = 1000000,
      int queue = 0,
    }) => SbSource.fromJson({
      'source': user,
      'title': 'Album',
      'item_count': items,
      'total_size': items * 1000,
      'quality': quality,
      'score': score,
      'items': [
        for (var i = 0; i < items; i++)
          {
            'id': '$user/$i.$quality',
            'title': 't$i',
            'size': 1000,
            'quality': quality,
            'backend_data': jsonEncode({'hasFreeUploadSlot': free, 'uploadSpeed': speed, 'queueLength': queue}),
          },
      ],
    });

    test('FLAC beats a better-scored M4A (Soulbeet\'s own pick took the M4A)', () {
      expect(pickSource([src('a', quality: 'm4a'), src('b', score: 0.95)], tracks: 9)!.user, 'b');
    });

    test('a copy missing tracks is never picked', () {
      expect(pickSource([src('a', items: 8)], tracks: 9), isNull);
      expect(pickSource([src('a', items: 8)], tracks: 0)!.user, 'a');
    });

    test('a poor match is never picked', () {
      expect(pickSource([src('a', score: 0.5)], tracks: 9), isNull);
    });

    test('no lossless copy means let Soulbeet choose', () {
      expect(pickSource([src('a', quality: 'mp3'), src('b', quality: 'm4a')], tracks: 9), isNull);
    });

    test('a free slot, then a short queue, then speed, then score', () {
      expect(pickSource([src('slow', speed: 10), src('busy', free: false, speed: 99999999)], tracks: 9)!.user, 'slow');
      expect(
        pickSource([src('long', free: false, queue: 9), src('short', free: false, queue: 1)], tracks: 9)!.user,
        'short',
      );
      expect(pickSource([src('slow', speed: 10), src('fast', speed: 5000)], tracks: 9)!.user, 'fast');
      expect(pickSource([src('meh', score: 0.92), src('good', score: 0.99)], tracks: 9)!.user, 'good');
    });

    test('the recorded search: the copy with a free slot and the most speed', () {
      final s = SbSourceSearch.fromJson(reply('download_search_poll_done')! as SbJson);
      final pick = pickSource(s.sources, tracks: 9)!;
      expect(pick.lossless, isTrue);
      expect(pick.freeSlot, isTrue);
      for (final other in s.sources.where(
        (o) => o.lossless && o.freeSlot && o.itemCount >= 9 && o.score >= minPickScore,
      )) {
        expect(pick.uploadSpeed >= other.uploadSpeed || pick.queueLength < other.queueLength, isTrue);
      }
    });
  });

  test('searchArtists: the artist, then shorter starts that still name someone', () {
    List<String> names(String artist) =>
        SbAlbum.fromJson({'id': 'x', 'title': 'T', 'artist': artist}).searchArtists;
    expect(names('Kanye West'), ['Kanye West', 'Kanye']);
    expect(names('Bob Marley & The Wailers'), ['Bob Marley & The Wailers', 'Bob Marley', 'Bob']);
    expect(names('The Beatles'), ['The Beatles'], reason: '"The" alone would match anything');
    expect(names('DJ Shadow'), ['DJ Shadow']);
    expect(names('Lil Wayne'), ['Lil Wayne'], reason: '"Lil" alone would match half of Soulseek');
    expect(names('Radiohead'), ['Radiohead']);
    expect(names('  '), isEmpty);
    final a = SbAlbum.fromJson({'id': 'x', 'title': 'T', 'artist': 'Kanye West', 'mbid': 'm'});
    expect(a.searchedAs('Kanye').request, {'id': 'x', 'title': 'T', 'artist': 'Kanye', 'mbid': 'm'});
    expect(identical(a.searchedAs('Kanye West'), a), isTrue);
  });

  test('soulbeetBaseFor: Tailscale port 8443, or loopback straight to Soulbeet', () {
    expect(
      soulbeetBaseFor('https://my-pc.example-tailnet.ts.net').toString(),
      'https://my-pc.example-tailnet.ts.net:8443',
    );
    expect(
      soulbeetBaseFor('https://my-pc.example-tailnet.ts.net/').toString(),
      'https://my-pc.example-tailnet.ts.net:8443',
    );
    expect(soulbeetBaseFor('http://localhost:4533').toString(), 'http://127.0.0.1:9765');
  });
}
