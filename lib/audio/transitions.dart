// How one track hands over to the next: crossfade timing and volume levelling.
// Pure logic, so it can be tested without a player.

import 'dart:math';

import '../data/subsonic/models.dart';
import 'playback_source.dart';

/// Crossfade lengths offered in Settings, in seconds (0 = off).
const crossfadeMax = 12;

/// True when [next] is simply the following track of the same album, which
/// must run on without a fade (live albums, DJ mixes, segues).
bool continuesAlbum(Song current, Song next) {
  if (current.albumId == null || current.albumId != next.albumId) return false;
  final track = current.track;
  if (track == null || next.track == null) return false;
  final disc = current.discNumber ?? 1;
  final nextDisc = next.discNumber ?? 1;
  return (nextDisc == disc && next.track == track + 1) || (nextDisc == disc + 1 && next.track == 1);
}

bool shouldCrossfade({
  required int seconds,
  required Song current,
  required Song? next,
  required bool repeatOne,
  required bool stopAfterTrack,
}) => seconds > 0 && next != null && !repeatOne && !stopAfterTrack && !continuesAlbum(current, next);

/// The fade length for a track: the setting, but never more than a quarter of
/// a short track. Zero means too short to fade.
int fadeSecondsFor(Duration length, int seconds) => min(seconds, length.inSeconds ~/ 4);

/// Where the fade starts, on a whole second (a transcoded stream can only be
/// started at whole seconds). Null when the track is too short to fade.
Duration? crossfadeStart(Duration length, int seconds) {
  final fade = fadeSecondsFor(length, seconds);
  if (fade < 1) return null;
  return Duration(seconds: (length - Duration(seconds: fade)).inSeconds);
}

/// Equal-power levels `(outgoing, incoming)` at fraction [t] of the fade, so
/// the overall loudness holds steady through the middle.
(double, double) crossfadeLevels(double t) {
  final x = t.clamp(0.0, 1.0) * pi / 2;
  return (cos(x), sin(x));
}

/// Album gain keeps an album's quiet and loud songs as the artist mixed them;
/// anything else (playlists, shuffle, radio) levels song by song.
bool preferAlbumGain(PlaybackSource? source, {required bool shuffled}) => source?.kind == SourceKind.album && !shuffled;

/// Player volume (0–1) that applies a track's ReplayGain. The player can only
/// turn down, so tracks quieter than the reference play at full volume.
double levelledVolume(ReplayGain? gain, {required bool album}) {
  final db = album ? gain?.albumGain ?? gain?.trackGain : gain?.trackGain ?? gain?.albumGain;
  if (db == null) return 1;
  return pow(10, db / 20).toDouble().clamp(0.0, 1.0);
}
