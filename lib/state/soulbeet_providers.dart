import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connect/connect_client.dart';
import '../data/deezer/deezer_client.dart';
import '../data/discover/discover.dart';
import '../data/discovery.dart';
import '../data/musicbrainz/musicbrainz_client.dart';
import '../data/soulbeet/get_music_search.dart';
import '../data/soulbeet/get_music_suggestions.dart';
import '../data/soulbeet/library_match.dart';
import '../data/soulbeet/soulbeet_client.dart';
import '../data/soulbeet/soulbeet_downloads.dart';
import '../data/soulbeet/soulbeet_models.dart';
import '../data/subsonic/models.dart';
import '../data/subsonic/subsonic_client.dart';
import 'providers.dart';

/// Get music: Soulbeet beside Navidrome (docs/SOULBEET_PLAN.md).

/// Off in tests and screenshot renders unless a test turns it on.
final soulbeetEnabledProvider = Provider<bool>((_) => true);

/// Overrides where Soulbeet is (tests); null means beside Navidrome.
final soulbeetBaseOverrideProvider = Provider<Uri?>((_) => null);

final soulbeetClientProvider = Provider<SoulbeetClient?>((ref) {
  if (!ref.watch(soulbeetEnabledProvider)) return null;
  final creds = ref.watch(sessionProvider).valueOrNull;
  if (creds == null) return null;
  final store = ref.read(credentialsStoreProvider);
  final client = SoulbeetClient(
    base: ref.watch(soulbeetBaseOverrideProvider) ?? soulbeetBaseFor(creds.baseUrl),
    username: creds.username,
    password: creds.password,
    savedToken: store.soulbeetToken,
    onToken: (t) => store.saveSoulbeetToken(t),
  );
  ref.onDispose(client.close);
  return client;
});

/// Whether Soulbeet answers and can download, so the app only offers Get
/// music where it works. Checked once per login (and on retry).
final soulbeetHealthProvider = FutureProvider<SbHealth?>((ref) async {
  final client = ref.watch(soulbeetClientProvider);
  if (client == null) return null;
  try {
    return await client.health();
  } on Object {
    return null;
  }
});

/// Get music is offered (Soulbeet reached and logged in).
final soulbeetAvailableProvider = Provider<bool>(
  (ref) => ref.watch(soulbeetHealthProvider).valueOrNull?.downloaderOnline == true,
);

final soulbeetDownloadsProvider = ChangeNotifierProvider<SoulbeetDownloads?>((ref) {
  final client = ref.watch(soulbeetClientProvider);
  if (client == null) return null;
  return SoulbeetDownloads(
    client: client,
    rescan: () async => await ref.read(connectLinkProvider)?.client.rescan() ?? false,
    findInLibrary: (title, artist) async => (await _inLibrary(ref, title, artist))?.id,
  );
});

Future<Album?> _inLibrary(Ref ref, String title, String? artist) async {
  final client = ref.read(clientProvider);
  if (client == null) return null;
  final r = await client.search3(title, artistCount: 0, albumCount: 20, songCount: 0);
  return findLibraryAlbum(r.albums, title, artist);
}

/// The library's copy of a MusicBrainz album, if there is one.
final libraryAlbumForProvider = FutureProvider.autoDispose.family<Album?, ({String title, String artist})>(
  (ref, a) => _inLibrary(ref, a.title, a.artist),
);

/// Where Get music searches first (see [findMusic]).
final deezerClientProvider = Provider<DeezerClient>((ref) {
  final client = DeezerClient();
  ref.onDispose(client.close);
  return client;
});

/// One MusicBrainz client for the app, so its one-request-a-second pacing
/// covers every search.
final musicBrainzClientProvider = Provider<MusicBrainzClient>((ref) {
  final client = MusicBrainzClient(deezer: ref.watch(deezerClientProvider));
  ref.onDispose(client.close);
  return client;
});

/// What Deezer, else MusicBrainz, has for a Get music search (see
/// [findMusic]), filling in part by part.
final soulbeetSearchProvider = StreamProvider.autoDispose.family<GetMusicResults, String>((ref, raw) {
  if (ref.watch(soulbeetClientProvider) == null || raw.trim().isEmpty) {
    return Stream.value(const GetMusicResults(done: true));
  }
  // Typed on, or left: what this search still has waiting drops out of line.
  final cancel = MbCancel();
  ref.onDispose(cancel.cancel);
  return findMusic(ref.watch(deezerClientProvider), ref.watch(musicBrainzClientProvider), raw, cancel: cancel);
});

/// What MusicBrainz alone has for a search (see [searchGetMusic]), when
/// what Deezer found isn't it.
final musicBrainzSearchProvider = StreamProvider.autoDispose.family<GetMusicResults, String>((ref, raw) {
  if (ref.watch(soulbeetClientProvider) == null || raw.trim().isEmpty) {
    return Stream.value(const GetMusicResults(done: true));
  }
  final cancel = MbCancel();
  ref.onDispose(cancel.cancel);
  return searchGetMusic(ref.watch(musicBrainzClientProvider), raw, cancel: cancel);
});

/// What Get music suggests before anything is searched (see
/// [suggestMusic]). Kept for the session: an album downloaded from it shows
/// as downloading, then as yours.
final getMusicSuggestionsProvider = StreamProvider<MusicSuggestions>((ref) async* {
  final client = ref.watch(soulbeetClientProvider) == null ? null : ref.watch(clientProvider);
  if (client == null) {
    yield const MusicSuggestions([], done: true);
    return;
  }
  final played = await _playedArtists(ref, client, await ref.watch(mixSeedsProvider.future));
  final owned = [for (final a in await client.getArtists()) a.name];
  yield* suggestMusic(ref.watch(deezerClientProvider), played: played, owned: owned);
});

/// Whom suggestions and Discover are built around (see [suggestionSeeds]).
Future<List<String>> _playedArtists(Ref ref, SubsonicClient client, List<MixSeed> top) async => suggestionSeeds([
  for (final s in top) s.artist,
], top.isNotEmpty ? const [] : [for (final a in await client.getAlbumList2(AlbumListType.newest, size: 20)) a.artist]);

// ---- Discover (docs/DISCOVER_PLAN.md) ------------------------------------------

class DiscoverSettingsNotifier extends Notifier<DiscoverSettings> {
  static const _key = 'discover_settings';

  /// Changed since it was built: what's saved is older, so it's not loaded.
  bool _set = false;

  @override
  DiscoverSettings build() {
    ref.read(dbProvider).getJson(_key).then((j) {
      if (!_set && j != null) state = DiscoverSettings.fromJson(j);
    });
    return const DiscoverSettings();
  }

  Future<void> set(DiscoverSettings s) async {
    _set = true;
    state = s;
    await ref.read(dbProvider).setJson(_key, s.toJson());
  }
}

final discoverSettingsProvider = NotifierProvider<DiscoverSettingsNotifier, DiscoverSettings>(
  DiscoverSettingsNotifier.new,
);

/// How often Discover tops up while the app is open.
const discoverEvery = Duration(hours: 3);

/// Waits (a little) for Sonar Connect to be online, for a Discover call.
Future<ConnectClient> _online(ConnectClient c, {Duration within = const Duration(seconds: 20)}) async {
  if (c.status.value == ConnectStatus.online) return c;
  final up = Completer<void>();
  void check() {
    if (c.status.value == ConnectStatus.online && !up.isCompleted) up.complete();
  }

  c.status.addListener(check);
  try {
    await up.future.timeout(within);
  } on TimeoutException {
    throw const ConnectUnavailable('Not connected to Sonar Connect.');
  } finally {
    c.status.removeListener(check);
  }
  return c;
}

/// Discover, while logged in with Get music and Sonar Connect. Tops up when
/// Connect comes online, every [discoverEvery], and when settings make room.
final discoverProvider = ChangeNotifierProvider<Discover?>((ref) {
  // `.notifier`: the downloads themselves, not their changes. Watching the
  // provider would remake Discover on every progress event, each new one
  // starting its own top-up (seen live: the Home row flashing, and more than
  // a top-up's worth of downloads).
  final downloads = ref.watch(soulbeetDownloadsProvider.notifier);
  final link = ref.watch(connectLinkProvider);
  // Not clientProvider: it's remade when Discover sets the library's scope.
  if (downloads == null || link == null || ref.watch(sessionProvider).valueOrNull == null) return null;
  final connect = link.client;
  final db = ref.read(dbProvider);
  final discover = Discover(
    library: () => ref.read(clientProvider)!,
    server: () async => (await _online(connect)).discover(),
    keepSongs: (ids) async => (await _online(connect)).keep(ids),
    removeSongs: (ids) async => (await _online(connect)).remove(ids),
    downloads: downloads,
    deezer: ref.read(deezerClientProvider),
    musicBrainz: ref.read(musicBrainzClientProvider),
    played: () async {
      final client = ref.read(clientProvider)!;
      return _playedArtists(ref, client, await ref.read(mixSeedsProvider.future));
    },
    read: () => db.getJson('discover_state'),
    write: (state) => db.setJson('discover_state', state),
    onFolders: (folders) => ref.read(libraryFoldersProvider.notifier).set(folders),
    hidden: ref.read(libraryHiddenProvider),
    // Only where Soulbeet can download; and a phone leaves it to a PC that's
    // on, so the two don't race.
    mayTopUp: () =>
        ref.read(soulbeetAvailableProvider) &&
        (connect.me.kind == 'pc' || !connect.devices.value.values.any((d) => d.kind == 'pc')),
  )..settings = ref.read(discoverSettingsProvider);
  ref.listen(discoverSettingsProvider, (_, s) => discover.settings = s);
  var started = false;
  void online() {
    if (connect.status.value != ConnectStatus.online || started) return;
    started = true;
    // Learns the Discover library (for the library screens) even when off.
    unawaited(discover.refresh().then((_) => discover.topUp()).catchError((Object _) {}));
  }

  connect.status.addListener(online);
  online();
  final timer = Timer.periodic(discoverEvery, (_) => unawaited(discover.topUp()));
  ref.onDispose(() {
    timer.cancel();
    connect.status.removeListener(online);
    discover.dispose();
  });
  return discover;
});

/// An album found in Get music, as the pressing to download, with its songs
/// (see [MusicBrainzClient.songsOf]): usually already fetched by the search.
final albumSongsProvider = FutureProvider.autoDispose.family<SbAlbumDetail, SbAlbum>(
  (ref, album) => ref.watch(musicBrainzClientProvider).songsOf(album),
);
