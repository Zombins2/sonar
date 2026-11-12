import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../data/db/database.dart';
import '../data/discovery.dart';
import '../data/handoff.dart';
import '../data/subsonic/models.dart';
import '../data/subsonic/subsonic_client.dart';
import '../downloads/download_manager.dart';
import 'car_browser.dart';
import 'playback_source.dart';
import 'player_controls.dart';
import 'transitions.dart';

/// Where "Add to queue" inserts: after the current track and after anything
/// already queued by hand right behind it, so queued songs play in the order
/// they were added and before the rest of the album or playlist.
int queueInsertIndex(List<bool> queued, int current) {
  var i = current + 1;
  while (i < queued.length && queued[i]) {
    i++;
  }
  return i;
}

/// A song as the system media controls and the screens see it. Also used for
/// another device's songs (Sonar Connect).
MediaItem songMediaItem(Song s, {required SubsonicClient? client, int streamKbps = 0, bool queued = false}) =>
    MediaItem(
      id: s.id,
      title: s.title,
      artist: s.artist,
      album: s.album,
      duration: s.duration > Duration.zero ? s.duration : null,
      artUri: s.coverArt == null ? null : client?.coverArtUrl(s.coverArt!, size: 512),
      extras: {
        'coverArt': s.coverArt,
        'albumId': s.albumId,
        'artistId': s.artistId,
        'suffix': s.suffix,
        'bitRate': s.bitRate,
        'streamKbps': streamKbps,
        if (queued) 'queued': true,
      },
    );

class SleepTimer {
  const SleepTimer({this.endsAt, this.endOfTrack = false});
  final DateTime? endsAt;
  final bool endOfTrack;
}

/// Owns the just_audio player and exposes it to the system (notification,
/// lock screen, Bluetooth / headset buttons) through audio_service.
///
/// Shuffle physically reorders the queue around the current track instead of
/// using just_audio's shuffle indices, so queue order always equals play order
/// and the queue screen can reorder/remove by plain index.
class SonarAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler implements PlayerControls {
  SonarAudioHandler(this._db);

  static const _kQueue = 'queue_state';

  final AppDatabase _db;
  final AudioPlayer _player = AudioPlayer();
  final _errors = StreamController<String>.broadcast();

  SubsonicClient? _client;

  /// Returns the `maxBitRate` to stream at for the current network (0 = original).
  Future<int> Function() bitrateResolver = () async => 0;

  /// Path of a downloaded copy of a song, if there is one.
  String? Function(String songId) localPath = (_) => null;

  /// Whether the server answered recently. Offline, only downloads can play.
  bool Function() isReachable = () => true;

  /// Carry on with similar songs when the queue runs out.
  bool autoplay = true;

  /// The last track autoplay already topped the queue up from.
  String? _autoplayFrom;

  /// Seconds the end of a track overlaps the start of the next (0 = off).
  int crossfade = 0;

  /// Evens out loudness with the tracks' ReplayGain tags.
  bool get levelVolume => _levelVolume;
  bool _levelVolume = true;
  set levelVolume(bool on) {
    _levelVolume = on;
    _updateGain();
  }

  // The player's volume is these four multiplied: the track's ReplayGain,
  // the crossfade ramp, the sleep timer's fade-out and the volume slider.
  double _gain = 1;
  double _fadeIn = 1;
  double _sleepLevel = 1;
  double _volume = 1;

  static const _kVolume = 'user_volume';

  /// The volume slider (desktop), 0–1. Phones use their own volume keys.
  final userVolume = ValueNotifier<double>(1);

  @override
  void setUserVolume(double v) {
    userVolume.value = v.clamp(0.0, 1.0);
    _applyVolume();
    _volumeSave?.cancel();
    _volumeSave = Timer(const Duration(milliseconds: 400), () => _db.setJson(_kVolume, userVolume.value));
  }

  Timer? _volumeSave;

  /// Loudness follows the square of the slider, so its travel feels even.
  double get _userLevel => userVolume.value * userVolume.value;

  /// The fades every player shares: sleep timer and volume slider.
  double get _shared => _sleepLevel * _userLevel;

  void _applyVolume() {
    final v = _gain * _fadeIn * _shared;
    if (v == _volume) return;
    _volume = v;
    unawaited(_player.setVolume(v));
  }

  void _updateGain() {
    final s = currentSong;
    _gain = _levelVolume && s != null
        ? levelledVolume(s.replayGain, album: preferAlbumGain(_source, shuffled: shuffled))
        : 1;
    _applyVolume();
  }

  List<Song> _songs = [];

  /// Parallel to [_songs]: true for tracks queued by hand ("Add to queue",
  /// "Play next"). Like Spotify, they play right after the current track,
  /// ahead of the rest of the album or playlist.
  List<bool> _queued = [];
  List<Song>? _unshuffled;
  PlaybackSource? _source;
  bool _restored = false;
  Timer? _persistTimer;

  // Scrobble bookkeeping.
  String? _nowPlayingSent;
  String? _submissionSent;
  Duration _lastPosition = Duration.zero;

  AudioPlayer get player => _player;
  Stream<String> get errors => _errors.stream;
  List<Song> get songs => List.unmodifiable(_songs);

  /// Which songs were queued by hand, parallel to [songs].
  List<bool> get queuedFlags => List.unmodifiable(_queued);

  /// The current song's place in [songs].
  int? get currentIndex => _index;

  /// Where the current song is up to (right for a restored queue too).
  Duration get position => _restoredIndex != null ? _restoredPosition : _player.position;
  bool get shuffled => _unshuffled != null;
  PlaybackSource? get source => _source;

  /// Published through audio_service's spare `customState` stream.
  void _setSource(PlaybackSource? s) {
    _source = s;
    customState.add(s);
  }

  @override
  Song? get currentSong {
    final i = _index;
    return i == null || i >= _songs.length ? null : _songs[i];
  }

  /// A queue restored at start-up isn't loaded until play is pressed, and
  /// until then the player reports the first song as current. This keeps the
  /// saved one (cleared once the player has loaded).
  int? _restoredIndex;
  Duration _restoredPosition = Duration.zero;

  int? get _index => _restoredIndex ?? _player.currentIndex;

  /// Loads a restored queue before it's changed, so the player's own index
  /// is right again for the change.
  Future<void> _settleRestored() async {
    if (_restoredIndex == null) return;
    try {
      await _player.load();
    } catch (_) {
      // Offline: the change still applies to the queue as listed.
    }
    _restoredIndex = null;
  }

  Future<void> init() async {
    final saved = await _db.getJson(_kVolume);
    if (saved is num) {
      userVolume.value = saved.toDouble().clamp(0.0, 1.0);
      _applyVolume();
    }
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    // Pause when headphones are unplugged / Bluetooth disconnects.
    session.becomingNoisyEventStream.listen((_) => pause());

    _player.playbackEventStream.listen(
      _broadcastState,
      onError: (Object e, StackTrace _) {
        _errors.add('Playback failed. Check your connection to the server.');
      },
    );
    _player.playingStream.listen((playing) {
      // Also covers pauses the handler doesn't see (a phone call taking focus).
      // Windows briefly reports "not playing" (as loading, or even paused)
      // while the next song opens, so only a pause that lasts counts.
      _pauseCheck?.cancel();
      if (!playing && (_fading || _tailFor != null)) {
        _pauseCheck = Timer(_pauseGrace, () {
          if (!_player.playing) _stopCrossfade();
        });
      }
      _broadcastState(_player.playbackEvent);
      _checkStall();
    });
    _player.processingStateStream.listen((state) {
      // Loaded: the player's own index is the truth again.
      if (state != ProcessingState.idle) _restoredIndex = null;
      _checkStall();
    });
    _player.loopModeStream.listen((_) => _broadcastState(_player.playbackEvent));
    _player.currentIndexStream.listen(_onIndexChanged);
    _player.positionStream.listen(_onPosition);
    _player.durationStream.listen((d) {
      final item = mediaItem.value;
      if (item != null && d != null && item.duration != d) mediaItem.add(item.copyWith(duration: d));
    });

    // "End of track" sleep: stop as soon as playback rolls into the next track
    // on its own (a manual skip doesn't count).
    _player.positionDiscontinuityStream.listen((d) {
      if (d.reason == PositionDiscontinuityReason.autoAdvance && sleep.value?.endOfTrack == true) {
        _fireSleep(rewind: true);
      }
    });

    _persistTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_player.playing) return;
      _persist();
      if (DateTime.now().difference(_queueSavedAt) > _queueSyncEvery) unawaited(_saveQueueToServer());
    });
  }

  // ---- Carrying on elsewhere ------------------------------------------------------

  static const _queueSyncEvery = Duration(seconds: 30);
  DateTime _queueSavedAt = DateTime(2000);
  Timer? _queueSyncSoon;

  /// Set once something has played here. A queue that was only restored at
  /// startup isn't saved, so it can't hide one left on another device.
  bool _playedHere = false;

  /// Saves the queue on the server (Subsonic savePlayQueue), so the other
  /// device can offer to carry on from this exact spot.
  Future<void> _saveQueueToServer() async {
    final client = _client;
    final song = currentSong;
    final i = _player.currentIndex;
    if (client == null || song == null || i == null || !_playedHere || !isReachable()) return;
    _queueSavedAt = DateTime.now();
    try {
      await client.savePlayQueue(
        [for (final s in queueToSave(_songs, i)) s.id],
        current: song.id,
        position: _player.position,
      );
    } catch (_) {
      // Only a convenience; the next save tries again.
    }
  }

  void _saveQueueSoon() {
    _queueSyncSoon?.cancel();
    _queueSyncSoon = Timer(const Duration(seconds: 2), _saveQueueToServer);
  }

  /// Called whenever the logged-in server changes. Restores the saved queue the
  /// first time a client becomes available.
  Future<void> setClient(SubsonicClient? client) async {
    _client = client;
    if (client == null) {
      // Null before the first login is just the session still loading; after
      // a client has existed it means logout, so drop the queue.
      if (_restored) {
        _restored = false;
        await stop();
        await _clearQueue();
      }
      return;
    }
    if (!_restored) {
      _restored = true;
      await _restore();
    }
  }

  // ---- Queue building -----------------------------------------------------

  MediaItem _mediaItem(Song s, {bool queued = false}) =>
      songMediaItem(s, client: _client, streamKbps: _streamKbps[s.id] ?? 0, queued: queued);

  /// Bitrate cap each queued track was asked for (0 = original file or download).
  final _streamKbps = <String, int>{};

  List<MediaItem> _queueItems() => [
    for (var i = 0; i < _songs.length; i++) _mediaItem(_songs[i], queued: i < _queued.length && _queued[i]),
  ];

  Future<List<AudioSource>> _sources(List<Song> songs) async {
    final client = _client;
    if (client == null) throw StateError('Not logged in');
    final bitrate = await bitrateResolver();
    for (final s in songs) {
      _streamKbps[s.id] = localPath(s.id) == null ? bitrate : 0;
    }
    return [
      for (final s in songs)
        switch (localPath(s.id)) {
          final String path => AudioSource.file(path, tag: _mediaItem(s)),
          null => AudioSource.uri(client.streamUrl(s.id, maxBitRate: bitrate), tag: _mediaItem(s)),
        },
    ];
  }

  void _publishQueue() {
    queue.add(_queueItems());
    _publishMediaItem();
    _schedulePersist();
  }

  void _publishMediaItem() {
    final s = currentSong;
    mediaItem.add(s == null ? null : _mediaItem(s));
    _updateGain();
  }

  /// Replaces the queue and starts playing. [source] is the album, playlist or
  /// artist page it came from (null for search results and loose song lists).
  @override
  Future<void> playSongs(
    List<Song> songs, {
    int index = 0,
    bool shuffle = false,
    PlaybackSource? source,
    Duration position = Duration.zero,
  }) async {
    if (songs.isEmpty) return;
    var list = List<Song>.of(songs);
    var start = index.clamp(0, list.length - 1);
    if (!isReachable()) {
      // Offline: drop tracks that would only stall, keeping the tapped one if we can.
      final tapped = list[start];
      list = list.where((s) => localPath(s.id) != null).toList();
      if (list.isEmpty) {
        _errors.add('Server unreachable and none of these songs are downloaded.');
        return;
      }
      start = list.indexOf(tapped).clamp(0, list.length - 1);
    }
    _stopCrossfade();
    _setSource(source);
    _autoplayFrom = null;
    _unshuffled = null;
    if (shuffle) {
      _unshuffled = List.of(list);
      list.shuffle(Random());
      start = 0;
    }
    _songs = list;
    _queued = List.filled(list.length, false, growable: true);
    _restoredIndex = null;
    try {
      await _player.setAudioSources(
        await _sources(list),
        initialIndex: start,
        initialPosition: position > Duration.zero ? position : null,
        preload: false,
      );
    } on PlayerInterruptedException {
      return;
    }
    _publishQueue();
    _playedHere = true;
    unawaited(_player.play());
  }

  /// Puts [songs] straight after the current track, ahead of anything queued.
  @override
  Future<void> playNext(List<Song> songs) async {
    if (_songs.isEmpty) return playSongs(songs);
    await _settleRestored();
    await _insertQueued((_player.currentIndex ?? -1) + 1, songs);
  }

  /// Queues [songs] after the current track and anything already queued, but
  /// before the rest of the album or playlist that's playing.
  @override
  Future<void> addToQueue(List<Song> songs) async {
    if (_songs.isEmpty) return playSongs(songs);
    await _settleRestored();
    await _insertQueued(queueInsertIndex(_queued, _player.currentIndex ?? 0), songs);
  }

  Future<void> _insertQueued(int at, List<Song> songs) async {
    await _player.insertAudioSources(at, await _sources(songs));
    _songs.insertAll(at, songs);
    _queued.insertAll(at, List.filled(songs.length, true));
    _publishQueue();
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    if (index < 0 || index >= _songs.length) return;
    await _settleRestored();
    await _player.removeAudioSourceAt(index);
    final removed = _songs.removeAt(index);
    _queued.removeAt(index);
    _unshuffled?.remove(removed);
    _publishQueue();
  }

  @override
  Future<void> moveQueueItem(int from, int to) async {
    if (from == to) return;
    await _settleRestored();
    await _player.moveAudioSource(from, to);
    _songs.insert(to, _songs.removeAt(from));
    _queued.insert(to, _queued.removeAt(from));
    _publishQueue();
  }

  @override
  Future<void> toggleShuffle() async {
    await _settleRestored();
    final cur = _player.currentIndex;
    if (cur == null || _songs.isEmpty) return;
    final current = _songs[cur];
    // Songs queued by hand stay up next, in order, whichever way this goes.
    // Queued songs that already played drop out.
    final queuedNext = [
      for (var i = cur + 1; i < _songs.length; i++)
        if (_queued[i]) _songs[i],
    ];
    final List<Song> before, after;
    if (_unshuffled == null) {
      _unshuffled = [
        for (var i = 0; i < _songs.length; i++)
          if (i == cur || !_queued[i]) _songs[i],
      ];
      before = const [];
      after = [
        for (var i = 0; i < _songs.length; i++)
          if (i != cur && !_queued[i]) _songs[i],
      ]..shuffle(Random());
    } else {
      final original = _unshuffled!;
      _unshuffled = null;
      final at = original.indexWhere((s) => identical(s, current) || s.id == current.id);
      before = at < 0 ? const [] : original.sublist(0, at);
      after = at < 0 ? original : original.sublist(at + 1);
    }
    // Rebuild around the playing track so it carries on uninterrupted.
    final next = [...queuedNext, ...after];
    await _player.removeAudioSourceRange(cur + 1, _songs.length);
    await _player.removeAudioSourceRange(0, cur);
    if (before.isNotEmpty) await _player.insertAudioSources(0, await _sources(before));
    if (next.isNotEmpty) await _player.addAudioSources(await _sources(next));
    _songs = [...before, current, ...next];
    _queued = [for (final _ in before) false, false, for (final _ in queuedNext) true, for (final _ in after) false];
    _publishQueue();
    _broadcastState(_player.playbackEvent);
  }

  @override
  Future<void> cycleRepeat() async {
    final next = switch (_player.loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    await _player.setLoopMode(next);
    _schedulePersist();
  }

  Future<void> _clearQueue() async {
    _stopCrossfade();
    _restoredIndex = null;
    _songs = [];
    _queued = [];
    _unshuffled = null;
    _setSource(null);
    await _player.clearAudioSources();
    queue.add(const []);
    mediaItem.add(null);
    await _db.removeValue(_kQueue);
  }

  // ---- Android Auto -----------------------------------------------------------------

  /// Set at startup so the car menu can list downloads.
  DownloadManager? downloads;

  CarBrowser? get _car => _client == null ? null : CarBrowser(_client!, downloads);

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    try {
      return await _car?.children(parentMediaId) ?? const [];
    } on SubsonicException {
      return const [];
    }
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    final target = await _car?.resolve(mediaId);
    if (target == null) return;
    await playSongs(target.songs, index: target.index, source: target.source);
  }

  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) async {
    final car = _car;
    if (car == null) return;
    // An empty query means "just play something".
    final songs = query.trim().isEmpty ? <Song>[] : await car.searchSongs(query);
    if (songs.isNotEmpty) {
      await playSongs(songs);
    } else if (_songs.isNotEmpty) {
      await play();
    }
  }

  // ---- Transport ------------------------------------------------------------

  @override
  Future<void> play() {
    _playedHere = true;
    return _player.play();
  }

  @override
  Future<void> pause() async {
    _stopCrossfade();
    await _player.pause();
    await _persist();
    unawaited(_saveQueueToServer());
  }

  @override
  Future<void> seek(Duration position) async {
    _stopCrossfade();
    await _settleRestored();
    return _player.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    _stopCrossfade();
    await _settleRestored();
    return _player.seekToNext();
  }

  @override
  Future<void> skipToPrevious() async {
    _stopCrossfade();
    await _settleRestored();
    if (_player.position > const Duration(seconds: 3) || !_player.hasPrevious) {
      await _player.seek(Duration.zero);
    } else {
      await _player.seekToPrevious();
    }
  }

  /// Mini player swipe: always the previous track (no restart-first rule),
  /// or the start of this one when there's nothing before it.
  @override
  Future<void> skipToPreviousTrack() async {
    _stopCrossfade();
    await _settleRestored();
    return _player.hasPrevious ? _player.seekToPrevious() : _player.seek(Duration.zero);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _songs.length) return;
    _stopCrossfade();
    await _settleRestored();
    await _player.seek(Duration.zero, index: index);
    if (!_player.playing) unawaited(_player.play());
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) => _player.setLoopMode(switch (repeatMode) {
    AudioServiceRepeatMode.none => LoopMode.off,
    AudioServiceRepeatMode.one => LoopMode.one,
    _ => LoopMode.all,
  });

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final want = shuffleMode != AudioServiceShuffleMode.none;
    if (want != shuffled) await toggleShuffle();
  }

  @override
  Future<void> stop() async {
    _stopCrossfade();
    await _persist();
    await _saveQueueToServer();
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    await _persist();
    await _saveQueueToServer();
  }

  // ---- Sleep timer ---------------------------------------------------------------

  static const _sleepFade = Duration(seconds: 10);
  final sleep = ValueNotifier<SleepTimer?>(null);
  Timer? _sleepTicker;

  /// Pause after [after], fading out over the last few seconds. Null cancels.
  void setSleepTimer(Duration? after) {
    _cancelSleep();
    if (after == null) return;
    sleep.value = SleepTimer(endsAt: DateTime.now().add(after));
    _sleepTicker = Timer.periodic(const Duration(milliseconds: 250), (_) => _tickSleep());
  }

  void sleepAtEndOfTrack() {
    _cancelSleep();
    sleep.value = const SleepTimer(endOfTrack: true);
  }

  void _tickSleep() {
    final endsAt = sleep.value?.endsAt;
    if (endsAt == null) return;
    final left = endsAt.difference(DateTime.now());
    if (left <= Duration.zero) {
      _fireSleep();
    } else if (left < _sleepFade) {
      _sleepLevel = left.inMilliseconds / _sleepFade.inMilliseconds;
      _applyVolume();
    }
  }

  Future<void> _fireSleep({bool rewind = false}) async {
    _sleepTicker?.cancel();
    await pause();
    _cancelSleep(); // Restores volume only once we're silent.
    // The next track has already started by the time auto-advance is reported.
    if (rewind) await _player.seek(Duration.zero);
  }

  void _cancelSleep() {
    _sleepTicker?.cancel();
    _sleepTicker = null;
    sleep.value = null;
    _sleepLevel = 1;
    _applyVolume();
  }

  // ---- State -------------------------------------------------------------------

  /// A stream that never delivers data (e.g. the server's transcoder failing
  /// mid-response) leaves the player buffering forever with no error. Give up
  /// after a while and say so instead of spinning silently.
  static const _stallTimeout = Duration(seconds: 20);
  Timer? _stallTimer;

  void _checkStall() {
    final waiting =
        _player.playing &&
        (_player.processingState == ProcessingState.loading || _player.processingState == ProcessingState.buffering);
    if (!waiting) {
      _stallTimer?.cancel();
      _stallTimer = null;
      return;
    }
    _stallTimer ??= Timer(_stallTimeout, () async {
      _stallTimer = null;
      await _player.pause();
      final capped = await bitrateResolver() > 0;
      _errors.add(
        capped
            ? 'This track won\'t load. The server may be failing to transcode. '
                  'Try Original quality in Settings.'
            : 'This track won\'t load. Check your connection to the server.',
      );
    });
  }

  void _broadcastState(PlaybackEvent event) {
    final playing = _player.playing;
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.skipToQueueItem,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: const {
          ProcessingState.idle: AudioProcessingState.idle,
          ProcessingState.loading: AudioProcessingState.loading,
          ProcessingState.buffering: AudioProcessingState.buffering,
          ProcessingState.ready: AudioProcessingState.ready,
          ProcessingState.completed: AudioProcessingState.completed,
        }[_player.processingState]!,
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: event.currentIndex,
        repeatMode: switch (_player.loopMode) {
          LoopMode.off => AudioServiceRepeatMode.none,
          LoopMode.one => AudioServiceRepeatMode.one,
          LoopMode.all => AudioServiceRepeatMode.all,
        },
        shuffleMode: shuffled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
      ),
    );
  }

  void _onIndexChanged(int? index) {
    _publishMediaItem();
    _schedulePersist();
    _submissionSent = null;
    final song = currentSong;
    if (song != null && _nowPlayingSent != song.id && _player.playing) _sendNowPlaying(song);
    if (_player.playing) _saveQueueSoon();
  }

  void _sendNowPlaying(Song song) {
    _nowPlayingSent = song.id;
    _client?.scrobble(song.id, submission: false).catchError((_) {});
  }

  /// `submission=false` when a track starts, `true` once it has played for half
  /// its length or 4 minutes, whichever is first.
  void _onPosition(Duration position) {
    final song = currentSong;
    if (song == null) return;
    // Repeat-one loops restart the same index: treat a jump back to zero as a new play.
    if (position < const Duration(seconds: 2) && _lastPosition > const Duration(seconds: 10)) {
      _submissionSent = null;
      _nowPlayingSent = null;
    }
    _lastPosition = position;
    if (!_player.playing) return;
    _maybeAutoplay();
    _maybeCrossfade(position);
    if (_nowPlayingSent != song.id) _sendNowPlaying(song);
    if (_submissionSent == song.id) return;
    final duration = _player.duration ?? song.duration;
    if (duration <= Duration.zero) return;
    final threshold = Duration(milliseconds: min(duration.inMilliseconds ~/ 2, 4 * 60 * 1000));
    if (position >= threshold) {
      _submissionSent = song.id;
      _client?.scrobble(song.id, submission: true).catchError((_) {});
    }
  }

  // ---- Autoplay ---------------------------------------------------------------

  /// Once the last track is playing, append songs like it so music doesn't
  /// stop. Checked from the position stream, so it also covers a restored
  /// queue that resumes on its last track.
  void _maybeAutoplay() {
    final i = _player.currentIndex;
    if (i == null ||
        !shouldAutoplay(
          enabled: autoplay,
          repeating: _player.loopMode != LoopMode.off,
          index: i,
          length: _songs.length,
        )) {
      return;
    }
    final seed = _songs[i];
    if (_autoplayFrom == seed.id || !isReachable()) return;
    _autoplayFrom = seed.id;
    unawaited(_appendSimilar(seed));
  }

  Future<void> _appendSimilar(Song seed) async {
    final client = _client;
    if (client == null) return;
    try {
      var similar = await client.getSimilarSongs2(seed.id, count: 40);
      if (similar.isEmpty && seed.artistId != null) similar = await client.getSimilarSongs2(seed.artistId!, count: 40);
      final picks = autoplayPicks(similar, _songs);
      // The queue may have been replaced while the server answered.
      if (picks.isEmpty || _songs.isEmpty || _songs.last.id != seed.id) return;
      await _player.addAudioSources(await _sources(picks));
      _songs.addAll(picks);
      _queued.addAll(List.filled(picks.length, false));
      _unshuffled?.addAll(picks);
      _publishQueue();
    } catch (_) {
      // Autoplay is a nicety: the queue just ends as it would have.
    }
  }

  // ---- Crossfade --------------------------------------------------------------

  /// Plays the end of the outgoing track while [_player] moves on to the next
  /// one, so the queue, notification and scrobbles never leave [_player].
  AudioPlayer? _tail;

  /// `index:id` of the track the tail is loaded for, and whether it's ready.
  String? _tailFor;
  bool _tailReady = false;

  /// Where the tail's own position 0 sits in the track: a transcoded stream
  /// is started part-way in by the server instead of seeking.
  Duration _tailBase = Duration.zero;
  Timer? _crossfadeTimer;
  bool _fading = false;

  /// The tail starts this far ahead of the fade, silently, so it's really
  /// playing (and lined up) by the time it's heard.
  static const _preroll = Duration(seconds: 2);

  /// Both players carry the outgoing track for this long while it changes hands.
  static const _handoff = Duration(milliseconds: 120);

  /// How long the player must stay stopped, without our own pause, before a
  /// crossfade gives up (see the playing listener in [init]).
  static const _pauseGrace = Duration(seconds: 1);
  Timer? _pauseCheck;

  Song? _songAfter(int i) {
    if (i + 1 < _songs.length) return _songs[i + 1];
    return _player.loopMode == LoopMode.all && _songs.isNotEmpty ? _songs.first : null;
  }

  bool _wantsCrossfade(int i) => shouldCrossfade(
    seconds: crossfade,
    current: _songs[i],
    next: _songAfter(i),
    repeatOne: _player.loopMode == LoopMode.one,
    stopAfterTrack: sleep.value?.endOfTrack == true,
  );

  void _maybeCrossfade(Duration position) {
    if (_fading || _crossfadeTimer != null) return;
    final i = _player.currentIndex;
    final length = _player.duration;
    if (i == null || i >= _songs.length || length == null || !_wantsCrossfade(i)) return;
    final start = crossfadeStart(length, crossfade);
    if (start == null || start < _preroll) return;
    final preroll = start - _preroll;
    final until = preroll - position;
    if (until > const Duration(seconds: 12)) return;
    final key = '$i:${_songs[i].id}';
    if (_tailFor != key) {
      // Joined too late (seeked near the end): the track just ends.
      if (until.isNegative) return;
      _tailFor = key;
      _tailReady = false;
      unawaited(_prepareTail(_songs[i], preroll, key));
      return;
    }
    if (!_tailReady || until > const Duration(seconds: 1)) return;
    if (until < const Duration(milliseconds: -500)) {
      // The tail took too long to load; it would start out of step.
      _stopCrossfade(forget: false);
      return;
    }
    _crossfadeTimer = Timer(until.isNegative ? Duration.zero : until, () => _runCrossfade(key, start, length));
  }

  Future<void> _prepareTail(Song s, Duration at, String key) async {
    final client = _client;
    if (client == null) return;
    final tail = _tail ??= AudioPlayer(handleInterruptions: false, handleAudioSessionActivation: false);
    final local = localPath(s.id);
    final kbps = _streamKbps[s.id] ?? 0;
    try {
      await tail.setVolume(0);
      if (local != null) {
        _tailBase = Duration.zero;
        await tail.setAudioSource(AudioSource.file(local), initialPosition: at);
      } else if (kbps > 0) {
        _tailBase = at;
        await tail.setAudioSource(AudioSource.uri(client.streamUrl(s.id, maxBitRate: kbps, timeOffset: at.inSeconds)));
      } else {
        _tailBase = Duration.zero;
        await tail.setAudioSource(AudioSource.uri(client.streamUrl(s.id)), initialPosition: at);
      }
      if (_tailFor == key) _tailReady = true;
    } catch (_) {
      // No crossfade this time; the track just ends.
    }
  }

  Future<void> _runCrossfade(String key, Duration start, Duration length) async {
    _crossfadeTimer = null;
    final tail = _tail;
    final i = _player.currentIndex;
    if (tail == null || !_tailReady || i == null || '$i:${currentSong?.id}' != key) return;
    if (!_player.playing || !_wantsCrossfade(i)) return;
    _fading = true;
    unawaited(tail.play().catchError((Object _) {}));
    await _alignTail(tail, start);
    // Hand the outgoing track to the tail...
    final outGain = _gain;
    await _ramp(_handoff, (t) {
      tail.setVolume(outGain * _shared * t);
      _fadeIn = 1 - t;
      _applyVolume();
    });
    if (!_fading) return;
    // ...then move the main player on, silent, and fade the two across.
    _fadeIn = 0;
    _applyVolume();
    await _player.seekToNext();
    await _ramp(Duration(seconds: fadeSecondsFor(length, crossfade)) - _handoff, (t) {
      final (out, incoming) = crossfadeLevels(t);
      tail.setVolume(outGain * _shared * out);
      _fadeIn = incoming;
      _applyVolume();
    });
    if (_fading) _stopCrossfade();
  }

  /// Waits for the main player to reach [until], meanwhile nudging the silent
  /// tail's speed so both are at the same moment of the track.
  Future<void> _alignTail(AudioPlayer tail, Duration until) async {
    while (_fading && _player.position < until) {
      final lag = _player.position - (tail.position + _tailBase);
      final speed = lag.inMilliseconds.abs() < 15 ? 1.0 : (lag.isNegative ? 0.92 : 1.08);
      if (tail.speed != speed) await tail.setSpeed(speed);
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    if (tail.speed != 1) await tail.setSpeed(1);
  }

  /// Calls [step] with 0→1 over [length]; stops early if the fade is cancelled.
  Future<void> _ramp(Duration length, void Function(double t) step) async {
    final clock = Stopwatch()..start();
    while (_fading) {
      final t = length <= Duration.zero ? 1.0 : clock.elapsedMilliseconds / length.inMilliseconds;
      step(t.clamp(0.0, 1.0));
      if (t >= 1) return;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  /// Ends any crossfade now: the tail goes quiet and the main player returns
  /// to full level. Unless [forget] is false, a track that's still playing
  /// may set up its crossfade again (after a pause, say).
  void _stopCrossfade({bool forget = true}) {
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;
    _fading = false;
    _tailReady = false;
    if (forget) _tailFor = null;
    final tail = _tail;
    if (tail != null && tail.processingState != ProcessingState.idle) unawaited(tail.stop().catchError((Object _) {}));
    _fadeIn = 1;
    _applyVolume();
  }

  // ---- Persistence ------------------------------------------------------------

  Timer? _debounce;
  void _schedulePersist() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _persist);
  }

  Future<void> _persist() async {
    final snapshot = queueSnapshot();
    if (snapshot != null) await _db.setJson(_kQueue, snapshot);
  }

  Future<void> _restore() async {
    final saved = await _db.getJson(_kQueue);
    if (saved is Map) await _load(saved, play: false);
  }

  /// The queue, where it's up to, and how it plays (order, songs queued by
  /// hand, shuffle, repeat, source). Saved at shutdown and sent to another
  /// device to carry on there. Null with nothing queued.
  ///
  /// [maxSongs] keeps a window around the current song; a shuffled queue
  /// that gets cut loses its original order (it stays in the shuffled one).
  Map<String, Object?>? queueSnapshot({int? maxSongs}) {
    if (_songs.isEmpty) return null;
    var songs = _songs;
    var queued = _queued;
    var unshuffled = _unshuffled;
    var index = _index ?? 0;
    if (maxSongs != null && songs.length > maxSongs) {
      final start = (index - maxSongs ~/ 10).clamp(0, songs.length - maxSongs);
      songs = songs.sublist(start, start + maxSongs);
      queued = queued.sublist(start, start + maxSongs);
      unshuffled = null;
      index -= start;
    }
    return {
      'songs': songs.map((s) => s.toJson()).toList(),
      'unshuffled': unshuffled?.map((s) => s.toJson()).toList(),
      'queued': [
        for (var i = 0; i < queued.length; i++)
          if (queued[i]) i,
      ],
      'index': index,
      'positionMs': (_restoredIndex != null ? _restoredPosition : _player.position).inMilliseconds,
      'loop': _player.loopMode.name,
      'source': _source?.toJson(),
    };
  }

  /// Takes over a queue from [queueSnapshot] (another device's), at its song
  /// and second, playing if [play].
  Future<void> loadQueueSnapshot(Map<Object?, Object?> snapshot, {required bool play}) async {
    _stopCrossfade();
    _autoplayFrom = null;
    if (!await _load(snapshot, play: play)) return;
    _playedHere = true;
    _schedulePersist();
    if (play) unawaited(_player.play());
  }

  Future<bool> _load(Map<Object?, Object?> saved, {required bool play}) async {
    final songs = jsonList(saved['songs']).map(Song.fromJson).toList();
    if (songs.isEmpty) return false;
    final unshuffled = saved['unshuffled'];
    _unshuffled = unshuffled is List ? jsonList(unshuffled).map(Song.fromJson).toList() : null;
    _songs = songs;
    final queued = {for (final i in (saved['queued'] as List?) ?? const []) (i as num).toInt()};
    _queued = [for (var i = 0; i < songs.length; i++) queued.contains(i)];
    _setSource(PlaybackSource.fromJson(saved['source']));
    final index = ((saved['index'] as num?)?.toInt() ?? 0).clamp(0, songs.length - 1);
    final position = Duration(milliseconds: (saved['positionMs'] as num?)?.toInt() ?? 0);
    final loop = LoopMode.values.where((m) => m.name == saved['loop']).firstOrNull ?? LoopMode.off;
    try {
      await _player.setLoopMode(loop);
      await _player.setAudioSources(
        await _sources(songs),
        initialIndex: index,
        initialPosition: position,
        preload: false,
      );
      // Until it loads, the player would report the first song as current.
      _restoredIndex = index;
      _restoredPosition = position;
    } on PlayerInterruptedException {
      return false;
    } catch (_) {
      return false;
    }
    queue.add(_queueItems());
    _publishMediaItem();
    _broadcastState(_player.playbackEvent);
    return true;
  }

  Future<void> dispose() async {
    _stopCrossfade();
    await _tail?.dispose();
    await _player.dispose();
    // After the players: their last events can still schedule a save.
    _persistTimer?.cancel();
    _debounce?.cancel();
    _stallTimer?.cancel();
    _sleepTicker?.cancel();
    _volumeSave?.cancel();
    _queueSyncSoon?.cancel();
    _pauseCheck?.cancel();
    await _errors.close();
  }
}
