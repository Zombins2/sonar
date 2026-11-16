import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../connect/connect_client.dart';
import '../deezer/deezer_client.dart';
import '../musicbrainz/musicbrainz_client.dart';
import '../soulbeet/get_music_suggestions.dart';
import '../soulbeet/soulbeet_downloads.dart';
import '../soulbeet/soulbeet_models.dart';
import '../subsonic/models.dart';
import '../subsonic/subsonic_client.dart';

/// Discover: songs the listener doesn't have, by artists like the ones they
/// play, downloaded into a library of their own until each is kept or
/// removed (docs/DISCOVER_PLAN.md). The server side is Sonar Connect's
/// `/discover` endpoints; the downloads are Get music's song downloads.

/// What Discover may download.
@immutable
class DiscoverSettings {
  const DiscoverSettings({this.on = false, this.maxSongs = 50, this.maxGb = 2, this.makeRoom = false});

  factory DiscoverSettings.fromJson(Object? j) {
    if (j is! Map) return const DiscoverSettings();
    int pick(Object? v, List<int> options, int fallback) =>
        v is num && options.contains(v.toInt()) ? v.toInt() : fallback;
    return DiscoverSettings(
      on: j['on'] == true,
      maxSongs: pick(j['maxSongs'], songOptions, 50),
      maxGb: pick(j['maxGb'], gbOptions, 2),
      makeRoom: j['makeRoom'] == true,
    );
  }

  static const songOptions = [25, 50, 100, 200];
  static const gbOptions = [1, 2, 5, 10, 20];

  final bool on;

  /// At most this many undecided songs...
  final int maxSongs;

  /// ...taking at most this much space, whichever comes first.
  final int maxGb;

  /// When full, remove the oldest undecided songs to fit new ones (else
  /// Discover waits until songs are kept or removed).
  final bool makeRoom;

  int get maxBytes => maxGb * 1024 * 1024 * 1024;

  Map<String, Object?> toJson() => {'on': on, 'maxSongs': maxSongs, 'maxGb': maxGb, 'makeRoom': makeRoom};

  DiscoverSettings copyWith({bool? on, int? maxSongs, int? maxGb, bool? makeRoom}) => DiscoverSettings(
    on: on ?? this.on,
    maxSongs: maxSongs ?? this.maxSongs,
    maxGb: maxGb ?? this.maxGb,
    makeRoom: makeRoom ?? this.makeRoom,
  );
}

/// A song downloading into Discover, kept across app restarts: Soulbeet's
/// feed doesn't replay what happened while the app was closed, so this is
/// what's needed to file it afterwards ([SoulbeetDownloads.resumeDiscover]).
class DiscoverPending {
  DiscoverPending({
    required this.key,
    required this.title,
    required this.artist,
    required this.album,
    required this.releaseId,
    required this.started,
    List<String>? items,
  }) : items = items ?? [];

  factory DiscoverPending.fromJson(Map<Object?, Object?> j) => DiscoverPending(
    key: '${j['key']}',
    title: '${j['title'] ?? ''}',
    artist: '${j['artist'] ?? ''}',
    album: '${j['album'] ?? ''}',
    releaseId: '${j['releaseId'] ?? ''}',
    started: DateTime.tryParse('${j['started']}') ?? DateTime.now(),
    items: [for (final i in j['items'] is List ? j['items']! as List : const []) '$i'],
  );

  /// Soulbeet's batch id once it has one.
  String key;
  final String title;
  final String artist;
  final String album;

  /// The MusicBrainz release to file it as.
  final String releaseId;
  final DateTime started;

  /// Its files' `item`s, the address Soulbeet retries imports by.
  List<String> items;

  Map<String, Object?> toJson() => {
    'key': key,
    'title': title,
    'artist': artist,
    'album': album,
    'releaseId': releaseId,
    'started': started.toIso8601String(),
    'items': items,
  };
}

/// Why the last top-up added nothing, in the words the app shows.
enum DiscoverNote { none, added, full, nothingFound, unreachable }

class Discover extends ChangeNotifier {
  Discover({
    required this.library,
    required this.server,
    required this.keepSongs,
    required this.removeSongs,
    required this.downloads,
    required this.deezer,
    required this.musicBrainz,
    required this.played,
    required this.read,
    required this.write,
    required this.onFolders,
    required this.hidden,
    this.mayTopUp,
    this.batch = 5,
    this.lookAt = 15,
    this.perArtist = 2,
    this.minAge = const Duration(days: 1),
    this.pendingFor = const Duration(days: 2),
    this.importedFor = const Duration(minutes: 15),
    this.resumeQuiet = const Duration(seconds: 20),
    this.averageSong = 35 * 1024 * 1024,
  });

  /// The Subsonic client as it is now (it's remade when its scope changes).
  final SubsonicClient Function() library;

  /// Discover on the server (`GET /discover`), null when it's off there.
  final Future<DiscoverServer?> Function() server;
  final Future<DiscoverResult> Function(List<String> songIds) keepSongs;
  final Future<DiscoverResult> Function(List<String> songIds) removeSongs;
  final SoulbeetDownloads downloads;
  final DeezerClient deezer;
  final MusicBrainzClient musicBrainz;

  /// The artists to find others like: the most played (Get music's seeds).
  final Future<List<String>> Function() played;

  /// Where Discover keeps its state between runs.
  final Future<Object?> Function() read;
  final Future<void> Function(Object? state) write;

  /// The libraries other than Discover's, for the library screens to show.
  final void Function(List<String> folders) onFolders;

  /// Discover's song ids, kept out of similar songs ([LibraryScope.hidden]).
  final Set<String> hidden;

  /// False while another device does the topping up (a PC, when this is a
  /// phone), so two don't download the same songs at once.
  final bool Function()? mayTopUp;

  /// At most this many songs started per top-up...
  final int batch;

  /// ...looking at no more than this many artists for them.
  final int lookAt;

  /// At most this many undecided songs by one artist.
  final int perArtist;

  /// "Make room" never removes songs that arrived more recently than this.
  final Duration minAge;

  /// A download not seen to arrive by then is given up on.
  final Duration pendingFor;

  /// An imported song not in Navidrome's Discover library by then is given
  /// up on (beets filed it somewhere unexpected).
  final Duration importedFor;
  final Duration resumeQuiet;

  /// What a song still downloading counts for against the space limit.
  final int averageSong;

  DiscoverSettings _settings = const DiscoverSettings();
  DiscoverSettings get settings => _settings;

  /// Settings changed: tops up when that makes room (turned on, limit raised).
  set settings(DiscoverSettings s) {
    final more = s.on && (!_settings.on || s.maxSongs > _settings.maxSongs || s.maxGb > _settings.maxGb);
    _settings = s;
    _changed();
    if (more) unawaited(topUp());
  }

  /// Whether the server has Discover: null until asked.
  bool? available;

  /// Navidrome's id for the Discover library.
  String? libraryId;

  /// The undecided songs, newest first.
  List<Song> songs = const [];
  final _pending = <DiscoverPending>[];
  List<RemovedSong> _removed = const [];

  /// Songs removed only to make room ("artist|title"), which say nothing
  /// about the artist.
  final _roomed = <String>{};

  bool _loaded = false;
  bool _resumed = false;
  bool _topping = false;
  bool _disposed = false;
  DiscoverNote note = DiscoverNote.none;
  int lastAdded = 0;

  /// Why the last download didn't start, if one didn't.
  String? lastError;

  bool get toppingUp => _topping;
  int get bytes => songs.fold(0, (s, x) => s + (x.size ?? 0));
  int get downloading => _pending.length;
  List<DiscoverPending> get pending => List.unmodifiable(_pending);

  /// No room for another song under either limit.
  bool get full => _room() == 0;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    downloads.removeListener(_downloadsChanged);
    super.dispose();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  static String _key(String artist, String title) => '${plainName(artist)}|${plainName(title)}';

  // ---- State kept between runs ------------------------------------------------

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    downloads.addListener(_downloadsChanged);
    final j = await read();
    if (j is! Map) return;
    for (final p in (j['pending'] is List ? j['pending']! as List : const []).whereType<Map<Object?, Object?>>()) {
      _pending.add(DiscoverPending.fromJson(p));
    }
    _roomed.addAll([for (final r in j['roomed'] is List ? j['roomed']! as List : const []) '$r']);
  }

  Future<void> _save() => write({
    'pending': [for (final p in _pending) p.toJson()],
    'roomed': _roomed.toList(),
  });

  /// Keeps each pending song's batch id and file items up to date.
  void _downloadsChanged() {
    var changed = false;
    for (final p in _pending) {
      final d = _live[p];
      if (d == null) continue;
      if (d.key != p.key && !d.key.startsWith('local-')) {
        p.key = d.key;
        changed = true;
      }
      final items = {...p.items, for (final f in d.files.values) f.item}.toList();
      if (items.length != p.items.length) {
        p.items = items;
        changed = true;
      }
      if (d.phase == AlbumPhase.imported && !_arrivedAt.containsKey(p)) {
        _arrivedAt[p] = DateTime.now();
        // Connect's rescan has started; look once it's had time to finish.
        Timer(const Duration(seconds: 20), () => _disposed ? null : unawaited(refresh().catchError((Object _) {})));
      }
    }
    if (changed) unawaited(_save());
  }

  final _live = <DiscoverPending, AlbumDownload>{};
  final _arrivedAt = <DiscoverPending, DateTime>{};

  // ---- What's in Discover -----------------------------------------------------

  /// Asks the server what's in Discover, and settles downloads that have
  /// arrived, failed, or were left from last time.
  Future<void> refresh() async {
    await _load();
    final DiscoverServer? s;
    try {
      s = await server();
    } on ConnectUnavailable {
      note = DiscoverNote.unreachable;
      _changed();
      rethrow;
    }
    if (s == null || s.library == null) {
      available = false;
      libraryId = null;
      songs = const [];
      hidden.clear();
      onFolders(const []);
      _changed();
      return;
    }
    available = true;
    libraryId = s.library;
    _removed = s.removed;
    final client = library();
    final folders = await client.getMusicFolders();
    onFolders([
      for (final f in folders)
        if (f.id != libraryId) f.id,
    ]);
    songs = (await client.songsIn(libraryId!))
      ..sort((a, b) => (b.created ?? DateTime(2000)).compareTo(a.created ?? DateTime(2000)));
    hidden
      ..clear()
      ..addAll(songs.map((x) => x.id));
    await _settle();
    _changed();
  }

  bool _arrived(DiscoverPending p) => songs.any(
    (s) =>
        plainName(s.title) == plainName(p.title) &&
        (plainName(s.album) == plainName(p.album) || plainName(s.artist) == plainName(p.artist)),
  );

  Future<void> _settle() async {
    final now = DateTime.now();
    final resume = !_resumed;
    _resumed = true;
    for (final p in _pending.toList()) {
      final d = _live[p] ?? downloads.byKey(p.key);
      final arrivedAt = _arrivedAt[p];
      final gone =
          _arrived(p) ||
          (d != null &&
              (d.phase == AlbumPhase.failed || d.phase == AlbumPhase.cancelled || d.phase == AlbumPhase.needsMatch)) ||
          (arrivedAt != null && now.difference(arrivedAt) > importedFor) ||
          now.difference(p.started) > pendingFor;
      if (gone) {
        if (d != null && !_arrived(p) && d.error != null) lastError = d.error;
        _pending.remove(p);
        _live.remove(p);
        _arrivedAt.remove(p);
        continue;
      }
      if (d == null && resume && p.releaseId.isNotEmpty && !p.key.startsWith('local-')) {
        // Left from last time: pick it up.
        unawaited(
          downloads
              .resumeDiscover(
                batchId: p.key,
                releaseId: p.releaseId,
                items: p.items,
                label: p.title,
                started: p.started,
                quietFor: resumeQuiet,
              )
              .then((d) => _live[p] = d),
        );
      } else if (d != null) {
        _live[p] = d;
      }
    }
    await _save();
  }

  // ---- Keep / remove ----------------------------------------------------------

  /// Moves [song] into the library. Returns why not, or null.
  Future<String?> keep(Song song) => _change(song, keepSongs);

  /// Deletes [song] from the server. Returns why not, or null.
  Future<String?> remove(Song song) => _change(song, removeSongs);

  Future<String?> _change(Song song, Future<DiscoverResult> Function(List<String>) call) async {
    final DiscoverResult r;
    try {
      r = await call([song.id]);
    } on ConnectUnavailable catch (e) {
      return e.message;
    }
    if (!r.done.contains(song.id)) return r.failed[song.id] ?? 'The server didn\'t do it.';
    songs = [
      for (final s in songs)
        if (s.id != song.id) s,
    ];
    hidden.remove(song.id);
    _changed();
    // Room for another, once Navidrome has caught up.
    unawaited(Future<void>.delayed(const Duration(seconds: 5), topUp).catchError((Object _) {}));
    return null;
  }

  // ---- Topping up -------------------------------------------------------------

  /// Downloads new songs while there's room: for each artist like the ones
  /// played (as Get music suggests), their most played song on Deezer that
  /// isn't in Discover, wasn't removed before, and is on an album MusicBrainz
  /// knows (beets files by MusicBrainz release). Skips artists with two
  /// songs removed, and albums already in Discover (beets would replace the
  /// song there with the new one).
  Future<void> topUp() async {
    if (_topping || _disposed || !_settings.on) return;
    if (mayTopUp?.call() == false) return;
    _topping = true;
    _changed();
    try {
      await refresh();
      if (available != true) return;
      var room = _room();
      if (room <= 0 && _settings.makeRoom) room = await _makeRoom();
      if (room <= 0) {
        note = DiscoverNote.full;
        return;
      }
      lastAdded = await _add(room);
      note = lastAdded > 0 ? DiscoverNote.added : DiscoverNote.nothingFound;
    } on ConnectUnavailable {
      note = DiscoverNote.unreachable;
    } on SubsonicException {
      note = DiscoverNote.unreachable;
    } finally {
      _topping = false;
      _changed();
    }
  }

  int _room() {
    final bySongs = _settings.maxSongs - songs.length - _pending.length;
    final bySpace = (_settings.maxBytes - bytes - _pending.length * averageSong) ~/ averageSong;
    return max(0, min(batch, min(bySongs, bySpace)));
  }

  /// Removes the oldest undecided songs (none newer than [minAge]) to fit a
  /// top-up. Returns the room made.
  Future<int> _makeRoom() async {
    final now = DateTime.now();
    final old = songs.reversed.where((s) => s.created != null && now.difference(s.created!) >= minAge).toList();
    var freeSongs = _settings.maxSongs - songs.length - _pending.length;
    var freeBytes = _settings.maxBytes - bytes - _pending.length * averageSong;
    final out = <Song>[];
    for (final s in old) {
      if (freeSongs >= batch && freeBytes >= batch * averageSong) break;
      out.add(s);
      freeSongs++;
      freeBytes += s.size ?? 0;
    }
    if (out.isEmpty) return 0;
    final DiscoverResult r;
    try {
      r = await removeSongs([for (final s in out) s.id]);
    } on ConnectUnavailable {
      return 0;
    }
    final done = r.done.toSet();
    _roomed.addAll([
      for (final s in out)
        if (done.contains(s.id)) _key(s.artist, s.title),
    ]);
    songs = [
      for (final s in songs)
        if (!done.contains(s.id)) s,
    ];
    hidden.removeAll(done);
    await _save();
    return _room();
  }

  Future<int> _add(int room) async {
    final client = library();
    final seeds = await played();
    final owned = [for (final a in await client.getArtists()) a.name];
    final removed = {for (final r in _removed) _key(r.artist, r.title)};
    final strikes = <String, int>{};
    for (final r in _removed) {
      if (_roomed.contains(_key(r.artist, r.title))) continue;
      strikes.update(plainName(r.artist), (n) => n + 1, ifAbsent: () => 1);
    }
    final have = <String>{
      for (final s in songs) _key(s.artist, s.title),
      for (final p in _pending) _key(p.artist, p.title),
    };
    final albums = <String>{for (final s in songs) plainName(s.album), for (final p in _pending) plainName(p.album)};
    final byArtist = <String, int>{};
    for (final s in songs) {
      byArtist.update(plainName(s.artist), (n) => n + 1, ifAbsent: () => 1);
    }
    for (final p in _pending) {
      byArtist.update(plainName(p.artist), (n) => n + 1, ifAbsent: () => 1);
    }
    var added = 0, looked = 0;
    lastError = null;
    await for (final artist in relatedArtists(deezer, played: seeds, owned: owned)) {
      if (added >= room || looked >= lookAt || _disposed || !_settings.on) break;
      final name = plainName(artist.name);
      if ((strikes[name] ?? 0) >= 2 || (byArtist[name] ?? 0) >= perArtist) continue;
      looked++;
      final List<SbTrack> top;
      try {
        top = await deezer.topSongs(artist);
      } on DeezerException {
        continue;
      }
      for (final t in top.take(3)) {
        final key = _key(artist.name, t.title);
        if (removed.contains(key) || have.contains(key)) continue;
        final found = await _resolve(t, artist.name);
        if (found == null || albums.contains(plainName(found.album.title))) continue;
        final d = await downloads.download(found.album, songs: [found.track], forDiscover: true);
        if (d.phase == AlbumPhase.failed) {
          lastError = d.error;
          continue;
        }
        final p = DiscoverPending(
          key: d.key,
          title: found.track.title,
          artist: artist.name,
          album: found.album.title,
          releaseId: found.album.mbid ?? '',
          started: DateTime.now(),
        );
        _pending.add(p);
        _live[p] = d;
        have.add(key);
        albums.add(plainName(found.album.title));
        byArtist.update(name, (n) => n + 1, ifAbsent: () => 1);
        added++;
        await _save();
        _changed();
        break; // One song per artist each time, for variety.
      }
    }
    return added;
  }

  /// [t] (a Deezer song) as a MusicBrainz release and its track there, to
  /// download it with: its own album's pressing (by barcode), else the
  /// album MusicBrainz finds the song on. Never a compilation: not one
  /// MusicBrainz marks, Deezer calls one, credits to Various Artists, or
  /// titles like one ("100 Hits: Reggae"); MusicBrainz's search answers
  /// often leave the mark out (seen live 2026-11-16).
  Future<({SbAlbum album, SbTrack track})?> _resolve(SbTrack t, String artist) async {
    Future<({SbAlbum album, SbTrack track})?> on(SbAlbum? album) async {
      if (album == null) return null;
      if (album.deezerId case final id?) {
        try {
          if ((await deezer.album(id)).kind == 'compile') return null;
        } on DeezerException {
          // MusicBrainz's look still counts.
        }
      }
      final detail = await musicBrainz.songsOf(album);
      final a = detail.album;
      if (a.mbid == null ||
          a.kinds.contains('Compilation') ||
          plainName(a.artist) == 'variousartists' ||
          hitsTitle.hasMatch(a.title)) {
        return null;
      }
      final track = detail.tracks.where((x) => plainName(x.title) == plainName(t.title)).firstOrNull;
      return track == null ? null : (album: detail.album, track: track);
    }

    try {
      if (await on(t.onAlbum) case final r?) return r;
    } on MusicBrainzException {
      // Not by barcode or name; try the song itself.
    }
    try {
      for (final s in (await musicBrainz.searchSongs(t.title, artist: artist)).take(3)) {
        if (await on(s.onAlbum) case final r?) return r;
      }
    } on MusicBrainzException {
      return null;
    }
    return null;
  }
}
