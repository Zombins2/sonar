// Carrying on between devices: each app saves its queue on the server while it
// plays, and the other offers to pick up from there.

import 'subsonic/models.dart';
import 'subsonic/subsonic_client.dart';

/// How long a queue left on another device is still worth offering.
const handoffMaxAge = Duration(days: 14);

/// What to call the device that saved [clientName] (the Subsonic `c`).
String deviceName(String? clientName) => switch (clientName) {
  SubsonicClient.desktopClientName => 'your PC',
  'sonar' => 'your phone',
  null || '' => 'another device',
  final other => other,
};

/// The queue to offer here, or null. Offered when another device saved it
/// recently, it hasn't been turned down already, nothing is playing here, and
/// this device isn't already at the same spot.
PlayQueue? handoffOffer({
  required PlayQueue? server,
  required String me,
  required bool playingHere,
  String? currentHere,
  Duration positionHere = Duration.zero,
  DateTime? dismissed,
  DateTime? now,
}) {
  if (server == null || server.current == null || playingHere) return null;
  if (server.changedBy == me) return null;
  final changed = server.changed;
  if (changed == null || (now ?? DateTime.now()).difference(changed) > handoffMaxAge) return null;
  if (dismissed != null && !changed.isAfter(dismissed)) return null;
  final samePlace =
      currentHere == server.currentId && (positionHere - server.position).abs() < const Duration(seconds: 15);
  return samePlace ? null : server;
}

/// The stretch of a queue worth saving: some of what's been played, and what's
/// still to come (a very long queue would make an over-long request).
List<Song> queueToSave(List<Song> songs, int index, {int before = 50, int after = 200}) {
  if (songs.isEmpty) return const [];
  final i = index.clamp(0, songs.length - 1);
  final start = (i - before).clamp(0, songs.length);
  final end = (i + after + 1).clamp(0, songs.length);
  return songs.sublist(start, end);
}
