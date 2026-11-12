import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Albums on MusicBrainz for a search ("Album", or "Artist - Album").
final soulbeetAlbumSearchProvider = FutureProvider.autoDispose.family<List<SbAlbum>, String>((ref, raw) async {
  final client = ref.watch(soulbeetClientProvider);
  if (client == null || raw.trim().isEmpty) return const [];
  final (query, artist) = splitArtistQuery(raw);
  return client.searchAlbums(query, artist: artist);
});

final soulbeetAlbumDetailProvider = FutureProvider.autoDispose.family<SbAlbumDetail, String>((ref, id) {
  final client = ref.watch(soulbeetClientProvider);
  if (client == null) throw const SoulbeetException(SoulbeetErrorKind.unreachable, 'Get music is off.');
  return client.album(id);
});

/// "Peter Tosh - Legalize It" searches Legalize It by Peter Tosh; anything
/// else is the album name alone.
(String query, String? artist) splitArtistQuery(String raw) {
  final s = raw.trim();
  final m = RegExp(r'^(.+?)\s+[-–—]\s+(.+)$').firstMatch(s);
  if (m == null) return (s, null);
  return (m.group(2)!.trim(), m.group(1)!.trim());
}
