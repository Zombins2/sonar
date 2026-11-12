import 'dart:async';

import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// Stands in for the native player: plays in real time, moves on to the next
/// item at the end of each one, and records what it was asked to do.
class FakeJustAudio extends JustAudioPlatform {
  FakeJustAudio(this.lengthOf, {this.blipOnSkip = false});

  /// Length of the item at a URI (stream URLs carry the song id).
  final Duration Function(Uri uri) lengthOf;

  /// Act like Windows' player: report "loading, not playing" for a moment
  /// while the next item opens after a skip.
  final bool blipOnSkip;

  /// Every native player created, oldest first. just_audio makes a new one
  /// each time a stopped player is loaded again.
  final players = <FakePlayer>[];

  /// How long opening a queue takes, for loads from now on (Windows takes a
  /// moment to open a stream and find the second).
  Duration loadDelay = Duration.zero;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final p = FakePlayer(request.id, lengthOf, blipOnSkip: blipOnSkip, loadDelay: () => loadDelay);
    players.add(p);
    return p;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) async {
    for (final p in players.where((p) => p.id == request.id)) {
      p.disposed = true;
      p._stopClock();
    }
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(DisposeAllPlayersRequest request) async {
    for (final p in players) {
      p.disposed = true;
      p._stopClock();
    }
    return DisposeAllPlayersResponse();
  }
}

class FakeLoad {
  const FakeLoad(this.uris, this.position, this.index);
  final List<Uri> uris;
  final Duration? position;
  final int? index;
}

class FakePlayer extends AudioPlayerPlatform {
  FakePlayer(super.id, this._lengthOf, {this.blipOnSkip = false, Duration Function()? loadDelay})
    : _loadDelay = loadDelay ?? (() => Duration.zero);

  final Duration Function(Uri uri) _lengthOf;
  final bool blipOnSkip;
  final Duration Function() _loadDelay;
  final _events = StreamController<PlaybackEventMessage>.broadcast();
  final _data = StreamController<PlayerDataMessage>.broadcast();

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  final loads = <FakeLoad>[];
  final volumes = <double>[];
  final speeds = <double>[];
  final seeks = <(Duration?, int?)>[];
  int plays = 0;
  bool disposed = false;

  List<Uri> _items = [];
  int _index = 0;
  var _state = ProcessingStateMessage.idle;
  bool playing = false;
  double _speed = 1;
  Duration _from = Duration.zero;
  DateTime _since = DateTime.now();
  Timer? _end;
  Completer<void>? _playing;

  int get index => _index;
  Duration get _length => _items.isEmpty ? Duration.zero : _lengthOf(_items[_index]);

  Duration get position {
    if (!playing || _state != ProcessingStateMessage.ready) return _from;
    final p = _from + DateTime.now().difference(_since) * _speed;
    return p < _length ? p : _length;
  }

  void _mark(Duration p) {
    _from = p;
    _since = DateTime.now();
  }

  void _stopClock() {
    _end?.cancel();
    _end = null;
  }

  void _runClock() {
    _stopClock();
    if (!playing || _state != ProcessingStateMessage.ready) return;
    _end = Timer((_length - position) * (1 / _speed), () {
      if (_index + 1 < _items.length) {
        _index++;
        _mark(Duration.zero);
        _emit();
        _runClock();
      } else {
        _mark(_length);
        _state = ProcessingStateMessage.completed;
        _emit();
        _playing?.complete();
      }
    });
  }

  void _emit() {
    if (_events.isClosed) return;
    _events.add(
      PlaybackEventMessage(
        processingState: _state,
        updateTime: _since,
        updatePosition: _from,
        bufferedPosition: _length,
        duration: _items.isEmpty ? null : _length,
        icyMetadata: null,
        currentIndex: _items.isEmpty ? null : _index,
        androidAudioSessionId: null,
      ),
    );
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    final delay = _loadDelay();
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final source = request.audioSourceMessage;
    final children = source is ConcatenatingAudioSourceMessage ? source.children : [source];
    _items = [for (final c in children.whereType<UriAudioSourceMessage>()) Uri.parse(c.uri)];
    loads.add(FakeLoad(List.of(_items), request.initialPosition, request.initialIndex));
    _index = request.initialIndex ?? 0;
    _mark(request.initialPosition ?? Duration.zero);
    _state = ProcessingStateMessage.ready;
    _emit();
    _runClock();
    return LoadResponse(duration: _items.isEmpty ? null : _length);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    plays++;
    if (playing) return PlayResponse();
    _mark(position);
    playing = true;
    _emit();
    _runClock();
    _playing = Completer<void>();
    await _playing!.future;
    return PlayResponse();
  }

  /// The system pausing playback on its own (another app took the audio).
  void pauseFromOutside() {
    _mark(position);
    playing = false;
    _stopClock();
    _emit();
    _data.add(PlayerDataMessage(playing: false));
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    if (!playing) return PauseResponse();
    _mark(position);
    playing = false;
    _stopClock();
    _emit();
    if (!(_playing?.isCompleted ?? true)) _playing!.complete();
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    seeks.add((request.position, request.index));
    if (request.index != null) _index = request.index!;
    _mark(request.position ?? Duration.zero);
    if (blipOnSkip && request.index != null && playing) {
      // Windows can report this as paused, not loading, for a moment.
      _state = ProcessingStateMessage.ready;
      _emit();
      _data.add(PlayerDataMessage(playing: false));
      Timer(const Duration(milliseconds: 60), () {
        if (_events.isClosed) return;
        _mark(Duration.zero);
        _state = ProcessingStateMessage.ready;
        _emit();
        _data.add(PlayerDataMessage(playing: true));
        _runClock();
      });
      return SeekResponse();
    }
    _state = ProcessingStateMessage.ready;
    _emit();
    _runClock();
    return SeekResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    volumes.add(request.volume);
    return SetVolumeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    speeds.add(request.speed);
    _mark(position);
    _speed = request.speed;
    _emit();
    _runClock();
    return SetSpeedResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async => SetLoopModeResponse();

  @override
  Future<SetShuffleModeResponse> setShuffleMode(SetShuffleModeRequest request) async => SetShuffleModeResponse();

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(SetShuffleOrderRequest request) async => SetShuffleOrderResponse();

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async => SetPitchResponse();

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(SetSkipSilenceRequest request) async => SetSkipSilenceResponse();

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(SetAndroidAudioAttributesRequest request) async =>
      SetAndroidAudioAttributesResponse();

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse> setAutomaticallyWaitsToMinimizeStalling(
    SetAutomaticallyWaitsToMinimizeStallingRequest request,
  ) async => SetAutomaticallyWaitsToMinimizeStallingResponse();

  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
  setCanUseNetworkResourcesForLiveStreamingWhilePaused(
    SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest request,
  ) async => SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();

  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(SetPreferredPeakBitRateRequest request) async =>
      SetPreferredPeakBitRateResponse();

  @override
  Future<SetAllowsExternalPlaybackResponse> setAllowsExternalPlayback(SetAllowsExternalPlaybackRequest request) async =>
      SetAllowsExternalPlaybackResponse();

  @override
  Future<AudioEffectSetEnabledResponse> audioEffectSetEnabled(AudioEffectSetEnabledRequest request) async =>
      AudioEffectSetEnabledResponse();

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(ConcatenatingInsertAllRequest request) async {
    _items.insertAll(request.index, [
      for (final c in request.children.whereType<UriAudioSourceMessage>()) Uri.parse(c.uri),
    ]);
    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(ConcatenatingRemoveRangeRequest request) async {
    _items.removeRange(request.startIndex, request.endIndex);
    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(ConcatenatingMoveRequest request) async =>
      ConcatenatingMoveResponse();

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    disposed = true;
    _stopClock();
    _state = ProcessingStateMessage.idle;
    _emit();
    await _events.close();
    await _data.close();
    return DisposeResponse();
  }
}
