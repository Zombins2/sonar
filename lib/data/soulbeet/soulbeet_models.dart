import 'dart:convert';

/// Replies from the Soulbeet server (v0.8.0), as recorded in
/// `test/fixtures/soulbeet`. See docs/SOULBEET_PLAN.md.
///
/// Every parser here is lenient about extra fields and strict only about the
/// ones the app needs, so a Soulbeet update that adds fields changes nothing,
/// and one that renames a needed field fails loudly in the contract tests.

typedef SbJson = Map<String, Object?>;

class SoulbeetFormatException implements Exception {
  const SoulbeetFormatException(this.message);
  final String message;
  @override
  String toString() => 'Unexpected reply from Soulbeet: $message';
}

T _need<T>(SbJson j, String key) {
  final v = j[key];
  if (v is T) return v;
  throw SoulbeetFormatException('"$key" is ${v.runtimeType}, expected $T');
}

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;
int _int(Object? v) => v is num ? v.toInt() : 0;
double _double(Object? v) => v is num ? v.toDouble() : 0;

/// An album on MusicBrainz (a release), from a search or an album lookup.
/// [raw] is sent back unchanged when asking Soulbeet to download it.
class SbAlbum {
  SbAlbum._(
    this.raw, {
    required this.id,
    required this.title,
    required this.artist,
    this.releaseDate,
    this.mbid,
    this.groupId,
    this.kinds = const [],
  });

  factory SbAlbum.fromJson(SbJson j) => SbAlbum._(
    Map.unmodifiable(j),
    id: _need<String>(j, 'id'),
    title: _need<String>(j, 'title'),
    artist: _str(j['artist']) ?? '',
    releaseDate: _str(j['release_date']),
    mbid: _str(j['mbid']),
  );

  /// An album Sonar found on MusicBrainz itself, shaped as Soulbeet's own
  /// search sends it: [pressing] is the release to download, [groupId] the
  /// album across all its pressings. Found without a pressing (an artist's
  /// list), it [needsPressing] before its songs load or it downloads.
  factory SbAlbum.found({
    String? pressing,
    required String groupId,
    required String title,
    required String artist,
    String? releaseDate,
    List<String> kinds = const [],
  }) => SbAlbum._(
    Map.unmodifiable({
      'id': pressing ?? groupId,
      'title': title,
      'artist': artist,
      'release_date': releaseDate,
      'mbid': pressing,
    }),
    id: pressing ?? groupId,
    title: title,
    artist: artist,
    releaseDate: _str(releaseDate),
    mbid: pressing,
    groupId: groupId,
    kinds: List.unmodifiable(kinds),
  );

  /// Found without a pressing: [id] is the release group's for now.
  bool get needsPressing => mbid == null && groupId != null;

  final SbJson raw;
  final String id;
  final String title;
  final String artist;
  final String? releaseDate;

  /// The MusicBrainz release id (the same as [id] for MusicBrainz results).
  final String? mbid;

  /// The MusicBrainz release group (the album across all its pressings),
  /// when known: what listener counts are kept by.
  final String? groupId;

  /// What else MusicBrainz says the album is, besides an album or EP:
  /// "Compilation", "Live", "Remix", "Mixtape/Street"... Empty for a studio one.
  final List<String> kinds;

  /// The album as Soulbeet's own page sends it back (no `kind`).
  SbJson get request => {
    for (final e in raw.entries)
      if (e.key != 'kind') e.key: e.value,
  };

  String? get year => releaseDate != null && releaseDate!.length >= 4 ? releaseDate!.substring(0, 4) : null;

  /// Names to search Soulseek under, best first: the artist, then shorter
  /// and shorter starts of it ("Kanye West", then "Kanye").
  ///
  /// Soulseek peers silently ignore searches containing some phrases:
  /// "Kanye West Jesus Is King" gets no answers at all, "Kanye Jesus Is King"
  /// gets hundreds. Soulbeet scores a copy by whether its folders contain
  /// the artist searched for, so the shorter name still finds and scores the
  /// right copies. Starts that would match almost anything ("The", "DJ")
  /// are left out.
  List<String> get searchArtists {
    final words = artist.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final names = <String>[if (artist.trim().isNotEmpty) artist.trim()];
    for (var n = words.length - 1; n >= 1; n--) {
      final start = words.take(n).toList();
      while (start.isNotEmpty && {..._joiners, 'the', 'a', 'an'}.contains(start.last.toLowerCase())) {
        start.removeLast();
      }
      final name = start.join(' ');
      final letters = name.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
      if (letters.length < 3 || _vague.contains(name.toLowerCase())) continue;
      if (!names.contains(name)) names.add(name);
    }
    return names;
  }

  static const _joiners = {'&', '+', 'and', 'x', 'feat.', 'ft.', 'with', ',', '-', '/'};
  static const _vague = {'the', 'dj', 'mc', 'lil', 'los', 'las', 'les', 'die', 'der', 'das', 'el', 'la', 'le', 'de'};

  /// This album as searched for under [name] instead of its artist.
  SbAlbum searchedAs(String name) => name == artist ? this : SbAlbum.fromJson({...raw, 'artist': name});

  /// The release's front cover on the Cover Art Archive.
  Uri? coverUrl({int size = 250}) =>
      mbid == null ? null : Uri.parse('https://coverartarchive.org/release/$mbid/front-$size');
}

/// A song on MusicBrainz, from a track search or an album's track list.
class SbTrack {
  SbTrack._(
    this.raw, {
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.albumId,
    this.duration,
  });

  factory SbTrack.fromJson(SbJson j) => SbTrack._(
    Map.unmodifiable(j),
    id: _need<String>(j, 'id'),
    title: _need<String>(j, 'title'),
    artist: _str(j['artist']) ?? '',
    album: _str(j['album_title']),
    albumId: _str(j['album_id']) ?? _str(j['release_mbid']),
    duration: _parseDuration(j['duration']),
  );

  final SbJson raw;
  final String id;
  final String title;
  final String artist;
  final String? album;
  final String? albumId;
  final Duration? duration;

  /// The album this song is on, as far as a search knows it. Its artist is
  /// the song's (with any featured names); the album sheet swaps in the
  /// album's own details once they load.
  SbAlbum? get onAlbum => albumId == null || album == null
      ? null
      : SbAlbum.fromJson({
          'id': albumId,
          'title': album,
          'artist': artist,
          'release_date': raw['release_date'],
          'mbid': albumId,
        });

  /// Soulbeet sends `"04:41"` (or `"1:02:03"`).
  static Duration? _parseDuration(Object? v) {
    if (v is num) return Duration(seconds: v.toInt());
    if (v is! String || v.isEmpty) return null;
    final parts = v.split(':').map(int.tryParse).toList();
    if (parts.any((p) => p == null)) return null;
    var seconds = 0;
    for (final p in parts) {
      seconds = seconds * 60 + p!;
    }
    return Duration(seconds: seconds);
  }
}

class SbAlbumDetail {
  const SbAlbumDetail(this.album, this.tracks);

  factory SbAlbumDetail.fromJson(SbJson j) => SbAlbumDetail(SbAlbum.fromJson(_need<SbJson>(j, 'album')), [
    for (final t in _need<List<Object?>>(j, 'tracks').whereType<SbJson>()) SbTrack.fromJson(t),
  ]);

  final SbAlbum album;
  final List<SbTrack> tracks;
}

/// A library folder Soulbeet can import into.
class SbFolder {
  const SbFolder({required this.id, required this.name, required this.path});

  factory SbFolder.fromJson(SbJson j) =>
      SbFolder(id: _need<String>(j, 'id'), name: _str(j['name']) ?? '', path: _need<String>(j, 'path'));

  final String id;
  final String name;
  final String path;
}

class SbHealth {
  const SbHealth({
    required this.downloaderOnline,
    required this.importerReady,
    required this.navidromeOnline,
    required this.issues,
  });

  factory SbHealth.fromJson(SbJson j) {
    final importer = j['importer'] is SbJson ? j['importer']! as SbJson : const <String, Object?>{};
    return SbHealth(
      downloaderOnline: j['downloader_online'] == true,
      importerReady: importer['level'] == 'Ready',
      navidromeOnline: j['navidrome_online'] == true,
      issues: [
        // `HealthIssue {severity, title, detail}`.
        for (final i in (importer['issues'] as List<Object?>? ?? const []))
          if (i is SbJson) _str(i['title']) ?? '$i' else '$i',
      ],
    );
  }

  final bool downloaderOnline;
  final bool importerReady;
  final bool navidromeOnline;
  final List<String> issues;

  bool get ready => downloaderOnline && importerReady;
}

// ---- Finding sources ---------------------------------------------------------------

/// One file someone on Soulseek shares. [raw] goes back unchanged to queue it.
class SbSourceFile {
  SbSourceFile._(
    this.raw, {
    required this.id,
    required this.title,
    required this.size,
    required this.quality,
    this.bitDepth,
    this.sampleRate,
  });

  factory SbSourceFile.fromJson(SbJson j) {
    final backend = _backendData(j['backend_data']);
    return SbSourceFile._(
      Map.unmodifiable(j),
      id: _need<String>(j, 'id'),
      title: _str(j['title']) ?? '',
      size: _int(j['size']),
      quality: (_str(j['quality']) ?? '').toLowerCase(),
      bitDepth: backend['bitDepth'] is num ? (backend['bitDepth']! as num).toInt() : null,
      sampleRate: backend['sampleRate'] is num ? (backend['sampleRate']! as num).toInt() : null,
    );
  }

  final SbJson raw;
  final String id;
  final String title;
  final int size;
  final String quality;
  final int? bitDepth;
  final int? sampleRate;
}

/// `backend_data` is JSON inside a string (slskd's own fields).
SbJson _backendData(Object? v) {
  if (v is! String) return const {};
  try {
    final d = jsonDecode(v);
    return d is SbJson ? d : const {};
  } catch (_) {
    return const {};
  }
}

/// One person's copy of an album (or of a song).
class SbSource {
  SbSource._({
    required this.user,
    required this.title,
    required this.artist,
    required this.itemCount,
    required this.totalSize,
    required this.quality,
    required this.score,
    required this.files,
    required this.freeSlot,
    required this.uploadSpeed,
    required this.queueLength,
  });

  factory SbSource.fromJson(SbJson j) {
    final files = [for (final f in _need<List<Object?>>(j, 'items').whereType<SbJson>()) SbSourceFile.fromJson(f)];
    final items = j['items']! as List<Object?>;
    final first = items.isEmpty ? const <String, Object?>{} : _backendData((items.first as SbJson?)?['backend_data']);
    return SbSource._(
      user: _need<String>(j, 'source'),
      title: _str(j['title']) ?? '',
      artist: _str(j['artist']),
      itemCount: _int(j['item_count']),
      totalSize: _int(j['total_size']),
      quality: (_str(j['quality']) ?? '').toLowerCase(),
      score: _double(j['score']),
      files: files,
      freeSlot: first['hasFreeUploadSlot'] == true,
      uploadSpeed: _int(first['uploadSpeed']),
      queueLength: _int(first['queueLength']),
    );
  }

  final String user;
  final String title;
  final String? artist;
  final int itemCount;
  final int totalSize;

  /// `flac`, `mp3`, `m4a`...
  final String quality;

  /// Soulbeet's match score for this copy, 0..1.
  final double score;
  final List<SbSourceFile> files;
  final bool freeSlot;

  /// Bytes per second the sharer reports.
  final int uploadSpeed;
  final int queueLength;

  bool get lossless => quality == 'flac' || quality == 'alac' || quality == 'wav';
}

enum SbSearchState { inProgress, completed, notFound, timedOut }

class SbSourceSearch {
  const SbSourceSearch({required this.id, required this.sources, required this.state, required this.hasMore});

  factory SbSourceSearch.fromJson(SbJson j) => SbSourceSearch(
    id: _need<String>(j, 'search_id'),
    sources: [for (final g in _need<List<Object?>>(j, 'groups').whereType<SbJson>()) SbSource.fromJson(g)],
    state: switch (j['state']) {
      'InProgress' => SbSearchState.inProgress,
      'Completed' => SbSearchState.completed,
      'NotFound' => SbSearchState.notFound,
      'TimedOut' => SbSearchState.timedOut,
      final s => throw SoulbeetFormatException('search state $s'),
    },
    hasMore: j['has_more'] == true,
  );

  final String id;
  final List<SbSource> sources;
  final SbSearchState state;
  final bool hasMore;

  bool get done => state != SbSearchState.inProgress;
}

// ---- Downloads and imports ------------------------------------------------------------

enum SbStateKind {
  queued,
  inProgress,
  completed,
  importQueued,
  importing,
  imported,
  importSkipped,
  failed,
  cancelled,
  unknown,
}

/// A file's state. Soulbeet sends `"Queued"` or `{"Failed": "why"}`.
class SbState {
  const SbState(this.kind, [this.detail]);

  factory SbState.fromJson(Object? v) {
    final (name, detail) = switch (v) {
      String s => (s, null),
      Map<String, Object?> m when m.length == 1 => (m.keys.first, m.values.first),
      _ => ('', null),
    };
    final kind = switch (name) {
      'Queued' => SbStateKind.queued,
      'InProgress' => SbStateKind.inProgress,
      'Completed' => SbStateKind.completed,
      'ImportQueued' => SbStateKind.importQueued,
      'Importing' => SbStateKind.importing,
      'Imported' => SbStateKind.imported,
      'ImportSkipped' => SbStateKind.importSkipped,
      'Failed' => SbStateKind.failed,
      'Cancelled' => SbStateKind.cancelled,
      _ => SbStateKind.unknown,
    };
    return SbState(kind, detail?.toString());
  }

  final SbStateKind kind;

  /// The failure reason, or the import queue position.
  final String? detail;

  bool get finished =>
      kind == SbStateKind.imported ||
      kind == SbStateKind.importSkipped ||
      kind == SbStateKind.failed ||
      kind == SbStateKind.cancelled;
}

/// One file being downloaded and imported.
class SbProgress {
  const SbProgress({
    required this.id,
    required this.source,
    required this.item,
    required this.size,
    required this.transferred,
    required this.state,
    required this.percent,
    required this.speed,
    this.error,
    this.backend,
    this.batchId,
    this.batchLabel,
    this.retryable = false,
    this.canChooseImport = false,
    this.localPath,
  });

  factory SbProgress.fromJson(SbJson j) => SbProgress(
    id: _need<String>(j, 'id'),
    source: _str(j['source']) ?? '',
    item: _need<String>(j, 'item'),
    size: _int(j['size']),
    transferred: _int(j['transferred']),
    state: SbState.fromJson(j['state']),
    percent: _double(j['percent']),
    speed: _double(j['speed']),
    error: _str(j['error']),
    backend: _str(j['backend']),
    batchId: _str(j['batch_id']),
    batchLabel: _str(j['batch_label']),
    retryable: j['retryable'] == true,
    canChooseImport: j['can_choose_import'] == true,
    localPath: _str(j['local_path']),
  );

  final String id;
  final String source;

  /// The file's path on the sharer's side; also how imports are addressed.
  final String item;
  final int size;
  final int transferred;
  final SbState state;
  final double percent;

  /// Bytes per second.
  final double speed;
  final String? error;
  final String? backend;
  final String? batchId;
  final String? batchLabel;
  final bool retryable;
  final bool canChooseImport;

  /// Where Soulbeet kept the files of an import that didn't go through, for
  /// another try. Only set once an import has ended without importing.
  final String? localPath;

  /// The file name without the sharer's folders.
  String get fileName => item.split(RegExp(r'[\\/]')).last;
}

/// What Soulbeet's own pick did for an album ([SbAutoEvent.batchId]).
enum SbAutoKind { searching, scoring, pickedSource, downloading, fallbackToManual, failed, unknown }

class SbAutoEvent {
  const SbAutoEvent(this.kind, this.batchId, {this.source, this.quality, this.error, this.resultCount});
  final SbAutoKind kind;
  final String batchId;
  final String? source;
  final String? quality;
  final String? error;
  final int? resultCount;
}

/// One WebSocket message from `/api/downloads/updates`.
sealed class SbEvent {
  const SbEvent();

  /// Each frame holds one JSON event (`{"Progress": [...]}`,
  /// `{"AutoDownload": {"PickedSource": {...}}}`). Unknown events come back
  /// as [SbUnknownEvent], so a newer Soulbeet can't break the feed.
  factory SbEvent.fromJson(Object? json) {
    if (json is! SbJson || json.length != 1) return SbUnknownEvent(json);
    final MapEntry(:key, :value) = json.entries.first;
    switch (key) {
      case 'Progress' when value is List:
        return SbProgressEvent([for (final p in value.whereType<SbJson>()) SbProgress.fromJson(p)]);
      // A file moved to another sharer: its row is replaced, not duplicated.
      case 'Replaced' when value is SbJson && value['entry'] is SbJson:
        return SbReplacedEvent(_str(value['previous_item']) ?? '', SbProgress.fromJson(value['entry']! as SbJson));
      case 'AutoDownload' when value is SbJson && value.length == 1:
        final MapEntry(key: name, value: body) = value.entries.first;
        final b = body is SbJson ? body : const <String, Object?>{};
        final batch = _str(b['batch_id']) ?? '';
        return SbAutoDownloadEvent(
          SbAutoEvent(
            switch (name) {
              'Searching' => SbAutoKind.searching,
              'ScoringResults' => SbAutoKind.scoring,
              'PickedSource' => SbAutoKind.pickedSource,
              'Downloading' => SbAutoKind.downloading,
              'FallbackToManual' => SbAutoKind.fallbackToManual,
              'Failed' => SbAutoKind.failed,
              _ => SbAutoKind.unknown,
            },
            batch,
            source: _str(b['source']),
            quality: _str(b['quality']),
            error: _str(b['error']) ?? _str(b['reason']),
            resultCount: b['result_count'] is num ? (b['result_count']! as num).toInt() : null,
          ),
        );
      default:
        return SbUnknownEvent(json);
    }
  }
}

class SbProgressEvent extends SbEvent {
  const SbProgressEvent(this.files);
  final List<SbProgress> files;
}

class SbReplacedEvent extends SbEvent {
  const SbReplacedEvent(this.previousItem, this.entry);
  final String previousItem;
  final SbProgress entry;
}

class SbAutoDownloadEvent extends SbEvent {
  const SbAutoDownloadEvent(this.event);
  final SbAutoEvent event;
}

class SbUnknownEvent extends SbEvent {
  const SbUnknownEvent(this.json);
  final Object? json;
}

/// A match beets found for a skipped import.
class SbMatch {
  const SbMatch({
    required this.dataSource,
    required this.id,
    required this.artist,
    required this.title,
    this.year,
    this.country,
    this.disambig,
    required this.perMille,
    this.matchedTracks,
    this.totalTracks,
  });

  factory SbMatch.fromJson(SbJson j) {
    final fit = j['tracks'] is SbJson ? j['tracks']! as SbJson : null;
    return SbMatch(
      dataSource: _need<String>(j, 'data_source'),
      id: _need<String>(j, 'id'),
      artist: _str(j['artist']) ?? '',
      title: _str(j['title']) ?? '',
      year: j['year'] is num ? (j['year']! as num).toInt() : null,
      country: _str(j['country']),
      disambig: _str(j['disambig']),
      perMille: _int(j['per_mille']),
      matchedTracks: fit == null ? null : _int(fit['matched']),
      totalTracks: fit == null ? null : _int(fit['total']),
    );
  }

  final String dataSource;
  final String id;
  final String artist;
  final String title;
  final int? year;
  final String? country;
  final String? disambig;

  /// How close beets thinks it is, 0..1000.
  final int perMille;
  final int? matchedTracks;
  final int? totalTracks;
}

/// How to run a skipped import again (`ImportChoice`).
sealed class SbImportChoice {
  const SbImportChoice();
  Object toJson();
}

class SbChooseAuto extends SbImportChoice {
  const SbChooseAuto();
  @override
  Object toJson() => 'Auto';
}

class SbChooseAsIs extends SbImportChoice {
  const SbChooseAsIs();
  @override
  Object toJson() => 'AsIs';
}

class SbChooseMatch extends SbImportChoice {
  const SbChooseMatch(this.match);
  final SbMatch match;
  @override
  Object toJson() => {
    'Candidate': {'data_source': match.dataSource, 'id': match.id},
  };
}

/// A MusicBrainz release id (the album the user picked in Sonar).
class SbChooseRelease extends SbImportChoice {
  const SbChooseRelease(this.releaseId);
  final String releaseId;
  @override
  Object toJson() => {'MusicBrainz': releaseId};
}
