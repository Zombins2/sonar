import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:sonar/audio/audio_handler.dart';
import 'package:sonar/audio/playback_source.dart';
import 'package:sonar/data/db/database.dart';
import 'package:sonar/data/subsonic/models.dart';

import 'fake_audio.dart';
import 'fake_server.dart';

/// A 20-second song (the length the fake player gives every item).
Song testSong(String id, {String? albumId, int? track, int? disc, ReplayGain? gain}) => Song(
  id: id,
  title: id,
  albumId: albumId,
  track: track,
  discNumber: disc,
  duration: const Duration(seconds: 20),
  replayGain: gain,
);

/// Polls [done] in real time; the fake player runs on the wall clock.
Future<void> waitFor(bool Function() done, {Duration timeout = const Duration(seconds: 8)}) async {
  final clock = Stopwatch()..start();
  while (!done()) {
    if (clock.elapsed > timeout) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Real [SonarAudioHandler]s on a fake native player. Call [setUp] and
/// [tearDown] from the test's own hooks.
class PlayerHarness {
  late FakeJustAudio platform;
  final _open = <(SonarAudioHandler, AppDatabase)>[];

  void setUp({bool blipOnSkip = false}) {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.audio_session'),
      (_) async => null,
    );
    platform = FakeJustAudio((_) => const Duration(seconds: 20), blipOnSkip: blipOnSkip);
    JustAudioPlatform.instance = platform;
  }

  Future<void> tearDown() async {
    final closed = <AppDatabase>{};
    for (final (h, db) in _open) {
      await h.dispose();
      if (closed.add(db)) await db.close();
    }
    _open.clear();
  }

  /// A handler playing [songs]. Each gets its own database unless [db] is
  /// given, so none restores another's queue.
  Future<SonarAudioHandler> start(
    List<Song> songs, {
    int crossfade = 1,
    int bitrate = 0,
    bool level = true,
    PlaybackSource? source,
    FakeServer? server,
    AppDatabase? db,
    Duration position = Duration.zero,
    bool play = true,
  }) async {
    db ??= AppDatabase(NativeDatabase.memory());
    final h = SonarAudioHandler(db)
      ..crossfade = crossfade
      ..autoplay = false
      ..levelVolume = level
      ..bitrateResolver = () async => bitrate;
    _open.add((h, db));
    final mine = platform.players.length;
    await h.init();
    await h.setClient((server ?? fakeServer({})).client);
    if (!play) return h;
    await h.playSongs(songs, source: source, position: position);
    await waitFor(() => platform.players.length > mine && platform.players[mine].playing);
    return h;
  }

  /// The crossfade's tail player, once one has been made.
  FakePlayer? get tail => platform.players.length > 1 ? platform.players[1] : null;
}
