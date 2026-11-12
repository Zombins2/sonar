// Recommendations built from what the server already knows: play counts (the
// app scrobbles every play) and its Last.fm agent's similar songs and artists.
// Everything suggested is in the library, so all of it can play.

import 'dart:math';

import 'subsonic/models.dart';
import 'subsonic/subsonic_client.dart';

/// [songs] without repeats or anything in [exclude], first copy kept.
List<Song> uniqueSongs(Iterable<Song> songs, {Iterable<String> exclude = const []}) {
  final seen = {...exclude};
  return [
    for (final s in songs)
      if (seen.add(s.id)) s,
  ];
}

/// Reorders [songs] so the same artist doesn't play twice in a row where that
/// can be avoided, otherwise keeping the order.
List<Song> spreadArtists(List<Song> songs) {
  final rest = List.of(songs);
  final out = <Song>[];
  while (rest.isNotEmpty) {
    final last = out.isEmpty ? null : out.last.artist;
    final i = rest.indexWhere((s) => s.artist != last);
    out.add(rest.removeAt(i < 0 ? 0 : i));
  }
  return out;
}

/// Mixes [top] into [others], one in every [every] songs, starting with the first.
List<Song> interleave(List<Song> top, List<Song> others, {int every = 3}) {
  final out = <Song>[];
  var t = 0, o = 0;
  while (t < top.length || o < others.length) {
    if (t < top.length && (out.length % every == 0 || o >= others.length)) {
      out.add(top[t++]);
    } else {
      out.add(others[o++]);
    }
  }
  return out;
}

/// A queue that starts on [seed] and carries on with songs like it.
Future<List<Song>> songRadio(SubsonicClient client, Song seed, {int size = 60}) async {
  var similar = await client.getSimilarSongs2(seed.id, count: size);
  // No match for the track itself (obscure B-side): go by the artist instead.
  if (similar.isEmpty && seed.artistId != null) similar = await client.getSimilarSongs2(seed.artistId!, count: size);
  if (similar.isEmpty) similar = await client.getRandomSongs(size: size);
  return [
    seed,
    ...spreadArtists(uniqueSongs(similar, exclude: [seed.id])),
  ].take(size).toList();
}

/// The artist's best-known songs mixed through songs by similar artists.
Future<List<Song>> artistRadio(SubsonicClient client, String artistId, String artistName, {int size = 60}) async {
  final (top, similar) = await (
    client.getTopSongs(artistName, count: 10),
    client.getSimilarSongs2(artistId, count: size),
  ).wait;
  final songs = uniqueSongs(interleave(top, similar));
  if (songs.isEmpty) return client.getRandomSongs(size: size);
  return spreadArtists(songs).take(size).toList();
}

/// An artist the listener plays a lot, which a "Made for you" mix is built around.
class MixSeed {
  const MixSeed({required this.artistId, required this.artist, this.coverArt});
  final String artistId;
  final String artist;

  /// Art of their most played album.
  final String? coverArt;
}

/// The most played artists, by summing album play counts.
List<MixSeed> topArtists(List<Album> albums, {int max = 4}) {
  final plays = <String, int>{};
  final seeds = <String, MixSeed>{};
  for (final a in albums) {
    final id = a.artistId;
    if (id == null || a.playCount <= 0) continue;
    plays[id] = (plays[id] ?? 0) + a.playCount;
    // Albums come most played first, so the first one seen supplies the art.
    seeds.putIfAbsent(id, () => MixSeed(artistId: id, artist: a.artist, coverArt: a.coverArt));
  }
  final ids = plays.keys.toList()..sort((x, y) => plays[y]!.compareTo(plays[x]!));
  return [for (final id in ids.take(max)) seeds[id]!];
}

/// Same input, same order: a mix keeps its shape through the day and changes overnight.
Random dailyRandom(String key, [DateTime? now]) {
  final d = now ?? DateTime.now();
  var h = d.year * 10000 + d.month * 100 + d.day;
  for (final c in key.codeUnits) {
    h = (h * 31 + c) & 0x3fffffff;
  }
  return Random(h);
}

/// A day's mix around one artist: a third their own top songs, the rest
/// similar artists, shuffled.
Future<List<Song>> artistMix(SubsonicClient client, MixSeed seed, {int size = 30, DateTime? now}) async {
  final random = dailyRandom(seed.artistId, now);
  final (top, similar) = await (
    client.getTopSongs(seed.artist, count: 20),
    client.getSimilarSongs2(seed.artistId, count: 60),
  ).wait;
  final own = (List.of(top)..shuffle(random)).take(size ~/ 3).toList();
  final others = uniqueSongs(similar, exclude: own.map((s) => s.id)).where((s) => s.artistId != seed.artistId).toList()
    ..shuffle(random);
  final songs = uniqueSongs(interleave(own, others)).take(size).toList();
  return spreadArtists(songs);
}

String mixTitle(MixSeed seed) => '${seed.artist} Mix';

/// "Artist, X, Y and more": who a mix leans on.
String mixSubtitle(MixSeed seed, List<Song> songs) {
  final counts = <String, int>{};
  for (final s in songs) {
    if (s.artist.isNotEmpty && s.artist != seed.artist) counts[s.artist] = (counts[s.artist] ?? 0) + 1;
  }
  final names = counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  if (names.isEmpty) return seed.artist;
  return '${seed.artist}, ${names.take(2).join(', ')}${names.length > 2 ? ' and more' : ''}';
}

/// Albums played a lot, but not lately.
List<Album> rediscover(List<Album> frequent, List<Album> recent, {int max = 12}) {
  final lately = recent.map((a) => a.id).toSet();
  return frequent.where((a) => a.playCount > 0 && !lately.contains(a.id)).take(max).toList();
}

/// Albums nobody has played yet.
List<Album> unplayed(List<Album> albums, {int max = 12}) => albums.where((a) => a.playCount == 0).take(max).toList();

/// Whether to top up the queue: on its last track, nothing set to repeat.
bool shouldAutoplay({required bool enabled, required bool repeating, required int index, required int length}) =>
    enabled && !repeating && length > 0 && index == length - 1;

/// What autoplay appends: similar songs not already in the queue.
List<Song> autoplayPicks(List<Song> similar, List<Song> queue, {int max = 20}) =>
    spreadArtists(uniqueSongs(similar, exclude: queue.map((s) => s.id))).take(max).toList();
