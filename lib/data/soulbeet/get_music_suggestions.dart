import '../deezer/deezer_client.dart';
import 'soulbeet_models.dart';

/// Albums Get music suggests because the listener plays [because]: one by
/// each of a few artists their listeners also play.
class SuggestionRow {
  const SuggestionRow(this.because, this.albums);
  final String because;
  final List<SbAlbum> albums;
}

/// What Get music suggests before anything is searched.
class MusicSuggestions {
  const MusicSuggestions(this.rows, {this.done = false});
  final List<SuggestionRow> rows;

  /// Every played artist has been looked at.
  final bool done;
}

String _plain(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

/// Whom suggestions are built around: the most played artists, else (before
/// anything is played) those of the albums added last. "Various Artists"
/// is no one to build around.
List<String> suggestionSeeds(List<String> mostPlayed, List<String> newest, {int max = 4}) {
  final seen = <String>{};
  return [
    for (final a in mostPlayed.isNotEmpty ? mostPlayed : newest)
      if (_plain(a) case final p when p.isNotEmpty && p != 'variousartists' && seen.add(p)) a,
  ].take(max).toList();
}

/// Music the listener doesn't have yet, around the artists they play most
/// ([played]): for each, a row of the best-known album by each of
/// [perRow] artists Deezer says their listeners also play, leaving out
/// artists already in the library ([owned], which holds the played ones),
/// under any billing ("Kirk Franklin & The Family" is Kirk Franklin), and
/// anyone already suggested. Rows fill in one played artist at a time.
///
/// Sends Deezer only artist names and ids. Navidrome's own similar songs
/// only reach songs already in the library; these reach past it.
Stream<MusicSuggestions> suggestMusic(
  DeezerClient dz, {
  required List<String> played,
  required Iterable<String> owned,
  int perRow = 6,
}) async* {
  final have = {for (final a in owned) _plain(a)}..remove('');
  final seeds = {for (final p in played) _plain(p): p}..remove('');
  final shown = <String>{};
  final rows = <SuggestionRow>[];
  for (final MapEntry(key: want, value: seed) in seeds.entries) {
    try {
      final artist = (await dz.searchArtists(seed)).where((a) => _plain(a.name) == want).firstOrNull;
      if (artist == null) continue;
      final picks = <DeezerArtist>[];
      for (final r in await dz.related(artist)) {
        final name = _plain(r.name);
        if (name.isEmpty || shown.contains(name)) continue;
        if (have.any((h) => _sameAct(name, h))) continue;
        picks.add(r);
        if (picks.length == perRow) break;
      }
      final albums = await Future.wait(picks.map((r) => _bestAlbum(dz, r)));
      final row = [for (final a in albums) ?a];
      if (row.isEmpty) continue;
      shown.addAll(picks.map((r) => _plain(r.name)));
      rows.add(SuggestionRow(seed, row));
      yield MusicSuggestions(List.of(rows));
    } on DeezerException {
      // This artist's row is left out; the others may still come.
    }
  }
  yield MusicSuggestions(rows, done: true);
}

/// One act billed two ways: "Kirk Franklin & The Family" is Kirk Franklin.
/// Names too short to tell ("Ye") must match whole.
bool _sameAct(String a, String b) => a == b || (a.length >= 4 && b.length >= 4 && (a.startsWith(b) || b.startsWith(a)));

/// Deezer lists many hits sets as plain albums ("Best Of").
final _hits = RegExp(
  r'\b(best of|greatest|hits|anthology|collection|essential|definitive|gold|retrospective)\b',
  caseSensitive: false,
);

/// [artist]'s most followed album, a studio one before a compilation or a
/// hits set.
Future<SbAlbum?> _bestAlbum(DeezerClient dz, DeezerArtist artist) async {
  try {
    final albums = await dz.albumsBy(artist);
    return albums.where((a) => a.kinds.isEmpty && !_hits.hasMatch(a.title)).firstOrNull ?? albums.firstOrNull;
  } on DeezerException {
    return null;
  }
}
