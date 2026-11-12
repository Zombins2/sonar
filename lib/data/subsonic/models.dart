// Typed models for the Subsonic / OpenSubsonic JSON responses Navidrome sends.
// Parsing is defensive: Navidrome omits fields freely, so everything optional
// falls back to a sensible empty value.

typedef Json = Map<String, dynamic>;

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
int? _intOrNull(Object? v) => v == null ? null : _int(v);
String _str(Object? v) => v == null ? '' : '$v';
String? _strOrNull(Object? v) => v == null ? null : '$v';
DateTime? _date(Object? v) => v == null ? null : DateTime.tryParse('$v');

List<Json> jsonList(Object? v) {
  if (v is List) return v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  if (v is Map) return [v.cast<String, dynamic>()];
  return const [];
}

double? _doubleOrNull(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');

/// OpenSubsonic `replayGain`: loudness corrections in dB from the file's tags.
class ReplayGain {
  const ReplayGain({this.trackGain, this.albumGain});
  final double? trackGain;
  final double? albumGain;

  /// Null when the tags are missing (Navidrome sends an empty object or zeros).
  static ReplayGain? fromJson(Object? v) {
    if (v is! Map) return null;
    final track = _doubleOrNull(v['trackGain']);
    final album = _doubleOrNull(v['albumGain']);
    if ((track ?? 0) == 0 && (album ?? 0) == 0) return null;
    return ReplayGain(trackGain: track, albumGain: album);
  }

  Json toJson() => {'trackGain': trackGain, 'albumGain': albumGain};
}

class Song {
  const Song({
    required this.id,
    required this.title,
    this.album = '',
    this.albumId,
    this.artist = '',
    this.artistId,
    this.track,
    this.discNumber,
    this.duration = Duration.zero,
    this.coverArt,
    this.suffix,
    this.bitRate,
    this.year,
    this.starred = false,
    this.replayGain,
  });

  final String id;
  final String title;
  final String album;
  final String? albumId;
  final String artist;
  final String? artistId;
  final int? track;
  final int? discNumber;
  final Duration duration;
  final String? coverArt;
  final String? suffix;
  final int? bitRate;
  final int? year;
  final bool starred;
  final ReplayGain? replayGain;

  factory Song.fromJson(Json j) => Song(
    id: _str(j['id']),
    title: _str(j['title']),
    album: _str(j['album']),
    albumId: _strOrNull(j['albumId']),
    artist: _str(j['artist']),
    artistId: _strOrNull(j['artistId']),
    track: _intOrNull(j['track']),
    discNumber: _intOrNull(j['discNumber']),
    duration: Duration(seconds: _int(j['duration'])),
    coverArt: _strOrNull(j['coverArt']),
    suffix: _strOrNull(j['suffix']),
    bitRate: _intOrNull(j['bitRate']),
    year: _intOrNull(j['year']),
    starred: j['starred'] != null,
    replayGain: ReplayGain.fromJson(j['replayGain']),
  );

  Json toJson() => {
    'id': id,
    'title': title,
    'album': album,
    'albumId': albumId,
    'artist': artist,
    'artistId': artistId,
    'track': track,
    'discNumber': discNumber,
    'duration': duration.inSeconds,
    'coverArt': coverArt,
    'suffix': suffix,
    'bitRate': bitRate,
    'year': year,
    if (starred) 'starred': true,
    if (replayGain != null) 'replayGain': replayGain!.toJson(),
  };

  Song copyWith({bool? starred}) => Song(
    id: id,
    title: title,
    album: album,
    albumId: albumId,
    artist: artist,
    artistId: artistId,
    track: track,
    discNumber: discNumber,
    duration: duration,
    coverArt: coverArt,
    suffix: suffix,
    bitRate: bitRate,
    year: year,
    starred: starred ?? this.starred,
    replayGain: replayGain,
  );
}

class Album {
  const Album({
    required this.id,
    required this.name,
    this.artist = '',
    this.artistId,
    this.coverArt,
    this.songCount = 0,
    this.duration = Duration.zero,
    this.year,
    this.created,
    this.playCount = 0,
    this.starred = false,
    this.songs = const [],
  });

  final String id;
  final String name;
  final String artist;
  final String? artistId;
  final String? coverArt;
  final int songCount;
  final Duration duration;
  final int? year;
  final DateTime? created;
  final int playCount;
  final bool starred;
  final List<Song> songs;

  factory Album.fromJson(Json j) => Album(
    id: _str(j['id']),
    name: _str(j['name'] ?? j['title']),
    artist: _str(j['artist']),
    artistId: _strOrNull(j['artistId']),
    coverArt: _strOrNull(j['coverArt']),
    songCount: _int(j['songCount']),
    duration: Duration(seconds: _int(j['duration'])),
    year: _intOrNull(j['year']),
    created: _date(j['created']),
    playCount: _int(j['playCount']),
    starred: j['starred'] != null,
    songs: jsonList(j['song']).map(Song.fromJson).toList(),
  );
}

class Artist {
  const Artist({
    required this.id,
    required this.name,
    this.albumCount = 0,
    this.coverArt,
    this.artistImageUrl,
    this.starred = false,
    this.albums = const [],
  });

  final String id;
  final String name;
  final int albumCount;
  final String? coverArt;
  final String? artistImageUrl;
  final bool starred;
  final List<Album> albums;

  factory Artist.fromJson(Json j) => Artist(
    id: _str(j['id']),
    name: _str(j['name']),
    albumCount: _int(j['albumCount']),
    coverArt: _strOrNull(j['coverArt']),
    artistImageUrl: _strOrNull(j['artistImageUrl']),
    starred: j['starred'] != null,
    albums: jsonList(j['album']).map(Album.fromJson).toList(),
  );
}

/// The parts of getArtistInfo2 the app uses. Navidrome only lists similar
/// artists that are in the library unless asked otherwise.
class ArtistInfo {
  const ArtistInfo({this.similarArtists = const []});
  final List<Artist> similarArtists;

  factory ArtistInfo.fromJson(Json j) => ArtistInfo(
    similarArtists: jsonList(j['similarArtist']).map(Artist.fromJson).where((a) => a.id.isNotEmpty).toList(),
  );
}

class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    this.songCount = 0,
    this.duration = Duration.zero,
    this.coverArt,
    this.owner,
    this.comment,
    this.changed,
    this.songs = const [],
  });

  final String id;
  final String name;
  final int songCount;
  final Duration duration;
  final String? coverArt;
  final String? owner;
  final String? comment;
  final DateTime? changed;
  final List<Song> songs;

  factory Playlist.fromJson(Json j) => Playlist(
    id: _str(j['id']),
    name: _str(j['name']),
    songCount: _int(j['songCount']),
    duration: Duration(seconds: _int(j['duration'])),
    coverArt: _strOrNull(j['coverArt']),
    owner: _strOrNull(j['owner']),
    comment: _strOrNull(j['comment']),
    changed: _date(j['changed']),
    songs: jsonList(j['entry']).map(Song.fromJson).toList(),
  );
}

/// The queue a device last saved on the server (savePlayQueue), so another
/// device can carry on from it.
class PlayQueue {
  const PlayQueue({required this.songs, this.currentId, this.position = Duration.zero, this.changed, this.changedBy});
  final List<Song> songs;
  final String? currentId;
  final Duration position;
  final DateTime? changed;

  /// The client name of the app that saved it.
  final String? changedBy;

  Song? get current => songs.where((s) => s.id == currentId).firstOrNull;
  int get currentIndex => songs.indexWhere((s) => s.id == currentId).clamp(0, songs.isEmpty ? 0 : songs.length - 1);

  factory PlayQueue.fromJson(Json j) => PlayQueue(
    songs: jsonList(j['entry']).map(Song.fromJson).toList(),
    currentId: _strOrNull(j['current']),
    position: Duration(milliseconds: _int(j['position'])),
    changed: _date(j['changed']),
    changedBy: _strOrNull(j['changedBy']),
  );
}

class Genre {
  const Genre({required this.name, this.songCount = 0, this.albumCount = 0});
  final String name;
  final int songCount;
  final int albumCount;

  factory Genre.fromJson(Json j) =>
      Genre(name: _str(j['value'] ?? j['name']), songCount: _int(j['songCount']), albumCount: _int(j['albumCount']));
}

class SearchResult {
  const SearchResult({this.artists = const [], this.albums = const [], this.songs = const []});

  final List<Artist> artists;
  final List<Album> albums;
  final List<Song> songs;

  bool get isEmpty => artists.isEmpty && albums.isEmpty && songs.isEmpty;

  factory SearchResult.fromJson(Json j) => SearchResult(
    artists: jsonList(j['artist']).map(Artist.fromJson).toList(),
    albums: jsonList(j['album']).map(Album.fromJson).toList(),
    songs: jsonList(j['song']).map(Song.fromJson).toList(),
  );
}

class LyricLine {
  const LyricLine(this.text, [this.start]);
  final String text;
  final Duration? start;
}

class Lyrics {
  const Lyrics({required this.synced, required this.lines, this.credit});
  final bool synced;
  final List<LyricLine> lines;

  /// Where they came from, when that's not the user's own server.
  final String? credit;

  static final _lrcStamp = RegExp(r'\[(\d+):(\d{1,2}(?:[.:]\d{1,3})?)\]');
  static final _wordStamp = RegExp(r'<\d+:\d{1,2}(?:[.:]\d{1,3})?>');

  /// Parses LRC text (`[mm:ss.xx] words`). A line may carry several stamps
  /// (repeated choruses); `[ar:...]`-style metadata and inline word timings
  /// are dropped. Null when nothing in it is timed.
  static Lyrics? fromLrc(String text, {String? credit}) {
    final lines = <LyricLine>[];
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final stamps = _lrcStamp.allMatches(raw).toList();
      if (stamps.isEmpty) continue;
      final words = raw.substring(stamps.last.end).replaceAll(_wordStamp, '').trim();
      for (final m in stamps) {
        final seconds = double.parse(m[2]!.replaceFirst(':', '.'));
        lines.add(LyricLine(words, Duration(milliseconds: int.parse(m[1]!) * 60000 + (seconds * 1000).round())));
      }
    }
    if (lines.isEmpty) return null;
    lines.sort((a, b) => a.start!.compareTo(b.start!));
    return Lyrics(synced: true, lines: lines, credit: credit);
  }

  /// Picks the best entry from an OpenSubsonic `lyricsList`, preferring synced.
  static Lyrics? fromLyricsList(Json j) {
    final entries = jsonList(j['structuredLyrics']);
    if (entries.isEmpty) return null;
    entries.sort((a, b) => (b['synced'] == true ? 1 : 0) - (a['synced'] == true ? 1 : 0));
    final e = entries.first;
    final synced = e['synced'] == true;
    final lines = jsonList(e['line'])
        .map(
          (l) => LyricLine(
            _str(l['value']),
            synced && l['start'] != null ? Duration(milliseconds: _int(l['start'])) : null,
          ),
        )
        .toList();
    if (lines.every((l) => l.text.trim().isEmpty)) return null;
    return Lyrics(synced: synced, lines: lines);
  }
}

enum AlbumListType { newest, recent, frequent, random, starred, alphabeticalByName, alphabeticalByArtist }
