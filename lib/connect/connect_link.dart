import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../audio/audio_handler.dart';
import '../audio/playback_source.dart';
import '../data/subsonic/models.dart';
import 'connect_client.dart';

/// Songs either side of the current one that other devices are shown.
const connectQueueBefore = 50;
const connectQueueAfter = 200;

/// A whole queue moved to another device is cut to this many songs.
const connectTransferMax = 1000;

/// Ties this device's player to Sonar Connect: tells the account's other
/// devices what it's playing, does what they ask, and moves playback between
/// devices.
class ConnectLink {
  ConnectLink({required this.handler, required this.client, this.startTimeout = const Duration(seconds: 15)});

  final SonarAudioHandler handler;
  final ConnectClient client;

  /// How long a device taking over may take to start playing before this one
  /// gives up and carries on playing itself.
  final Duration startTimeout;

  final _tookOver = StreamController<void>.broadcast();

  /// Playback moved here from another device.
  Stream<void> get tookOver => _tookOver.stream;

  final _subs = <StreamSubscription<Object?>>[];
  Timer? _heartbeat;
  Timer? _soon;
  var _soonPosition = false;

  /// What was last sent, per key (JSON), so only changes go out.
  Map<String, String> _sent = {};
  int _queueRev = 0;
  int _sentQueueRev = -1;

  /// The position last sent and when, to notice jumps (seeks, stalls).
  Duration _sentPosition = Duration.zero;
  DateTime _sentAt = DateTime(2000);
  bool _sentPlaying = false;

  void start() {
    client.onOnline = () {
      _sent = {};
      _sentQueueRev = -1;
      _publish(position: true);
    };
    _subs
      ..add(
        handler.queue.listen((_) {
          _queueRev++;
          _publishSoon();
        }),
      )
      ..add(handler.mediaItem.listen((_) => _publishSoon(position: true)))
      ..add(handler.playbackState.listen((_) => _publishSoon(position: _positionJumped())))
      ..add(client.commands.listen((c) => unawaited(_onCommand(c))));
    handler.userVolume.addListener(_publishSoon);
    // Keeps the position honest on the other devices, and this one listed.
    _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) => _publish(position: true));
    client.start();
  }

  Future<void> dispose() async {
    _heartbeat?.cancel();
    _soon?.cancel();
    handler.userVolume.removeListener(_publishSoon);
    for (final s in _subs) {
      await s.cancel();
    }
    await client.dispose();
    await _tookOver.close();
  }

  bool _positionJumped() => positionJumped(
    sentPosition: _sentPosition,
    sentAt: _sentAt,
    sentPlaying: _sentPlaying,
    position: handler.position,
    playing: handler.player.playing,
    now: DateTime.now(),
  );

  /// Whether the other devices' picture of the position (what was sent,
  /// played on since) is now wrong: a seek, a stall, a pause.
  @visibleForTesting
  static bool positionJumped({
    required Duration sentPosition,
    required DateTime sentAt,
    required bool sentPlaying,
    required Duration position,
    required bool playing,
    required DateTime now,
  }) {
    if (playing != sentPlaying) return true;
    final expected = sentPosition + (playing ? now.difference(sentAt) : Duration.zero);
    return (position - expected).abs() > const Duration(milliseconds: 1500);
  }

  void _publishSoon({bool position = false}) {
    _soonPosition |= position;
    _soon ??= Timer(const Duration(milliseconds: 150), () {
      _soon = null;
      final p = _soonPosition;
      _soonPosition = false;
      _publish(position: p);
    });
  }

  /// The part of the queue other devices are sent, `[start, end)`: at least
  /// [connectQueueBefore] songs before the current one and [connectQueueAfter]
  /// after. It moves in steps of [_windowStep], so it's resent every so many
  /// songs rather than on every track change.
  static (int, int) queueWindow(int length, int? index) {
    if (index == null || length == 0) return (0, 0);
    final from = index - connectQueueBefore;
    final start = from <= 0 ? 0 : (from ~/ _windowStep) * _windowStep;
    final end = (start + connectQueueBefore + connectQueueAfter + _windowStep + 1).clamp(0, length);
    return (start, end);
  }

  static const _windowStep = 25;

  /// This device's player, as other devices see it.
  Map<String, Object?> state() {
    final songs = handler.songs;
    final index = handler.currentIndex;
    final song = handler.currentSong;
    final (start, end) = queueWindow(songs.length, index);
    final queued = handler.queuedFlags;
    return {
      'song': song?.toJson(),
      'index': index,
      'durationMs': song?.duration.inMilliseconds,
      'playing': handler.player.playing,
      // "Playing" is set the moment play is pressed; this is whether sound is
      // actually coming out (the stream is open, not loading or buffering).
      'ready': handler.player.processingState == ProcessingState.ready,
      'shuffle': handler.shuffled,
      'repeat': handler.player.loopMode.name,
      'volume': handler.userVolume.value,
      'source': handler.source?.toJson(),
      'queueRev': _queueRev,
      'queueStart': start,
      'queue': [for (var i = start; i < end; i++) songs[i].toJson()],
      'queued': [
        for (var i = start; i < end; i++)
          if (i < queued.length && queued[i]) i,
      ],
    };
  }

  static const _queueKeys = {'queue', 'queueStart', 'queued'};

  void _publish({bool position = false}) {
    if (client.status.value != ConnectStatus.online) return;
    final full = state();
    final patch = <String, Object?>{};
    final queueChanged = _sentQueueRev != _queueRev || _sent['queueStart'] != '${full['queueStart']}';
    _sent['queueStart'] = '${full['queueStart']}';
    for (final e in full.entries) {
      if (_queueKeys.contains(e.key)) {
        if (queueChanged) patch[e.key] = e.value;
        continue;
      }
      final json = jsonEncode(e.value);
      if (_sent[e.key] != json) {
        patch[e.key] = e.value;
        _sent[e.key] = json;
      }
    }
    _sentQueueRev = _queueRev;
    if (position || patch.containsKey('playing') || patch.containsKey('ready') || patch.containsKey('index')) {
      _sentPosition = handler.position;
      _sentAt = DateTime.now();
      _sentPlaying = handler.player.playing;
      patch['positionMs'] = _sentPosition.inMilliseconds;
      patch['playing'] = _sentPlaying;
    }
    if (patch.isNotEmpty) client.publish(patch);
  }

  // ---- Doing what other devices ask -------------------------------------------------

  Future<void> _onCommand(ConnectCommand c) async {
    final a = c.args;
    int arg(String k) => (a[k] as num?)?.toInt() ?? 0;
    List<Song> songs() => jsonList(a['songs']).map(Song.fromJson).toList();
    try {
      switch (c.cmd) {
        case 'play':
          await handler.play();
        case 'pause':
          await handler.pause();
        case 'next':
          await handler.skipToNext();
        case 'previous':
          await handler.skipToPrevious();
        case 'previousTrack':
          await handler.skipToPreviousTrack();
        case 'seek':
          await handler.seek(Duration(milliseconds: arg('ms')));
        case 'skipTo':
          await handler.skipToQueueItem(arg('index'));
        case 'remove':
          await handler.removeQueueItemAt(arg('index'));
        case 'move':
          await handler.moveQueueItem(arg('fromIndex'), arg('toIndex'));
        case 'playNext':
          await handler.playNext(songs());
        case 'addToQueue':
          await handler.addToQueue(songs());
        case 'playSongs':
          await handler.playSongs(
            songs(),
            index: arg('index'),
            shuffle: a['shuffle'] == true,
            source: PlaybackSource.fromJson(a['source']),
          );
        case 'shuffle':
          await handler.toggleShuffle();
        case 'repeat':
          await handler.cycleRepeat();
        case 'volume':
          handler.setUserVolume((a['volume'] as num?)?.toDouble() ?? handler.userVolume.value);
        case 'takeOver':
          final snapshot = a['snapshot'];
          if (snapshot is Map) {
            await handler.loadQueueSnapshot(snapshot, play: a['play'] != false);
            _tookOver.add(null);
          }
        case 'handOver':
          final target = a['target'];
          if (target is String) await _sendQueueTo(target);
      }
    } catch (e) {
      debugPrint('Connect command ${c.cmd} failed: ${e.runtimeType}');
    }
    _publishSoon(position: true);
  }

  /// Hands this device's queue to [to], which starts playing it, and pauses
  /// here. With nothing queued here there's nothing to move.
  ///
  /// While music is playing here it carries on until [to] is actually
  /// playing (a PC takes a moment to open the stream and find the second),
  /// so the move never leaves a silence. If [to] never starts, this device
  /// keeps playing and the move counts as failed.
  Future<bool> _sendQueueTo(String to) async {
    final snapshot = handler.queueSnapshot(maxSongs: connectTransferMax);
    if (snapshot == null) return true;
    final songs = jsonList(snapshot['songs']);
    final index = (snapshot['index'] as num?)?.toInt() ?? 0;
    final songId = index < songs.length ? songs[index]['id'] : null;
    final since = DateTime.now();
    final started = handler.player.playing ? _untilPlaying(to, songId, since) : null;
    final ok = await client.send(to, 'takeOver', {'snapshot': snapshot, 'play': true});
    if (!ok) {
      started?.ignore();
      return false;
    }
    if (started != null && !await started) return false;
    await handler.pause();
    return true;
  }

  /// Completes true once [id] reports playing [songId] (after [since]), or
  /// false after [startTimeout].
  Future<bool> _untilPlaying(String id, Object? songId, DateTime since) {
    final done = Completer<bool>();
    void check() {
      final d = client.devices.value[id];
      final song = d?.state['song'];
      if (d != null && d.audible && song is Map && song['id'] == songId && !d.positionAt.isBefore(since)) {
        if (!done.isCompleted) done.complete(true);
      }
    }

    final timeout = Timer(startTimeout, () {
      if (!done.isCompleted) done.complete(false);
    });
    client.devices.addListener(check);
    return done.future.whenComplete(() {
      client.devices.removeListener(check);
      timeout.cancel();
    });
  }

  /// Moves playback from [from] (null: this device) to [to] (null: this
  /// device). False if the device asked didn't answer.
  Future<bool> moveTo(String? to, {required String? from}) async {
    if (to == from) return true;
    if (from == null) return _sendQueueTo(to!);
    // The playing device sends its queue on, to us or a third device.
    return client.send(from, 'handOver', {'target': to ?? client.me.id});
  }
}
