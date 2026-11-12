import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../audio/audio_handler.dart';
import '../audio/playback_source.dart';
import '../audio/player_controls.dart';
import '../data/subsonic/models.dart';
import '../data/subsonic/subsonic_client.dart';
import 'connect_client.dart';
import 'connect_link.dart';

/// Another device's player, seen and driven from here: its state as the same
/// streams the local player gives the screens, and its controls as commands.
///
/// Queue indices are into [queue], which is the window of that device's
/// queue it sends (see [connectQueueBefore]).
class RemotePlayer implements PlayerControls {
  RemotePlayer({required this.client, required this.deviceId, required this.subsonic});

  final ConnectClient client;
  final String deviceId;

  /// For cover URLs, made with this device's own login.
  final SubsonicClient? subsonic;

  ConnectDevice? get device => client.devices.value[deviceId];

  Map<String, Object?> get _state => device?.state ?? const {};
  int get _queueStart => (_state['queueStart'] as num?)?.toInt() ?? 0;

  @override
  Song? get currentSong {
    final s = _state['song'];
    return s is Map<String, Object?> ? Song.fromJson(s) : null;
  }

  /// Emits [read] now and whenever the part of the state named by [key] changes.
  Stream<T> _watch<T>(T Function() read, Object? Function(Map<String, Object?> s) key) {
    late final StreamController<T> c;
    String? last;
    void emit() {
      final k = jsonEncode(key(_state));
      if (k == last) return;
      last = k;
      c.add(read());
    }

    c = StreamController<T>(
      onListen: () {
        client.devices.addListener(emit);
        emit();
      },
      onCancel: () => client.devices.removeListener(emit),
    );
    return c.stream;
  }

  Stream<MediaItem?> get mediaItem => _watch(() {
    final s = currentSong;
    return s == null ? null : songMediaItem(s, client: subsonic);
  }, (s) => s['song']);

  Stream<List<MediaItem>> get queue => _watch(() {
    final queued = {for (final i in (_state['queued'] as List?) ?? const []) (i as num).toInt()};
    final songs = jsonList(_state['queue']).map(Song.fromJson).toList();
    return [
      for (var i = 0; i < songs.length; i++)
        songMediaItem(songs[i], client: subsonic, queued: queued.contains(_queueStart + i)),
    ];
  }, (s) => [s['queueRev'], s['queueStart']]);

  bool get playing => device?.playing ?? false;
  bool get shuffled => _state['shuffle'] == true;
  LoopMode get loopMode => LoopMode.values.where((m) => m.name == _state['repeat']).firstOrNull ?? LoopMode.off;
  double get volume => (_state['volume'] as num?)?.toDouble() ?? 1;
  Duration get duration => Duration(milliseconds: (_state['durationMs'] as num?)?.toInt() ?? 0);
  Duration get position => device?.position(DateTime.now()) ?? Duration.zero;

  Stream<PlaybackState> get playbackState => _watch(
    () => PlaybackState(
      processingState: device?.hasSong == true ? AudioProcessingState.ready : AudioProcessingState.idle,
      playing: playing,
      updatePosition: position,
      queueIndex: ((_state['index'] as num?)?.toInt() ?? 0) - _queueStart,
      shuffleMode: shuffled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
      repeatMode: switch (loopMode) {
        LoopMode.off => AudioServiceRepeatMode.none,
        LoopMode.one => AudioServiceRepeatMode.one,
        LoopMode.all => AudioServiceRepeatMode.all,
      },
    ),
    (s) => [s['playing'], s['index'], s['queueStart'], s['shuffle'], s['repeat'], s['positionMs']],
  );

  Stream<PlaybackSource?> get source => _watch(() => PlaybackSource.fromJson(_state['source']), (s) => s['source']);
  Stream<bool> get playingStream => _watch(() => playing, (s) => s['playing']);
  Stream<LoopMode> get loopModeStream => _watch(() => loopMode, (s) => s['repeat']);
  Stream<double> get volumeStream => _watch(() => volume, (s) => s['volume']);

  /// Ticks for the scrubber, extrapolated between the device's reports.
  Stream<Duration> get positionStream async* {
    yield position;
    yield* Stream.periodic(const Duration(milliseconds: 250), (_) => position);
  }

  // ---- Controls: sent as commands ---------------------------------------------------

  Future<void> _send(String cmd, [Map<String, Object?> args = const {}]) => client.send(deviceId, cmd, args);

  List<Map<String, Object?>> _songs(List<Song> songs) => [for (final s in songs) s.toJson()];

  @override
  Future<void> play() {
    client.assume(deviceId, {'playing': true, 'positionMs': position.inMilliseconds});
    return _send('play');
  }

  @override
  Future<void> pause() {
    client.assume(deviceId, {'playing': false, 'positionMs': position.inMilliseconds});
    return _send('pause');
  }

  @override
  Future<void> seek(Duration position) {
    client.assume(deviceId, {'positionMs': position.inMilliseconds});
    return _send('seek', {'ms': position.inMilliseconds});
  }

  @override
  Future<void> skipToNext() => _send('next');

  @override
  Future<void> skipToPrevious() => _send('previous');

  @override
  Future<void> skipToPreviousTrack() => _send('previousTrack');

  @override
  Future<void> skipToQueueItem(int index) => _send('skipTo', {'index': _queueStart + index});

  @override
  Future<void> removeQueueItemAt(int index) => _send('remove', {'index': _queueStart + index});

  @override
  Future<void> moveQueueItem(int from, int to) =>
      _send('move', {'fromIndex': _queueStart + from, 'toIndex': _queueStart + to});

  @override
  Future<void> playSongs(
    List<Song> songs, {
    int index = 0,
    bool shuffle = false,
    PlaybackSource? source,
    Duration position = Duration.zero,
  }) {
    // A whole library is too much to send; keep a long run around the song.
    var list = songs;
    var at = index;
    if (list.length > connectTransferMax) {
      final start = (index - connectTransferMax ~/ 10).clamp(0, list.length - connectTransferMax);
      list = list.sublist(start, start + connectTransferMax);
      at -= start;
    }
    return _send('playSongs', {'songs': _songs(list), 'index': at, 'shuffle': shuffle, 'source': source?.toJson()});
  }

  @override
  Future<void> playNext(List<Song> songs) => _send('playNext', {'songs': _songs(songs)});

  @override
  Future<void> addToQueue(List<Song> songs) => _send('addToQueue', {'songs': _songs(songs)});

  @override
  Future<void> toggleShuffle() => _send('shuffle');

  @override
  Future<void> cycleRepeat() => _send('repeat');

  Timer? _volumeSend;

  @override
  void setUserVolume(double v) {
    final value = v.clamp(0.0, 1.0);
    client.assume(deviceId, {'volume': value});
    // A dragged slider sends a stream of values; pass on a few a second.
    _volumeSend ??= Timer(const Duration(milliseconds: 120), () {
      _volumeSend = null;
      unawaited(_send('volume', {'volume': volume}));
    });
  }

  void dispose() => _volumeSend?.cancel();
}
