import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/musicbrainz/musicbrainz_client.dart';
import '../data/soulbeet/get_music_search.dart';
import '../data/soulbeet/library_match.dart';
import '../data/soulbeet/soulbeet_client.dart';
import '../data/soulbeet/soulbeet_downloads.dart';
import '../data/soulbeet/soulbeet_models.dart';
import '../data/subsonic/models.dart';
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

/// One MusicBrainz client for the app, so its one-request-a-second pacing
/// covers every search.
final musicBrainzClientProvider = Provider<MusicBrainzClient>((ref) {
  final client = MusicBrainzClient();
  ref.onDispose(client.close);
  return client;
});

/// What MusicBrainz has for a Get music search (see [searchGetMusic]),
/// filling in part by part.
final soulbeetSearchProvider = StreamProvider.autoDispose.family<GetMusicResults, String>((ref, raw) {
  if (ref.watch(soulbeetClientProvider) == null || raw.trim().isEmpty) {
    return Stream.value(const GetMusicResults(done: true));
  }
  // Typed on, or left: what this search still has waiting drops out of line.
  final cancel = MbCancel();
  ref.onDispose(cancel.cancel);
  return searchGetMusic(ref.watch(musicBrainzClientProvider), raw, cancel: cancel);
});

/// An album found in Get music, as the pressing to download, with its songs
/// (see [MusicBrainzClient.songsOf]): usually already fetched by the search.
final albumSongsProvider = FutureProvider.autoDispose.family<SbAlbumDetail, SbAlbum>(
  (ref, album) => ref.watch(musicBrainzClientProvider).songsOf(album),
);
