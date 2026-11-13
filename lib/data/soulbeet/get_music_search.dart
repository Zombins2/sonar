import 'dart:async';
import 'dart:math' as math;

import '../musicbrainz/musicbrainz_client.dart';
import 'soulbeet_models.dart';

/// The search is an artist's name: their card, at the top.
class TopArtist {
  const TopArtist(this.name, this.cover);

  /// "Ye (Kanye West)": as MusicBrainz names them, and as searched.
  final String name;

  /// Their most listened album, for its cover.
  final SbAlbum? cover;
}

/// What a Get music search found, part by part. A search fills in as each
/// part comes back, and is [done] once they all have.
///
/// Each list is in order of how many people listen to it on ListenBrainz.
/// [isFiller] marks what hardly anyone wants next to the best match (the
/// lullaby and string-quartet tributes under "kanye west", compilations and
/// live albums few play), for the screen to keep behind "See all", as a
/// music app does.
class GetMusicResults {
  const GetMusicResults({
    this.query = '',
    this.albums = const [],
    this.songs = const [],
    this.byArtist = const [],
    this.artist,
    this.respelled,
    this.listeners = const {},
    this.done = false,
  });

  /// What was searched for: the album or song name, without "Artist - ".
  final String query;

  /// Albums with the name searched for.
  final List<SbAlbum> albums;

  /// Songs with the name searched for, each on an album ([SbTrack.onAlbum]).
  final List<SbTrack> songs;

  /// Albums by [artist], when the whole search is an artist's name.
  final List<SbAlbum> byArtist;

  /// The artist [byArtist] are by, as MusicBrainz names them, with the name
  /// searched when that's another of theirs: "Ye (Kanye West)".
  final String? artist;

  /// The search in its other spelling ("pure colour"), searched as well.
  final String? respelled;

  /// Listeners on ListenBrainz, by album release group and by song id.
  final Map<String, int> listeners;

  final bool done;

  bool get isEmpty => albums.isEmpty && songs.isEmpty && byArtist.isEmpty;

  /// Listeners of an [SbAlbum] or [SbTrack]; 0 when unknown.
  int listenersOf(Object found) =>
      (found is SbAlbum ? listeners[found.groupId] : listeners[(found as SbTrack).id]) ?? 0;

  /// The most listened-to thing found.
  int get top => [
    for (final a in albums) listenersOf(a),
    for (final a in byArtist) listenersOf(a),
    for (final s in songs) listenersOf(s),
  ].fold(0, math.max);

  /// Under 1% of the listeners of the best match: almost certainly not
  /// what was searched for. Nothing is minor until listeners are known.
  bool isMinor(Object found) => listenersOf(found) * 100 < top;

  /// Kept out of the way until asked for: minor, or a compilation, live,
  /// remix or similar album, or one by "Various Artists", under 10% of the
  /// best match's listeners.
  bool isFiller(Object found) {
    if (isMinor(found)) return true;
    if (found is! SbAlbum) return false;
    final side = found.kinds.isNotEmpty || found.artist.toLowerCase() == 'various artists';
    return side && listenersOf(found) * 10 < top;
  }

  /// Every album found, by name and by the artist, once each, most listened first.
  List<SbAlbum> get allAlbums {
    final seen = <String>{};
    final all = [
      for (final a in [...albums, ...byArtist])
        if (seen.add(a.groupId ?? a.id)) a,
    ];
    final order = {for (final (i, a) in all.indexed) a: i};
    return all..sort((a, b) {
      final c = listenersOf(b).compareTo(listenersOf(a));
      return c != 0 ? c : order[a]!.compareTo(order[b]!);
    });
  }

  /// The one result most likely wanted, as a music app puts it first: the
  /// most listened of the albums and songs with exactly the name searched,
  /// and the artist with that name ([TopArtist], weighed by their most
  /// listened album); else the most listened of all. Null when nothing was
  /// found.
  Object? get topResult {
    final want = _plain(query);
    final named = [
      for (final x in <Object>[...albums, ...songs])
        if (_plain(x is SbAlbum ? x.title : (x as SbTrack).title) == want) x,
    ];
    final best = named.isEmpty ? null : _most(named);
    if (artist != null && byArtist.isNotEmpty) {
      final cover = _most(byArtist);
      if (best == null || listenersOf(cover) >= listenersOf(best)) return TopArtist(artist!, cover);
    }
    if (best != null) return best;
    final all = <Object>[...albums, ...songs];
    return all.isEmpty ? null : _most(all);
  }

  T _most<T extends Object>(List<T> found) => found.reduce((a, b) => listenersOf(b) > listenersOf(a) ? b : a);

  static String _plain(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

  GetMusicResults _with({
    List<SbAlbum>? albums,
    List<SbTrack>? songs,
    List<SbAlbum>? byArtist,
    String? artist,
    Map<String, int>? listeners,
    bool? done,
  }) => GetMusicResults(
    query: query,
    albums: albums ?? this.albums,
    songs: songs ?? this.songs,
    byArtist: byArtist ?? this.byArtist,
    artist: artist ?? this.artist,
    respelled: respelled,
    listeners: listeners ?? this.listeners,
    done: done ?? this.done,
  );

  /// Adds listener counts, and puts every list in their order.
  GetMusicResults _ranked(Map<String, int> more) {
    final all = {...listeners, ...more};
    List<T> rank<T>(List<T> found) {
      int of(T x) => (x is SbAlbum ? all[x.groupId] : all[(x as SbTrack).id]) ?? 0;
      final order = {for (final (i, x) in found.indexed) x: i};
      return [...found]..sort((a, b) {
        final c = of(b).compareTo(of(a));
        return c != 0 ? c : order[a]!.compareTo(order[b]!);
      });
    }

    return _with(albums: rank(albums), songs: rank(songs), byArtist: rank(byArtist), listeners: all);
  }
}

/// Searches MusicBrainz for [raw] ("Album", "Song", "Artist", or "Artist -
/// Album") and ranks what it finds by listeners on ListenBrainz:
///
/// - albums with that name;
/// - songs with that name, each on the album it's best found on ("Pure
///   Colour" is a song on Steve Lacy's "Oh yeah?");
/// - a name alone is also looked up as an artist, by any name they go by,
///   ignoring spaces ("jpeg mafia" is JPEGMAFIA, "kanye west" is Ye), and
///   all their albums listed, and their popular songs: the most listened on
///   their most listened albums;
/// - "X - Y" is read both ways round, artist first or song first;
/// - several words are also searched as a song or album and its artist run
///   together, in either order ("sky is the limit rebelution");
/// - words spelled differently in US and UK English are searched both ways
///   ("pure color" also finds "pure colour").
///
/// Every request is put in line at once, the albums and the artist first,
/// so MusicBrainz's one-a-second pace never waits on anything else, and each
/// part is yielded as it lands. Once done, the likeliest albums' songs are
/// fetched ahead, when nothing else waits, so opening one is instant.
///
/// [cancel] drops what's still waiting (the user typed on, or left). Only
/// the album search failing fails the search; a later part that fails is
/// left out.
Stream<GetMusicResults> searchGetMusic(MusicBrainzClient mb, String raw, {MbCancel? cancel}) async* {
  final (query, artist) = splitArtistQuery(raw);
  if (query.isEmpty) {
    yield const GetMusicResults(done: true);
    return;
  }
  final c = cancel ?? MbCancel();
  Future<GetMusicResults> ranked(
    GetMusicResults r, {
    List<SbAlbum> albums = const [],
    List<SbTrack> songs = const [],
  }) async =>
      r._ranked(await mb.listeners(albums: albums.map((a) => a.groupId).nonNulls, songs: songs.map((s) => s.id)));

  final other = respell(query);
  const soon = MbTurn.soon;
  final albumsAsked = mb.searchAlbums(query, artist: artist, cancel: c);
  final artistsAsked = artist == null ? _orNone(mb.findArtists(query, cancel: c)) : Future.value(const <MbArtist>[]);
  final loose = artist == null && query.contains(RegExp(r'\s'));
  // The songs, and more ways of reading what was typed, each merged in as
  // it lands, in the order asked: several words as a song (or album) and
  // its artist run together ("sky is the limit rebelution"), first, as the
  // likeliest way a song is typed; the song by name; "Song - Artist" as
  // well as "Artist - Song"; the other spelling. (Asked "soon": an artist's
  // albums and popular songs, asked "now" once they're known, go first.)
  final more = <(Future<List<SbTrack>>?, Future<List<SbAlbum>>?)>[
    if (loose) (_orNone(mb.searchSongsLoosely(query, turn: soon, cancel: c)), null),
    (_orNone(mb.searchSongs(query, artist: artist, turn: soon, cancel: c)), null),
    if (loose) (null, _orNone(mb.searchAlbumsLoosely(query, turn: soon, cancel: c))),
    if (artist != null)
      (
        _orNone(mb.searchSongs(artist, artist: query, turn: soon, cancel: c)),
        _orNone(mb.searchAlbums(artist, artist: query, turn: soon, cancel: c)),
      ),
    if (other != null)
      (
        _orNone(mb.searchSongs(other, artist: artist, turn: soon, cancel: c)),
        _orNone(mb.searchAlbums(other, artist: artist, turn: soon, cancel: c)),
      ),
  ];

  final List<SbAlbum> albums;
  try {
    albums = await albumsAsked;
  } on Object {
    c.cancel();
    rethrow;
  }
  var r = await ranked(
    GetMusicResults(
      query: query,
      albums: albums,
      respelled: other == null ? null : (artist == null ? other : '$artist - $other'),
    ),
    albums: albums,
  );
  yield r;

  // A name alone: the artist next, as the likeliest thing wanted.
  if (artist == null) {
    final artists = await artistsAsked;
    final first = artists.firstOrNull;
    var byArtist = <SbAlbum>[];
    for (final a in artists) {
      byArtist = _merge(byArtist, await _orNone(mb.albumsBy(a, cancel: c)));
    }
    if (c.cancelled) return;
    final name = first == null ? null : (first.matchedAs == null ? first.name : '${first.name} (${first.matchedAs})');
    r = await ranked(
      r._with(byArtist: _notIn(byArtist, r.albums), artist: byArtist.isEmpty ? null : name),
      albums: byArtist,
    );
    yield r;

    // Their popular songs: the most listened on their most listened albums,
    // listed as each album's songs land. (Those albums are the likeliest
    // opened, so this also fetches them ahead.)
    final onTop = <SbTrack>[];
    for (final album in r.byArtist.take(popularFrom)) {
      final SbAlbumDetail detail;
      try {
        detail = await mb.songsOf(album, cancel: c);
      } on Object {
        if (c.cancelled) return;
        continue;
      }
      onTop.addAll(detail.tracks);
      final listened = await mb.listeners(songs: onTop.map((s) => s.id));
      if (c.cancelled) return;
      final popular = pickPopular(onTop, listened);
      if (popular.isEmpty) continue;
      r = await ranked(r._with(songs: popular), songs: popular);
      yield r;
    }
  }

  for (final (songsAsked, albumsAsked) in more) {
    final moreSongs = songsAsked == null ? const <SbTrack>[] : _songs(await songsAsked);
    if (c.cancelled) return;
    if (moreSongs.isNotEmpty) {
      r = await ranked(r._with(songs: _merge(r.songs, moreSongs)), songs: moreSongs);
      yield r;
    }
    final moreAlbums = albumsAsked == null ? const <SbAlbum>[] : await albumsAsked;
    if (c.cancelled) return;
    if (moreAlbums.isNotEmpty) {
      final albums = _merge(r.albums, moreAlbums);
      r = await ranked(
        r._with(albums: albums, byArtist: _notIn(r.byArtist, albums)),
        albums: moreAlbums,
      );
      yield r;
    }
  }

  r = r._with(done: true);
  // The albums likeliest to be opened: their songs, ahead of time.
  final top = r.topResult;
  final likely = <SbAlbum>{
    if (top is SbAlbum) top,
    if (top is SbTrack && top.onAlbum != null) top.onAlbum!,
    ...r.allAlbums.where((a) => !r.isFiller(a)).take(3),
  };
  for (final a in likely) {
    unawaited(mb.songsOf(a, turn: MbTurn.spare, cancel: c).then((_) {}, onError: (_) {}));
  }
  yield r;
}

/// How many of an artist's most listened albums their popular songs are
/// picked from, and how many popular songs are listed.
const popularFrom = 3, popularSongs = 10;

/// The [popularSongs] most listened of [songs], one of each title (an album
/// and its deluxe pressing both have "Stronger"), none nobody has listened
/// to (ListenBrainz not answering means none are known).
List<SbTrack> pickPopular(List<SbTrack> songs, Map<String, int> listened) {
  final ranked = [
    for (final s in songs)
      if ((listened[s.id] ?? 0) > 0) s,
  ]..sort((a, b) => listened[b.id]!.compareTo(listened[a.id]!));
  final titles = <String>{};
  return [
    for (final s in ranked)
      if (titles.add(s.title.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), ''))) s,
  ].take(popularSongs).toList();
}

/// An artist's albums less those already listed by name (one album, any pressing).
List<SbAlbum> _notIn(List<SbAlbum> byArtist, List<SbAlbum> listed) {
  final groups = {for (final a in listed) a.groupId ?? a.id};
  return [
    for (final a in byArtist)
      if (!groups.contains(a.groupId ?? a.id)) a,
  ];
}

/// [asked], or nothing if it fails (or was dropped).
Future<List<T>> _orNone<T>(Future<List<T>> asked) => asked.then((v) => v, onError: (_) => <T>[]);

/// The songs that can be opened: those on an album.
List<SbTrack> _songs(List<SbTrack> songs) => [
  for (final s in songs)
    if (s.onAlbum != null) s,
];

List<T> _merge<T>(List<T> first, List<T> more) {
  String id(T x) => x is SbAlbum ? x.id : (x as SbTrack).id;
  final seen = {for (final x in first) id(x)};
  return [
    ...first,
    for (final x in more)
      if (seen.add(id(x))) x,
  ];
}

/// "Peter Tosh - Legalize It" searches Legalize It by Peter Tosh; anything
/// else is the name alone.
(String query, String? artist) splitArtistQuery(String raw) {
  final s = raw.trim();
  final m = RegExp(r'^(.+?)\s+[-–—]\s+(.+)$').firstMatch(s);
  if (m == null) return (s, null);
  return (m.group(2)!.trim(), m.group(1)!.trim());
}

/// [text] with its words in the other of US and UK spelling ("pure color"
/// becomes "pure colour", "Grey Skies" becomes "Gray Skies"), or null when
/// no word is spelled differently. MusicBrainz has each name one way only.
String? respell(String text) {
  var changed = false;
  final out = text.replaceAllMapped(RegExp(r'\p{L}+', unicode: true), (m) {
    final word = m[0]!;
    final lower = word.toLowerCase();
    for (final (us, uk) in _usUk) {
      // The UK form first: "catalogue" starts with "catalog" too.
      final (from, to) = lower.startsWith(uk)
          ? (uk, us)
          : lower.startsWith(us)
          ? (us, uk)
          : (null, null);
      if (from == null || to == null) continue;
      changed = true;
      return _sameCase(word, to + lower.substring(from.length));
    }
    return word;
  });
  return changed ? out : null;
}

String _sameCase(String like, String word) {
  if (like.length > 1 && like == like.toUpperCase()) return word.toUpperCase();
  if (like[0] != like[0].toLowerCase()) return word[0].toUpperCase() + word.substring(1);
  return word;
}

/// Starts of words spelled differently (US, UK). A start also catches the
/// longer words ("colorful", "favorite").
const _usUk = [
  ('color', 'colour'),
  ('favor', 'favour'),
  ('honor', 'honour'),
  ('neighbor', 'neighbour'),
  ('harbor', 'harbour'),
  ('flavor', 'flavour'),
  ('labor', 'labour'),
  ('humor', 'humour'),
  ('rumor', 'rumour'),
  ('armor', 'armour'),
  ('savior', 'saviour'),
  ('behavior', 'behaviour'),
  ('vapor', 'vapour'),
  ('valor', 'valour'),
  ('splendor', 'splendour'),
  ('endeavor', 'endeavour'),
  ('odor', 'odour'),
  ('parlor', 'parlour'),
  ('gray', 'grey'),
  ('center', 'centre'),
  ('theater', 'theatre'),
  ('fiber', 'fibre'),
  ('somber', 'sombre'),
  ('specter', 'spectre'),
  ('defense', 'defence'),
  ('offense', 'offence'),
  ('catalog', 'catalogue'),
  ('dialog', 'dialogue'),
  ('jewelry', 'jewellery'),
  ('pajama', 'pyjama'),
  ('aluminum', 'aluminium'),
  ('mustache', 'moustache'),
];
