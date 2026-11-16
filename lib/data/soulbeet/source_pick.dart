import 'soulbeet_models.dart';

/// Lowest Soulbeet match score a copy needs before Sonar picks it itself.
const minPickScore = 0.9;

/// The copy of an album Sonar downloads: a lossless one with every track,
/// from someone who can send it soonest. Null when no copy qualifies; the
/// app then lets Soulbeet choose, which may pick a lossy copy.
///
/// [tracks] is how many songs the album has (0 when unknown).
SbSource? pickSource(Iterable<SbSource> sources, {required int tracks}) {
  final complete = [
    for (final s in sources)
      if (s.lossless && s.score >= minPickScore && s.files.isNotEmpty && (tracks <= 0 || s.itemCount >= tracks)) s,
  ];
  if (complete.isEmpty) return null;
  complete.sort(compareSources);
  return complete.first;
}

/// Best first: a free upload slot now, then a short queue, then speed, then
/// how well it matches, then no extra files (bonus tracks, other discs).
int compareSources(SbSource a, SbSource b) {
  if (a.freeSlot != b.freeSlot) return a.freeSlot ? -1 : 1;
  final queue = a.queueLength.compareTo(b.queueLength);
  if (queue != 0) return queue;
  final speed = b.uploadSpeed.compareTo(a.uploadSpeed);
  if (speed != 0) return speed;
  final score = b.score.compareTo(a.score);
  if (score != 0) return score;
  return a.itemCount.compareTo(b.itemCount);
}

String _plain(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

/// The same name, or one a longer form of the other ("BULLY" and "BULLY
/// (Deluxe)", "Chase the Devil" and "Chase the Devil feat. ..."). Names too
/// short to tell must match whole.
bool _sameName(String a, String b) =>
    a == b || (a.length >= 4 && b.length >= 4 && (a.startsWith(b) || b.startsWith(a)));

/// Where to download [songs] (titles) of [album] (a title) from: one person's
/// copy of that album with every song asked for, best first (lossless, then
/// [compareSources]). Never a compilation or another album that has the
/// songs too: beets files a song as whatever album its copy's tags say, so
/// a copy from "Reggae Hits" gets filed as "Reggae Hits". Null when nobody
/// shares one.
({SbSource source, List<SbSourceFile> files})? pickSongs(
  Iterable<SbSource> sources, {
  required String album,
  required List<String> songs,
}) {
  final want = _plain(album);
  final picks = <({SbSource source, List<SbSourceFile> files})>[];
  for (final s in sources) {
    if (want.isEmpty || !_sameName(_plain(s.title), want)) continue;
    final files = <SbSourceFile>[];
    for (final song in songs) {
      final title = _plain(song);
      final f =
          s.files.where((f) => _plain(f.title) == title).firstOrNull ??
          s.files.where((f) => _sameName(_plain(f.title), title)).firstOrNull;
      if (f == null) break;
      files.add(f);
    }
    if (songs.isNotEmpty && files.length == songs.length) picks.add((source: s, files: files));
  }
  if (picks.isEmpty) return null;
  picks.sort((a, b) {
    if (a.source.lossless != b.source.lossless) return a.source.lossless ? -1 : 1;
    return compareSources(a.source, b.source);
  });
  return picks.first;
}
