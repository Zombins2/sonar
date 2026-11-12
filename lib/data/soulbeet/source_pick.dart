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
