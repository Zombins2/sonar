// Sonar Connect end to end on this machine: the real relay
// (server/sonar_connect/relay.py, run with Python), a fake Navidrome that
// checks logins, and two real players (a "PC" and a "phone") on the fake
// native player.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:sonar/audio/audio_handler.dart';
import 'package:sonar/audio/playback_source.dart';
import 'package:sonar/connect/connect_client.dart';
import 'package:sonar/connect/connect_link.dart';
import 'package:sonar/connect/remote_player.dart';
import 'package:sonar/data/subsonic/models.dart';
import 'package:sonar/state/providers.dart';

import 'support/fake_server.dart';
import 'support/player_harness.dart';

const _user = 'tester';
const _password = 'connect-test-only-pw';

Map<String, String> _proof() {
  final salt = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  return {'u': _user, 't': md5.convert(utf8.encode(_password + salt)).toString(), 's': salt};
}

/// Scans the fake Navidrome was asked to start.
var _scans = 0;

/// Answers Subsonic `ping` (and `startScan`, for the test account acting as
/// an admin) the way Navidrome does: ok for the right token.
Future<HttpServer> _fakeNavidrome() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((r) {
    final q = r.uri.queryParameters;
    final s = q['s'] ?? '';
    final login = q['u'] == _user && q['t'] == md5.convert(utf8.encode(_password + s)).toString();
    final ok = (r.uri.path == '/rest/ping.view' || r.uri.path == '/rest/startScan.view') && login;
    if (ok && r.uri.path == '/rest/startScan.view') _scans++;
    r.response
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode({
          'subsonic-response': {'status': ok ? 'ok' : 'failed'},
        }),
      )
      ..close();
  });
  return server;
}

class _Relay {
  _Relay(this.process, this.port);
  final Process process;
  final int port;
  final log = StringBuffer();

  static Future<_Relay> start(int navidromePort, {Map<String, String> env = const {}}) async {
    final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = free.port;
    await free.close();
    final process = await Process.start(
      Platform.isWindows ? 'python' : 'python3',
      ['relay.py'],
      workingDirectory: 'server/sonar_connect',
      environment: {'PORT': '$port', 'HOST': '127.0.0.1', 'NAVIDROME_URL': 'http://127.0.0.1:$navidromePort', ...env},
    );
    final relay = _Relay(process, port);
    process.stderr.transform(utf8.decoder).listen(relay.log.write);
    process.stdout.drain<void>();
    final http = HttpClient();
    for (var i = 0; i < 100; i++) {
      try {
        final r = await (await http.getUrl(Uri.parse('http://127.0.0.1:$port/health'))).close();
        await r.drain<void>();
        if (r.statusCode == 200) {
          http.close();
          return relay;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    process.kill();
    throw StateError('relay did not start: ${relay.log}');
  }
}

/// One app: a player and its link to the relay.
class _Device {
  _Device(this.handler, this.link);
  final SonarAudioHandler handler;
  final ConnectLink link;
  ConnectClient get client => link.client;
  String get id => client.me.id;

  static Future<_Device> start(
    PlayerHarness h,
    _Relay relay,
    String id,
    String kind, {
    List<Song> songs = const [],
    PlaybackSource? source,
    Duration startTimeout = const Duration(seconds: 15),
  }) async {
    final handler = await h.start(songs, play: songs.isNotEmpty, source: source);
    final link = ConnectLink(
      handler: handler,
      startTimeout: startTimeout,
      client: ConnectClient(
        base: Uri.parse('http://127.0.0.1:${relay.port}'),
        me: ConnectDeviceInfo(id: id, name: kind, kind: kind),
        loginProof: _proof,
        retryDelays: const [Duration(milliseconds: 200)],
      ),
    )..start();
    await waitFor(() => link.client.status.value == ConnectStatus.online);
    return _Device(handler, link);
  }

  ConnectDevice? see(String otherId) => client.devices.value[otherId];
}

List<Song> _album(int n) => [for (var i = 1; i <= n; i++) testSong('t$i', albumId: 'al')];

void main() {
  final harness = PlayerHarness();
  late HttpServer navidrome;
  late _Relay relay;
  final devices = <_Device>[];

  setUpAll(() async {
    navidrome = await _fakeNavidrome();
    relay = await _Relay.start(navidrome.port);
  });

  tearDownAll(() async {
    relay.process.kill();
    await navidrome.close(force: true);
  });

  setUp(() {
    harness.setUp(); // (A fresh fake player: no load delay.)
    // The test binding answers every HTTP request with 400; these go to the
    // relay and fake Navidrome on this machine.
    HttpOverrides.global = null;
  });

  tearDown(() async {
    for (final d in devices) {
      await d.link.dispose();
    }
    devices.clear();
    await harness.tearDown();
  });

  Future<_Device> device(
    String id,
    String kind, {
    List<Song> songs = const [],
    PlaybackSource? source,
    Duration startTimeout = const Duration(seconds: 15),
  }) async {
    final d = await _Device.start(harness, relay, id, kind, songs: songs, source: source, startTimeout: startTimeout);
    devices.add(d);
    return d;
  }

  test('a wrong password gets nowhere', () async {
    final client = ConnectClient(
      base: Uri.parse('http://127.0.0.1:${relay.port}'),
      me: const ConnectDeviceInfo(id: 'intruder', name: 'x', kind: 'pc'),
      loginProof: () => {'u': _user, 't': '0' * 32, 's': 'salt'},
      retryDelays: const [Duration(milliseconds: 100)],
    )..start();
    addTearDown(client.dispose);
    await waitFor(() => client.status.value == ConnectStatus.unavailable);
    expect(client.devices.value, isEmpty);
  });

  test('the phone sees what the PC is playing, and follows it', () async {
    final pc = await device(
      'pc',
      'pc',
      songs: _album(3),
      source: const PlaybackSource(SourceKind.album, 'al', 'Night'),
    );
    final phone = await device('phone', 'phone');
    await waitFor(() => phone.see('pc')?.state['song'] != null);
    expect(phone.client.devices.value.keys, ['pc'], reason: 'the other devices, not itself');
    final seen = phone.see('pc')!;
    expect(Song.fromJson(seen.state['song']! as Map<String, Object?>).id, 't1');
    expect(seen.playing, isTrue);
    expect(jsonList(seen.state['queue']).map((s) => s['id']), ['t1', 't2', 't3']);
    expect(PlaybackSource.fromJson(seen.state['source'])?.title, 'Night');

    await pc.handler.skipToNext();
    await waitFor(() => (phone.see('pc')?.state['song'] as Map?)?['id'] == 't2');
    await pc.handler.pause();
    await waitFor(() => phone.see('pc')?.playing == false);
    expect(phone.see('pc')!.position(DateTime.now()).inSeconds, lessThan(3), reason: 'paused near the start of t2');

    // A seek on the PC reaches the phone without waiting for the 15 s heartbeat.
    await pc.handler.seek(const Duration(seconds: 12));
    await waitFor(
      () =>
          (phone.see('pc')!.position(DateTime.now()) - const Duration(seconds: 12)).abs() < const Duration(seconds: 1),
    );
  });

  test('the phone drives the PC: play, pause, skip, seek, volume', () async {
    final pc = await device('pc', 'pc', songs: _album(3));
    final phone = await device('phone', 'phone');
    await waitFor(() => phone.see('pc')?.hasSong == true);
    final remote = RemotePlayer(client: phone.client, deviceId: 'pc', subsonic: null);
    addTearDown(remote.dispose);

    await remote.pause();
    await waitFor(() => !pc.handler.player.playing);
    await remote.play();
    await waitFor(() => pc.handler.player.playing);
    await remote.skipToNext();
    await waitFor(() => pc.handler.currentSong?.id == 't2');
    await remote.seek(const Duration(seconds: 9));
    await waitFor(() => (pc.handler.player.position - const Duration(seconds: 9)).abs() < const Duration(seconds: 1));
    remote.setUserVolume(0.3);
    remote.setUserVolume(0.35); // A drag: the last value wins.
    await waitFor(() => pc.handler.userVolume.value == 0.35);
    expect(remote.volume, 0.35);
  });

  test('the phone edits the PC\'s queue', () async {
    final pc = await device('pc', 'pc', songs: _album(4));
    final phone = await device('phone', 'phone');
    await waitFor(() => phone.see('pc')?.hasSong == true);
    final remote = RemotePlayer(client: phone.client, deviceId: 'pc', subsonic: null);
    addTearDown(remote.dispose);
    List<String> ids() => [for (final s in pc.handler.songs) s.id];

    await remote.addToQueue([testSong('extra')]);
    await waitFor(() => ids().contains('extra'));
    expect(ids(), ['t1', 'extra', 't2', 't3', 't4'], reason: 'queued songs play next');
    expect(pc.handler.queuedFlags[1], isTrue);

    await remote.removeQueueItemAt(3); // t3
    await waitFor(() => !ids().contains('t3'));
    await remote.moveQueueItem(3, 2); // t4 before t2
    await waitFor(() => ids().join() == 't1extrat4t2');
    await remote.skipToQueueItem(2);
    await waitFor(() => pc.handler.currentSong?.id == 't4');
    await remote.playSongs([testSong('n1'), testSong('n2')], index: 1);
    await waitFor(() => pc.handler.currentSong?.id == 'n2');

    // And the phone's view of it keeps up.
    final items = await remote.queue.firstWhere((q) => q.length == 2);
    expect(items.map((i) => i.id), ['n1', 'n2']);
  });

  test('a long queue: the phone sees a window, and its indices land right', () async {
    final pc = await device('pc', 'pc', songs: _album(300));
    await pc.handler.skipToQueueItem(120);
    await waitFor(() => pc.handler.currentSong?.id == 't121');
    final phone = await device('phone', 'phone');
    final remote = RemotePlayer(client: phone.client, deviceId: 'pc', subsonic: null);
    addTearDown(remote.dispose);
    // Not the window from when it started at t1 (the window moves with the song).
    final state = await remote.playbackState.firstWhere((s) => (s.queueIndex ?? 0) >= connectQueueBefore);
    final items = await remote.queue.firstWhere((q) => q.isNotEmpty && q.first.id != 't1');
    final at = state.queueIndex!;
    expect(items[at].id, 't121');
    expect(items.last.id, 't300', reason: 'everything after it (179 songs, under the 200 limit)');
    expect(items.first.id, isNot('t1'), reason: 'but not the whole queue before it');
    expect(at, greaterThanOrEqualTo(connectQueueBefore), reason: 'and enough of what came before');
    await remote.skipToQueueItem(at + 3);
    await waitFor(() => pc.handler.currentSong?.id == 't124');
    await remote.removeQueueItemAt(at + 5); // t126
    await waitFor(() => !pc.handler.songs.any((s) => s.id == 't126'));
    expect(pc.handler.songs.length, 299);
  });

  test('moving playback from the PC to the phone, and back', () async {
    final pc = await device(
      'pc',
      'pc',
      songs: _album(4),
      source: const PlaybackSource(SourceKind.album, 'al', 'Night'),
    );
    await pc.handler.addToQueue([testSong('q1')]);
    await pc.handler.skipToNext(); // Now on q1 (queued), then t2...
    await pc.handler.seek(const Duration(seconds: 7));
    await pc.handler.cycleRepeat(); // Repeat all.
    final phone = await device('phone', 'phone');
    await waitFor(() => phone.see('pc')?.hasSong == true);

    // From the phone: "play here".
    final took = phone.link.tookOver.first;
    expect(await phone.link.moveTo(null, from: 'pc'), isTrue);
    await took;
    await waitFor(() => phone.handler.player.playing);
    expect(phone.handler.currentSong?.id, 'q1');
    // At the same second: from 0 it couldn't reach 7 s within this wait.
    await waitFor(
      () => phone.handler.player.position >= const Duration(seconds: 7),
      timeout: const Duration(seconds: 2),
    );
    expect(phone.handler.player.position.inSeconds, lessThan(11));
    expect([for (final s in phone.handler.songs) s.id], ['t1', 'q1', 't2', 't3', 't4']);
    expect(phone.handler.queuedFlags, [false, true, false, false, false], reason: 'q1 is still a queued song');
    expect(phone.handler.player.loopMode, LoopMode.all);
    expect(phone.handler.source?.title, 'Night');
    await waitFor(() => !pc.handler.player.playing);

    // And back to the PC, from the phone.
    await phone.handler.skipToNext();
    await waitFor(() => phone.handler.currentSong?.id == 't2');
    expect(await phone.link.moveTo('pc', from: null), isTrue);
    await waitFor(() => pc.handler.player.playing && pc.handler.currentSong?.id == 't2');
    await waitFor(() => !phone.handler.player.playing);
  });

  test('no silence while a slow PC opens the stream: the phone plays on until it does', () async {
    final phone = await device('phone', 'phone', songs: _album(3));
    final pc = await device('pc', 'pc');
    await waitFor(() => phone.see('pc') != null);
    DateTime? phoneStopped;
    DateTime? pcAudible;
    final s1 = phone.handler.player.playingStream.listen((on) => on ? null : phoneStopped ??= DateTime.now());
    final s2 = pc.handler.player.playerStateStream.listen((s) {
      if (s.playing && s.processingState == ProcessingState.ready) pcAudible ??= DateTime.now();
    });
    addTearDown(s1.cancel);
    addTearDown(s2.cancel);
    harness.platform.loadDelay = const Duration(milliseconds: 1500); // Only the PC loads from here.

    expect(await phone.link.moveTo('pc', from: null), isTrue);
    expect(pcAudible, isNotNull, reason: 'the move finishes once the PC is playing');
    expect(phoneStopped, isNotNull, reason: 'and the phone has paused');
    expect(phoneStopped!.isBefore(pcAudible!), isFalse, reason: 'never a gap: the phone stopped after the PC started');
  });

  test('if the other device never starts, the music stays here', () async {
    final phone = await device('phone', 'phone', songs: _album(3), startTimeout: const Duration(seconds: 1));
    // Online on Connect, but no player answers its commands.
    final dead = ConnectClient(
      base: Uri.parse('http://127.0.0.1:${relay.port}'),
      me: const ConnectDeviceInfo(id: 'dead', name: 'pc', kind: 'pc'),
      loginProof: _proof,
    )..start();
    addTearDown(dead.dispose);
    await waitFor(() => phone.see('dead') != null);

    expect(await phone.link.moveTo('dead', from: null), isFalse);
    expect(phone.handler.player.playing, isTrue, reason: 'still playing on the phone');
  });

  test('a third device moves playback from the PC to the phone', () async {
    final pc = await device('pc', 'pc', songs: _album(3));
    final phone = await device('phone', 'phone');
    final tablet = await device('tablet', 'phone');
    await waitFor(() => tablet.see('pc')?.hasSong == true && tablet.see('phone') != null);
    expect(await tablet.link.moveTo('phone', from: 'pc'), isTrue);
    await waitFor(() => phone.handler.player.playing && phone.handler.currentSong?.id == 't1');
    await waitFor(() => !pc.handler.player.playing);
    expect(tablet.handler.currentSong, isNull, reason: 'not to the device that asked');
  });

  test('a position that jumps is reported straight away', () {
    final at = DateTime(2026, 11, 9, 12);
    bool jumped(Duration now, {bool playing = true, bool wasPlaying = true, int after = 5}) =>
        ConnectLink.positionJumped(
          sentPosition: const Duration(seconds: 10),
          sentAt: at,
          sentPlaying: wasPlaying,
          position: now,
          playing: playing,
          now: at.add(Duration(seconds: after)),
        );
    expect(jumped(const Duration(seconds: 15)), isFalse, reason: 'playing on as expected');
    expect(jumped(const Duration(milliseconds: 16200)), isFalse, reason: 'a little drift');
    expect(jumped(const Duration(seconds: 40)), isTrue, reason: 'a seek forward');
    expect(jumped(const Duration(seconds: 2)), isTrue, reason: 'a seek back');
    expect(jumped(const Duration(seconds: 15), playing: false), isTrue, reason: 'paused');
    expect(
      jumped(const Duration(seconds: 10), wasPlaying: false, after: 0),
      isTrue,
      reason: 'just started playing, still at the same second',
    );
  });

  test('the queue window keeps 50 before and 200 after, moving in steps', () {
    for (final index in [0, 10, 49, 50, 74, 75, 120, 999, 1500]) {
      final (start, end) = ConnectLink.queueWindow(2000, index);
      expect(
        index - start,
        greaterThanOrEqualTo(index < connectQueueBefore ? index : connectQueueBefore),
        reason: '$index',
      );
      expect(end - index - 1, greaterThanOrEqualTo(connectQueueAfter), reason: '$index');
      expect(start % 25, 0);
    }
    expect(ConnectLink.queueWindow(2000, 80), ConnectLink.queueWindow(2000, 99), reason: 'the same window for a while');
    expect(ConnectLink.queueWindow(10, 3), (0, 10));
    expect(ConnectLink.queueWindow(0, null), (0, 0));
  });

  test('a closed app leaves the other\'s list', () async {
    final pc = await device('pc', 'pc', songs: _album(2));
    final phone = await device('phone', 'phone');
    await waitFor(() => phone.see('pc') != null);
    devices.remove(pc);
    await pc.link.dispose();
    await waitFor(() => phone.see('pc') == null, timeout: const Duration(seconds: 5));
  });

  test('nothing secret reaches the relay\'s log', () async {
    await device('pc', 'pc', songs: _album(2));
    final phone = await device('phone', 'phone');
    await waitFor(() => phone.see('pc') != null);
    final out = relay.log.toString();
    expect(out, contains('joined'));
    expect(out, isNot(contains(_password)));
    expect(RegExp(r'[0-9a-f]{32}').hasMatch(out), isFalse, reason: 'no tokens');
  });

  group('which device the controls drive', () {
    late ProviderContainer container;
    late _Device pc;
    late _Device phone;

    Future<void> setUpPair({bool pcPlaying = true}) async {
      pc = await device('pc', 'pc', songs: _album(3));
      if (!pcPlaying) {
        await pc.handler.pause();
        await Future<void>.delayed(const Duration(milliseconds: 500)); // Reported to the relay.
      }
      phone = await device('phone', 'phone');
      container = ProviderContainer(
        overrides: [
          audioHandlerProvider.overrideWithValue(phone.handler),
          connectLinkProvider.overrideWithValue(phone.link),
          clientProvider.overrideWithValue(fakeServer({}).client),
        ],
      );
      addTearDown(container.dispose);
      container.listen(outputTargetProvider, (_, _) {});
    }

    test('an idle phone shows the PC while it plays', () async {
      await setUpPair();
      await waitFor(() => container.read(outputTargetProvider) == 'pc');
      expect(container.read(controlsProvider), isA<RemotePlayer>());
      final item = await container.read(mediaItemProvider.future);
      expect(item?.id, 't1');
    });

    test('not a PC that is only paused', () async {
      await setUpPair(pcPlaying: false);
      await waitFor(() => phone.see('pc')?.hasSong == true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(container.read(outputTargetProvider), isNull);
    });

    test('back to the phone when the PC goes away, or the phone plays', () async {
      await setUpPair();
      await waitFor(() => container.read(outputTargetProvider) == 'pc');
      await phone.handler.playSongs([testSong('mine')]);
      await waitFor(() => container.read(outputTargetProvider) == null);
      expect(container.read(controlsProvider), same(phone.handler));

      await phone.handler.pause();
      container.read(outputTargetProvider.notifier).pick('pc');
      expect(container.read(outputTargetProvider), 'pc');
      devices.remove(pc);
      await pc.link.dispose();
      await waitFor(() => container.read(outputTargetProvider) == null);
    });
  });

  group('rescan for new albums', () {
    test('off when the server has no admin login', () async {
      final phone = await _Device.start(harness, relay, 'phone', 'phone');
      devices.add(phone);
      _scans = 0;
      expect(await phone.client.rescan(), isFalse);
      expect(_scans, 0);
    });

    test('asks Navidrome to scan, once for albums close together', () async {
      final admin = await _Relay.start(
        navidrome.port,
        env: {'NAVIDROME_ADMIN_USER': _user, 'NAVIDROME_ADMIN_PASSWORD': _password},
      );
      addTearDown(admin.process.kill);
      final phone = await _Device.start(harness, admin, 'phone', 'phone');
      devices.add(phone);
      _scans = 0;
      expect(await phone.client.rescan(), isTrue);
      expect(await phone.client.rescan(), isTrue, reason: 'the scan already running counts');
      expect(_scans, 1);
      expect(admin.log.toString(), contains('rescan on'));
      expect(admin.log.toString(), isNot(contains(_password)));
    });
  });
}
