import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../audio/audio_handler.dart';
import '../audio/playback_source.dart';
import '../audio/player_controls.dart';
import '../connect/connect_client.dart';
import '../connect/connect_link.dart';
import '../connect/remote_player.dart';
import '../core/platform.dart';
import '../data/auth/credentials_store.dart';
import '../data/db/database.dart';
import '../data/discovery.dart';
import '../data/handoff.dart';
import '../data/lyrics/lrclib_client.dart';
import '../data/subsonic/models.dart';
import '../data/subsonic/subsonic_client.dart';
import '../downloads/download_manager.dart';

// ---- Singletons (overridden in main) -----------------------------------------

final dbProvider = Provider<AppDatabase>((_) => throw UnimplementedError());
final audioHandlerProvider = Provider<SonarAudioHandler>((_) => throw UnimplementedError());
final credentialsStoreProvider = Provider((_) => CredentialsStore());
final downloadManagerProvider = ChangeNotifierProvider<DownloadManager>((_) => throw UnimplementedError());

// ---- Session -----------------------------------------------------------------

class SessionNotifier extends AsyncNotifier<ServerCredentials?> {
  @override
  Future<ServerCredentials?> build() => ref.read(credentialsStoreProvider).load();

  /// Pings the server with the given credentials; saves them only on success.
  Future<void> login({required String url, required String username, required String password}) async {
    final creds = ServerCredentials(
      baseUrl: SubsonicClient.normaliseUrl(url),
      username: username.trim(),
      password: password,
    );
    await SubsonicClient(creds).ping();
    await ref.read(credentialsStoreProvider).save(creds);
    state = AsyncData(creds);
  }

  Future<void> logout() async {
    await ref.read(credentialsStoreProvider).clear();
    await ref.read(downloadManagerProvider).removeAll();
    await ref.read(dbProvider).clearAll();
    state = const AsyncData(null);
  }
}

final sessionProvider = AsyncNotifierProvider<SessionNotifier, ServerCredentials?>(SessionNotifier.new);

/// Whether the last request reached the server. Drives the offline banner.
final reachableProvider = StateProvider<bool>((_) => true);

final clientProvider = Provider<SubsonicClient?>((ref) {
  final creds = ref.watch(sessionProvider).valueOrNull;
  if (creds == null) return null;
  return SubsonicClient(
    creds,
    cache: ref.read(dbProvider),
    onReachability: (ok) {
      final n = ref.read(reachableProvider.notifier);
      if (n.state != ok) n.state = ok;
    },
  );
});

/// Use inside data providers that only run behind the login gate.
SubsonicClient requireClient(Ref ref) {
  final c = ref.watch(clientProvider);
  if (c == null) throw const SubsonicException(SubsonicErrorKind.badCredentials, 'Not logged in');
  return c;
}

/// [requireClient] for widgets, read once rather than watched.
SubsonicClient requireClientOf(WidgetRef ref) {
  final c = ref.read(clientProvider);
  if (c == null) throw const SubsonicException(SubsonicErrorKind.badCredentials, 'Not logged in');
  return c;
}

// ---- Settings ----------------------------------------------------------------

/// Streaming caps in kbps. 0 means original quality.
const bitrateOptions = [0, 320, 192, 128];

String bitrateLabel(int kbps) => kbps == 0 ? 'Original' : '$kbps kbps';

class StreamSettings {
  const StreamSettings({
    this.wifi = 0,
    this.cellular = 192,
    this.downloadOnCellular = false,
    this.onlineLyrics = true,
    this.autoplay = true,
    this.crossfade = 6,
    this.levelVolume = true,
  });
  final int wifi;
  final int cellular;
  final bool downloadOnCellular;

  /// Look up synced lyrics on LRCLIB when the server only has plain text.
  final bool onlineLyrics;

  /// Keep playing similar songs when the queue ends.
  final bool autoplay;

  /// Seconds songs overlap as one hands over to the next (0 = off).
  final int crossfade;

  /// Even out loudness between songs with their ReplayGain tags.
  final bool levelVolume;
}

class SettingsNotifier extends Notifier<StreamSettings> {
  static const _key = 'stream_settings';

  @override
  StreamSettings build() {
    _load();
    return const StreamSettings();
  }

  Future<void> _load() async {
    final j = await ref.read(dbProvider).getJson(_key);
    if (j is Map) {
      state = StreamSettings(
        wifi: (j['wifi'] as num?)?.toInt() ?? 0,
        cellular: (j['cellular'] as num?)?.toInt() ?? 192,
        downloadOnCellular: j['downloadOnCellular'] == true,
        onlineLyrics: j['onlineLyrics'] != false,
        autoplay: j['autoplay'] != false,
        crossfade: (j['crossfade'] as num?)?.toInt() ?? 6,
        levelVolume: j['levelVolume'] != false,
      );
    }
  }

  Future<void> set({
    int? wifi,
    int? cellular,
    bool? downloadOnCellular,
    bool? onlineLyrics,
    bool? autoplay,
    int? crossfade,
    bool? levelVolume,
  }) async {
    state = StreamSettings(
      wifi: wifi ?? state.wifi,
      cellular: cellular ?? state.cellular,
      downloadOnCellular: downloadOnCellular ?? state.downloadOnCellular,
      onlineLyrics: onlineLyrics ?? state.onlineLyrics,
      autoplay: autoplay ?? state.autoplay,
      crossfade: crossfade ?? state.crossfade,
      levelVolume: levelVolume ?? state.levelVolume,
    );
    await ref.read(dbProvider).setJson(_key, {
      'wifi': state.wifi,
      'cellular': state.cellular,
      'downloadOnCellular': state.downloadOnCellular,
      'onlineLyrics': state.onlineLyrics,
      'autoplay': state.autoplay,
      'crossfade': state.crossfade,
      'levelVolume': state.levelVolume,
    });
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, StreamSettings>(SettingsNotifier.new);

/// Picks the bitrate cap for whatever network the phone is on right now.
Future<int> resolveBitrate(StreamSettings s) async {
  final types = await Connectivity().checkConnectivity();
  final onMetered =
      types.contains(ConnectivityResult.mobile) &&
      !types.contains(ConnectivityResult.wifi) &&
      !types.contains(ConnectivityResult.ethernet);
  return onMetered ? s.cellular : s.wifi;
}

// ---- Library data ------------------------------------------------------------

final albumListProvider = FutureProvider.autoDispose.family<List<Album>, AlbumListType>(
  (ref, type) => requireClient(ref).getAlbumList2(type, size: type == AlbumListType.recent ? 30 : 20),
);

final albumProvider = FutureProvider.autoDispose.family<Album, String>((ref, id) async {
  try {
    return await requireClient(ref).getAlbum(id);
  } on SubsonicException {
    // Offline with no cached response: fall back to the downloaded copy.
    final d = ref.read(downloadManagerProvider).collection('album', id);
    if (d == null) rethrow;
    return Album(
      id: id,
      name: d.title,
      artist: d.subtitle,
      artistId: d.songs.firstOrNull?.artistId,
      coverArt: d.coverArt,
      songCount: d.songs.length,
      duration: d.songs.fold(Duration.zero, (t, s) => t + s.duration),
      songs: d.songs,
    );
  }
});

final artistProvider = FutureProvider.autoDispose.family<Artist, String>((ref, id) => requireClient(ref).getArtist(id));

final artistsProvider = FutureProvider.autoDispose<List<Artist>>((ref) => requireClient(ref).getArtists());

/// Genres with music in them, biggest first.
final genresProvider = FutureProvider.autoDispose<List<Genre>>((ref) async {
  final genres = await requireClient(ref).getGenres();
  return genres.where((g) => g.albumCount > 0 || g.songCount > 0).toList()
    ..sort((a, b) => b.albumCount.compareTo(a.albumCount));
});

final genreAlbumsProvider = FutureProvider.autoDispose.family<List<Album>, String>(
  (ref, genre) => requireClient(ref).getAlbumsByGenre(genre),
);

// ---- Discovery ---------------------------------------------------------------

/// The artists "Made for you" mixes are built around: the most played.
/// Not auto-disposed, since [mixProvider] keeps it alive anyway.
final mixSeedsProvider = FutureProvider<List<MixSeed>>(
  (ref) async => topArtists(await requireClient(ref).getAlbumList2(AlbumListType.frequent, size: 60)),
);

/// One mix per artist. Kept for the session so it doesn't reshuffle on every visit.
final mixProvider = FutureProvider.family<List<Song>, String>((ref, artistId) async {
  final client = requireClient(ref);
  final seeds = await ref.watch(mixSeedsProvider.future);
  var seed = seeds.where((s) => s.artistId == artistId).firstOrNull;
  if (seed == null) {
    // Opened from a link after the top artists changed.
    final a = await client.getArtist(artistId);
    seed = MixSeed(artistId: a.id, artist: a.name, coverArt: a.coverArt);
  }
  return artistMix(client, seed);
});

/// Albums played a lot, but not lately.
final rediscoverProvider = FutureProvider.autoDispose<List<Album>>((ref) async {
  final client = requireClient(ref);
  final (frequent, recent) = await (
    client.getAlbumList2(AlbumListType.frequent, size: 60),
    client.getAlbumList2(AlbumListType.recent, size: 60),
  ).wait;
  return rediscover(frequent, recent);
});

/// Albums in the library nobody has played yet.
final unplayedProvider = FutureProvider.autoDispose<List<Album>>(
  (ref) async => unplayed(await requireClient(ref).getAlbumList2(AlbumListType.random, size: 100)),
);

/// An artist's most popular songs (by name: that's what getTopSongs takes).
final topSongsProvider = FutureProvider.autoDispose.family<List<Song>, String>(
  (ref, artist) => requireClient(ref).getTopSongs(artist),
);

final artistInfoProvider = FutureProvider.autoDispose.family<ArtistInfo, String>(
  (ref, id) => requireClient(ref).getArtistInfo2(id),
);

final playlistsProvider = FutureProvider.autoDispose<List<Playlist>>((ref) => requireClient(ref).getPlaylists());

final playlistProvider = FutureProvider.autoDispose.family<Playlist, String>((ref, id) async {
  try {
    return await requireClient(ref).getPlaylist(id);
  } on SubsonicException {
    final d = ref.read(downloadManagerProvider).collection('playlist', id);
    if (d == null) rethrow;
    return Playlist(
      id: id,
      name: d.title,
      owner: d.subtitle,
      coverArt: d.coverArt,
      songCount: d.songs.length,
      duration: d.songs.fold(Duration.zero, (t, s) => t + s.duration),
      songs: d.songs,
    );
  }
});

/// What a lyrics lookup needs. Equal by song id only, so the player filling
/// in the exact duration later doesn't trigger a second lookup.
class LyricsQuery {
  const LyricsQuery({required this.id, required this.title, required this.artist, required this.duration});
  final String id;
  final String title;
  final String artist;
  final Duration duration;

  static LyricsQuery? of(MediaItem? item) => item == null
      ? null
      : LyricsQuery(
          id: item.id,
          title: item.title,
          artist: item.artist ?? '',
          duration: item.duration ?? Duration.zero,
        );

  @override
  bool operator ==(Object other) => other is LyricsQuery && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Synced lyrics from the server win. Otherwise try [online], falling back to
/// whatever the server had (plain text, or nothing).
Future<Lyrics?> resolveLyrics(Future<Lyrics?> Function() server, Future<Lyrics?> Function()? online) async {
  Lyrics? fromServer;
  try {
    fromServer = await server();
  } on SubsonicException {
    fromServer = null;
  }
  if (fromServer?.synced == true || online == null) return fromServer;
  try {
    return await online() ?? fromServer;
  } catch (_) {
    return fromServer;
  }
}

final lrclibProvider = Provider((_) => LrclibClient());

/// LRCLIB lookups are kept on the phone: hits for good, misses for a week.
Future<Lyrics?> _lrclibLyrics(Ref ref, LyricsQuery q) async {
  final db = ref.read(dbProvider);
  final key = 'lrclib:${q.id}';
  final saved = await db.getJson(key);
  if (saved is Map) {
    final lrc = saved['lrc'];
    if (lrc is String) return Lyrics.fromLrc(lrc, credit: LrclibClient.credit);
    final missedAt = DateTime.fromMillisecondsSinceEpoch((saved['missedAt'] as num?)?.toInt() ?? 0);
    if (DateTime.now().difference(missedAt) < const Duration(days: 7)) return null;
  }
  if (q.title.isEmpty || q.artist.isEmpty) return null;
  final lrc = await ref.read(lrclibProvider).findLrc(title: q.title, artist: q.artist, duration: q.duration);
  await db.setJson(key, lrc == null ? {'missedAt': DateTime.now().millisecondsSinceEpoch} : {'lrc': lrc});
  return lrc == null ? null : Lyrics.fromLrc(lrc, credit: LrclibClient.credit);
}

final lyricsProvider = FutureProvider.autoDispose.family<Lyrics?, LyricsQuery>((ref, q) {
  final client = requireClient(ref);
  final online = ref.watch(settingsProvider.select((s) => s.onlineLyrics));
  return resolveLyrics(() => client.getLyrics(q.id), online ? () => _lrclibLyrics(ref, q) : null);
});

/// Lyrics for whatever is playing right now.
final currentLyricsProvider = Provider.autoDispose<AsyncValue<Lyrics?>>((ref) {
  final q = LyricsQuery.of(ref.watch(mediaItemProvider).valueOrNull);
  return q == null ? const AsyncData(null) : ref.watch(lyricsProvider(q));
});

// ---- Favorites ---------------------------------------------------------------

/// Locally tracked star state, seeded from getStarred2 and updated optimistically.
class StarredNotifier extends AsyncNotifier<Set<String>> {
  @override
  Future<Set<String>> build() async {
    final s = await requireClient(ref).getStarred2();
    return {...s.songs.map((e) => e.id), ...s.albums.map((e) => e.id), ...s.artists.map((e) => e.id)};
  }

  bool isStarred(String id) => state.valueOrNull?.contains(id) ?? false;

  Future<void> _toggle(String id, {required _StarKind kind}) async {
    final client = requireClient(ref);
    final current = state.valueOrNull ?? <String>{};
    final starring = !current.contains(id);
    state = AsyncData(starring ? {...current, id} : ({...current}..remove(id)));
    try {
      final args = switch (kind) {
        _StarKind.song => (id: id, albumId: null, artistId: null),
        _StarKind.album => (id: null, albumId: id, artistId: null),
        _StarKind.artist => (id: null, albumId: null, artistId: id),
      };
      if (starring) {
        await client.star(id: args.id, albumId: args.albumId, artistId: args.artistId);
      } else {
        await client.unstar(id: args.id, albumId: args.albumId, artistId: args.artistId);
      }
      ref.invalidate(albumListProvider(AlbumListType.starred));
    } catch (_) {
      state = AsyncData(current);
      rethrow;
    }
  }

  Future<void> toggleSong(String id) => _toggle(id, kind: _StarKind.song);
  Future<void> toggleAlbum(String id) => _toggle(id, kind: _StarKind.album);
  Future<void> toggleArtist(String id) => _toggle(id, kind: _StarKind.artist);
}

enum _StarKind { song, album, artist }

final starredProvider = AsyncNotifierProvider<StarredNotifier, Set<String>>(StarredNotifier.new);

// ---- Carrying on from another device ------------------------------------------

const _kHandoffDismissed = 'handoff_dismissed';

/// A queue another device left on the server that this one could pick up.
/// Re-checked whenever the app comes back to the front.
final handoffProvider = FutureProvider.autoDispose<PlayQueue?>((ref) async {
  final client = ref.watch(clientProvider);
  if (client == null) return null;
  final handler = ref.read(audioHandlerProvider);
  final dismissed = await ref.read(dbProvider).getJson(_kHandoffDismissed);
  return handoffOffer(
    server: await client.getPlayQueue(),
    me: SubsonicClient.clientName,
    playingHere: handler.player.playing,
    currentHere: handler.currentSong?.id,
    positionHere: handler.player.position,
    dismissed: dismissed is String ? DateTime.tryParse(dismissed) : null,
  );
});

/// Stops offering [queue] (picked up, or turned down).
Future<void> dismissHandoff(WidgetRef ref, PlayQueue queue) async {
  await ref.read(dbProvider).setJson(_kHandoffDismissed, queue.changed?.toIso8601String());
  ref.invalidate(handoffProvider);
}

// ---- Recent searches ---------------------------------------------------------

class RecentSearchesNotifier extends Notifier<List<String>> {
  static const _key = 'recent_searches';

  @override
  List<String> build() {
    ref.read(dbProvider).getJson(_key).then((v) {
      if (v is List) state = v.map((e) => '$e').toList();
    });
    return const [];
  }

  void add(String q) {
    final query = q.trim();
    if (query.isEmpty) return;
    state = [query, ...state.where((e) => e.toLowerCase() != query.toLowerCase())].take(12).toList();
    ref.read(dbProvider).setJson(_key, state);
  }

  void remove(String q) {
    state = state.where((e) => e != q).toList();
    ref.read(dbProvider).setJson(_key, state);
  }

  void clear() {
    state = const [];
    ref.read(dbProvider).setJson(_key, state);
  }
}

final recentSearchesProvider = NotifierProvider<RecentSearchesNotifier, List<String>>(RecentSearchesNotifier.new);

// ---- Sonar Connect ------------------------------------------------------------

/// Off in widget tests, which have no relay to talk to.
final connectEnabledProvider = Provider<bool>((_) => true);

const _kDeviceId = 'connect_device_id';

/// This app on Sonar Connect: a random id kept on the device, and a name.
final connectDeviceProvider = FutureProvider<ConnectDeviceInfo>((ref) async {
  final db = ref.read(dbProvider);
  var id = await db.getJson(_kDeviceId);
  if (id is! String || id.isEmpty) {
    final r = Random.secure();
    id = List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
    await db.setJson(_kDeviceId, id);
  }
  final pc = isDesktopPlatform;
  return ConnectDeviceInfo(id: id, name: pc ? 'PC' : 'Phone', kind: pc ? 'pc' : 'phone');
});

/// The link to this account's other devices, while logged in.
final connectLinkProvider = Provider<ConnectLink?>((ref) {
  if (!ref.watch(connectEnabledProvider)) return null;
  final creds = ref.watch(sessionProvider).valueOrNull;
  final me = ref.watch(connectDeviceProvider).valueOrNull;
  if (creds == null || me == null) return null;
  final login = SubsonicClient(creds);
  final link = ConnectLink(
    handler: ref.read(audioHandlerProvider),
    client: ConnectClient(base: connectBaseFor(creds.baseUrl), me: me, loginProof: login.loginProof),
  )..start();
  ref.onDispose(link.dispose);
  return link;
});

/// The account's other devices that are online, by id.
final connectDevicesProvider = StreamProvider<Map<String, ConnectDevice>>((ref) {
  final link = ref.watch(connectLinkProvider);
  return link == null ? Stream.value(const {}) : valueStream(link.client.devices);
});

final connectStatusProvider = StreamProvider<ConnectStatus>((ref) {
  final link = ref.watch(connectLinkProvider);
  return link == null ? Stream.value(ConnectStatus.off) : valueStream(link.client.status);
});

/// Which device the player controls here drive: null for this one, or
/// another device's id.
///
/// It follows another device on its own when this one isn't playing and that
/// one is (open the phone while the PC plays: the phone shows the PC), and
/// comes back here when that device goes away or empties its queue, or when
/// this one starts playing. Picking a device sets it outright.
class OutputTarget extends Notifier<String?> {
  Timer? _pauseCheck;
  DateTime _pickedAt = DateTime(2000);

  @override
  String? build() {
    final link = ref.watch(connectLinkProvider);
    if (link == null) return null;
    final handler = ref.read(audioHandlerProvider);
    final devices = link.client.devices;
    devices.addListener(_check);
    final took = link.tookOver.listen((_) => state = null);
    final playing = handler.player.playingStream.listen((on) {
      _pauseCheck?.cancel();
      if (on) {
        state = null;
      } else {
        // Windows reports "not playing" for a moment between songs.
        _pauseCheck = Timer(const Duration(milliseconds: 1500), _check);
      }
    });
    ref.onDispose(() {
      devices.removeListener(_check);
      took.cancel();
      playing.cancel();
      _pauseCheck?.cancel();
    });
    return _follow(link);
  }

  String? _follow(ConnectLink link) {
    if (ref.read(audioHandlerProvider).player.playing) return null;
    return link.client.devices.value.values.where((d) => d.playing && d.hasSong).firstOrNull?.id;
  }

  void _check() {
    final link = ref.read(connectLinkProvider);
    if (link == null) return;
    final current = state;
    if (current == null) {
      state = _follow(link);
      return;
    }
    final d = link.client.devices.value[current];
    // A device just picked may not have reported its new song yet.
    final settling = DateTime.now().difference(_pickedAt) < const Duration(seconds: 10);
    if (d == null || (!d.hasSong && !settling)) state = _follow(link);
  }

  /// Show and control [deviceId] (null: this device), without moving playback.
  void pick(String? deviceId) {
    _pickedAt = DateTime.now();
    state = deviceId;
  }
}

final outputTargetProvider = NotifierProvider<OutputTarget, String?>(OutputTarget.new);

/// The other device being shown and controlled here, if any.
final remotePlayerProvider = Provider<RemotePlayer?>((ref) {
  final link = ref.watch(connectLinkProvider);
  final id = ref.watch(outputTargetProvider);
  if (link == null || id == null) return null;
  final remote = RemotePlayer(client: link.client, deviceId: id, subsonic: ref.watch(clientProvider));
  ref.onDispose(remote.dispose);
  return remote;
});

/// What the play/pause, skip, seek and queue controls drive.
final controlsProvider = Provider<PlayerControls>(
  (ref) => ref.watch(remotePlayerProvider) ?? ref.watch(audioHandlerProvider),
);

/// Moves playback to [to] (null: this device) from wherever it is now.
Future<bool> movePlaybackTo(WidgetRef ref, String? to) async {
  final link = ref.read(connectLinkProvider);
  if (link == null) return false;
  final from = ref.read(outputTargetProvider);
  final ok = await link.moveTo(to, from: from);
  // Coming here, the view switches when the queue arrives (tookOver), so it
  // doesn't flash this device's old queue first.
  if (ok && !(to == null && from != null)) ref.read(outputTargetProvider.notifier).pick(to);
  return ok;
}

// ---- Player streams ----------------------------------------------------------
// The player shown: this device's, or another's while it's the output target.

final mediaItemProvider = StreamProvider<MediaItem?>(
  (ref) => ref.watch(remotePlayerProvider)?.mediaItem ?? ref.watch(audioHandlerProvider).mediaItem,
);

final queueProvider = StreamProvider<List<MediaItem>>(
  (ref) => ref.watch(remotePlayerProvider)?.queue ?? ref.watch(audioHandlerProvider).queue,
);

final playbackStateProvider = StreamProvider<PlaybackState>(
  (ref) => ref.watch(remotePlayerProvider)?.playbackState ?? ref.watch(audioHandlerProvider).playbackState,
);

final playbackSourceProvider = StreamProvider<PlaybackSource?>(
  (ref) =>
      ref.watch(remotePlayerProvider)?.source ??
      ref.watch(audioHandlerProvider).customState.map((s) => s is PlaybackSource ? s : null),
);

/// The volume slider of the player shown, 0–1.
final volumeProvider = StreamProvider<double>(
  (ref) => ref.watch(remotePlayerProvider)?.volumeStream ?? valueStream(ref.watch(audioHandlerProvider).userVolume),
);

final currentSongIdProvider = Provider<String?>((ref) => ref.watch(mediaItemProvider).valueOrNull?.id);

final currentAlbumIdProvider = Provider<String?>(
  (ref) => ref.watch(mediaItemProvider).valueOrNull?.extras?['albumId'] as String?,
);

final playingProvider = StreamProvider<bool>(
  (ref) => ref.watch(remotePlayerProvider)?.playingStream ?? ref.watch(audioHandlerProvider).player.playingStream,
);

final loopModeProvider = StreamProvider<LoopMode>(
  (ref) => ref.watch(remotePlayerProvider)?.loopModeStream ?? ref.watch(audioHandlerProvider).player.loopModeStream,
);

/// Position, buffered position and duration, sampled for the scrubber.
class PositionData {
  const PositionData(this.position, this.duration);
  final Duration position;
  final Duration duration;

  double get fraction {
    final d = duration.inMilliseconds;
    return d <= 0 ? 0 : (position.inMilliseconds / d).clamp(0.0, 1.0);
  }
}

final positionProvider = StreamProvider<PositionData>((ref) {
  final remote = ref.watch(remotePlayerProvider);
  if (remote != null) return remote.positionStream.map((p) => PositionData(p, remote.duration));
  final handler = ref.watch(audioHandlerProvider);
  final player = handler.player;
  return player
      .createPositionStream(minPeriod: const Duration(milliseconds: 200), maxPeriod: const Duration(milliseconds: 500))
      .map((p) {
        final fallback = handler.mediaItem.value?.duration ?? Duration.zero;
        return PositionData(p, player.duration ?? fallback);
      });
});
