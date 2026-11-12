import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'soulbeet_client.dart';
import 'soulbeet_models.dart';
import 'source_pick.dart';

/// Where an album download is up to, in the words the app shows.
enum AlbumPhase {
  /// Looking for copies on Soulseek.
  finding,

  /// Waiting for the sharer, or receiving files.
  downloading,

  /// beets is tagging and filing it.
  importing,

  /// In the library (Navidrome may still be scanning it in).
  imported,

  /// beets wasn't sure which release it is: the user picks.
  needsMatch,
  failed,
  cancelled,
}

/// One album on its way into the library.
class AlbumDownload {
  AlbumDownload._(this.key, {this.album, String? label, this.releaseId}) : _label = label, started = DateTime.now();

  /// An album in a given state, for screenshots and widget tests.
  @visibleForTesting
  AlbumDownload.debug(this.key, {this.album, String? label, this.releaseId, DateTime? started})
    : _label = label,
      started = started ?? DateTime.now();

  /// Soulbeet's batch id once known, else a local id.
  String key;
  final SbAlbum? album;
  final String? _label;

  /// The MusicBrainz release the user picked, used if beets can't decide.
  final String? releaseId;
  final DateTime started;

  AlbumPhase phase = AlbumPhase.finding;

  /// Who it comes from, and in what (`flac`, `m4a`...).
  String? source;
  String? quality;

  /// Why it failed, or what beets said when it skipped the import.
  String? error;

  /// The files, by id.
  final files = <String, SbProgress>{};

  /// Already retried the import with [releaseId].
  bool retriedWithRelease = false;

  /// When an import retry was asked for and its first event hasn't come yet
  /// (until then the files still say "skipped").
  DateTime? retryAskedAt;

  /// Already retried an import whose lookup failed, by itself.
  bool retriedLookup = false;

  /// The album's id in Navidrome once it shows up there.
  String? libraryAlbumId;

  /// A file of an import that failed after every file arrived; Soulbeet kept
  /// them, so trying again needs only the import, not the download.
  SbProgress? get keptFile => files.values
      .where((f) => f.state.kind == SbStateKind.failed && f.retryable && f.localPath != null)
      .firstOrNull;

  bool get importFailed => phase == AlbumPhase.failed && keptFile != null;

  String get title => album?.title ?? _label ?? 'Album';
  String? get artist => album?.artist;

  int get totalBytes => files.values.fold(0, (s, f) => s + f.size);
  int get doneBytes => files.values.fold(0, (s, f) => s + min(f.transferred, f.size));

  /// 0..1 while files arrive; null before any size is known.
  double? get fraction => totalBytes == 0 ? null : doneBytes / totalBytes;

  /// Bytes per second, all files together.
  double get speed => files.values.fold(0.0, (s, f) => s + (f.state.kind == SbStateKind.inProgress ? f.speed : 0));

  int get filesDone =>
      files.values.where((f) => f.state.kind != SbStateKind.queued && f.state.kind != SbStateKind.inProgress).length;

  bool get active => phase == AlbumPhase.finding || phase == AlbumPhase.downloading || phase == AlbumPhase.importing;

  /// A file to address import retries and matches with (any of the album's).
  SbProgress? get anyFile => files.values.firstOrNull;
}

/// Everything downloading through Soulbeet: starting albums, following the
/// live feed, retrying an import with the release the user picked, and
/// telling Navidrome to scan when an album lands.
class SoulbeetDownloads extends ChangeNotifier {
  SoulbeetDownloads({
    required this.client,
    this.rescan,
    this.findInLibrary,
    this.pollEvery = const Duration(seconds: 2),
    this.searchFor = const Duration(seconds: 45),
    this.reconnectDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 30),
    ],
    this.lingerAfterDone = const Duration(minutes: 2),
    this.retryPatience = const Duration(seconds: 30),
    this.lookupRetryAfter = const Duration(seconds: 30),
  });

  final SoulbeetClient client;

  /// Asks Navidrome to scan (through the Sonar Connect relay).
  final Future<bool> Function()? rescan;

  /// The album's id in Navidrome, if it's there yet.
  final Future<String?> Function(String title, String? artist)? findInLibrary;
  final Duration pollEvery;

  /// How long to wait for copies to turn up before deciding.
  final Duration searchFor;
  final List<Duration> reconnectDelays;

  /// Keep the live feed open this long after the last album finishes.
  final Duration lingerAfterDone;

  /// How long "skipped" still counts as the old state after a retry.
  final Duration retryPatience;

  /// How long to wait before importing again when beets couldn't reach
  /// MusicBrainz (it answers "busy" for a while when asked too fast).
  final Duration lookupRetryAfter;

  final _albums = <String, AlbumDownload>{};

  /// File id -> album key, for files queued before their batch id is seen.
  final _fileOwner = <String, String>{};
  StreamSubscription<SbEvent>? _feed;
  Timer? _reconnect;
  Timer? _linger;
  int _feedFailures = 0;
  bool _disposed = false;
  int _localIds = 0;
  SbFolder? _folder;

  /// Shows [d] as if it had been started here (screenshots, widget tests).
  @visibleForTesting
  void debugAdd(AlbumDownload d) {
    _albums[d.key] = d;
    _changed();
  }

  /// Newest first.
  List<AlbumDownload> get albums => _albums.values.toList()..sort((a, b) => b.started.compareTo(a.started));

  int get activeCount => _albums.values.where((a) => a.active).length;

  /// The download for an album the user picked in search, if any.
  AlbumDownload? forAlbum(String albumId) => _albums.values.where((a) => a.album?.id == albumId).lastOrNull;

  @override
  void dispose() {
    _disposed = true;
    _reconnect?.cancel();
    _linger?.cancel();
    unawaited(_feed?.cancel());
    super.dispose();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  // ---- Starting ------------------------------------------------------------------

  /// Downloads [album]: the best lossless copy with every track if there is
  /// one ([pickSource]), else whatever Soulbeet picks. [chosen] skips the
  /// choosing (the user picked a copy themselves).
  Future<AlbumDownload> download(SbAlbum album, {int? trackCount, SbSource? chosen}) async {
    final existing = forAlbum(album.id);
    if (existing != null && existing.active) return existing;
    final d = AlbumDownload._('local-${_localIds++}', album: album, releaseId: album.mbid);
    _albums[d.key] = d;
    _changed();
    unawaited(_listen());
    try {
      final folder = _folder ??= (await client.folders()).firstOrNull;
      if (folder == null) {
        throw const SoulbeetException(SoulbeetErrorKind.refused, 'Soulbeet has no music folder set up.');
      }
      var source = chosen;
      var asked = album;
      if (source == null) {
        final tracks = trackCount ?? (await client.album(album.id)).tracks.length;
        final best = await _bestSource(album, tracks);
        if (best.nobody) {
          // Soulbeet's own pick would search the same way and find nothing too.
          throw const SoulbeetException(
            SoulbeetErrorKind.refused,
            'Nobody on Soulseek is sharing this album right now. Try again later.',
          );
        }
        source = best.pick;
        asked = best.asked;
      }
      if (d.phase == AlbumPhase.cancelled) return d;
      if (source != null) {
        d
          ..source = source.user
          ..quality = source.quality
          ..phase = AlbumPhase.downloading;
        for (final id in await client.queue(source.files, folder)) {
          _adopt(d, id);
        }
      } else {
        // No complete lossless copy: let Soulbeet choose.
        final batch = await client.autoDownload(asked, folder);
        _rekey(d, batch);
        d.phase = AlbumPhase.downloading;
      }
    } on SoulbeetException catch (e) {
      d
        ..phase = AlbumPhase.failed
        ..error = e.message;
    } on SoulbeetFormatException catch (e) {
      d
        ..phase = AlbumPhase.failed
        ..error = e.toString();
    }
    _changed();
    return d;
  }

  /// Copies of [album] found within [searchFor] each, for "Choose source".
  /// A search nobody answers is tried again under a shorter artist name
  /// ([SbAlbum.searchArtists]).
  Stream<SbSourceSearch> findSources(SbAlbum album) => _findSources(album, (_) {});

  Stream<SbSourceSearch> _findSources(SbAlbum album, void Function(SbAlbum asked) asking) async* {
    final names = album.searchArtists;
    if (names.isEmpty) names.add(album.artist);
    for (var i = 0; i < names.length; i++) {
      final asked = album.searchedAs(names[i]);
      asking(asked);
      final id = await client.startSourceSearch(asked);
      final end = DateTime.now().add(searchFor);
      while (true) {
        final r = await client.pollSources(id);
        final over = r.done || DateTime.now().isAfter(end);
        final unanswered = over && r.sources.isEmpty && i < names.length - 1;
        if (!unanswered) yield r;
        if (over) {
          if (r.sources.isNotEmpty) return;
          break;
        }
        await Future<void>.delayed(pollEvery);
      }
    }
  }

  /// The copy to download, the album as last searched for, and whether every
  /// search came back with nobody sharing it.
  Future<({SbSource? pick, SbAlbum asked, bool nobody})> _bestSource(SbAlbum album, int tracks) async {
    SbSourceSearch? last;
    var asked = album;
    try {
      await for (final r in _findSources(album, (a) => asked = a)) {
        last = r;
        // A free, fast, complete lossless copy is good enough to stop early.
        final pick = pickSource(r.sources, tracks: tracks);
        if (pick != null && pick.freeSlot && pick.queueLength == 0) return (pick: pick, asked: asked, nobody: false);
      }
    } on SoulbeetException {
      return (pick: null, asked: album, nobody: false); // Soulbeet's own pick can still try.
    }
    if (last == null) return (pick: null, asked: album, nobody: false);
    final nobody = last.sources.isEmpty && last.state == SbSearchState.completed;
    return (pick: pickSource(last.sources, tracks: tracks), asked: asked, nobody: nobody);
  }

  /// [fileId] is [d]'s. If its first event beat the queue reply, it was
  /// shown as an album of its own; fold that one into [d].
  void _adopt(AlbumDownload d, String fileId) {
    final other = _albums[_fileOwner[fileId]];
    _fileOwner[fileId] = d.key;
    if (other == null || identical(other, d) || other.album != null) return;
    d.files.addAll(other.files);
    _albums.remove(other.key);
    _fileOwner.updateAll((_, v) => v == other.key ? d.key : v);
    final batch = other.files.values.map((f) => f.batchId).whereType<String>().firstOrNull;
    if (batch != null) _rekey(d, batch);
    _settle(d);
  }

  void _rekey(AlbumDownload d, String batchId) {
    if (d.key == batchId) return;
    _albums.remove(d.key);
    final old = d.key;
    d.key = batchId;
    _albums[batchId] = d;
    _fileOwner.updateAll((_, v) => v == old ? batchId : v);
  }

  // ---- Acting on one -----------------------------------------------------------------

  Future<void> cancel(AlbumDownload d) async {
    d.phase = AlbumPhase.cancelled;
    _changed();
    for (final f in d.files.values.where((f) => !f.state.finished && f.state.kind != SbStateKind.completed)) {
      try {
        await client.cancel(f);
      } on SoulbeetException {
        // Already gone.
      }
    }
  }

  Future<List<SbMatch>> matches(AlbumDownload d) async {
    final f = d.anyFile;
    return f == null ? const [] : client.importChoices(f);
  }

  /// Imports a skipped album again the way the user chose.
  Future<void> importWith(AlbumDownload d, SbImportChoice choice) async {
    final f = d.anyFile;
    if (f == null) return;
    await _reimport(d, f, choice, AlbumPhase.needsMatch);
  }

  /// "Try again" on a failed album: only the import when the files are
  /// already here, else the whole download.
  Future<void> tryAgain(AlbumDownload d) async {
    final kept = d.keptFile;
    if (d.phase != AlbumPhase.failed) return;
    if (kept != null) return _reimport(d, kept, const SbChooseAuto(), AlbumPhase.failed);
    if (d.album != null) await download(d.album!);
  }

  Future<void> _reimport(AlbumDownload d, SbProgress f, SbImportChoice choice, AlbumPhase ifRefused) async {
    d
      ..phase = AlbumPhase.importing
      ..error = null
      ..retryAskedAt = DateTime.now();
    _changed();
    unawaited(_listen());
    try {
      await client.retryImport(f, choice);
    } on SoulbeetException catch (e) {
      d
        ..retryAskedAt = null
        ..phase = ifRefused
        ..error = e.message;
      _changed();
    }
  }

  /// Forgets finished albums.
  void clearFinished() {
    _albums.removeWhere((_, a) => !a.active && a.phase != AlbumPhase.needsMatch);
    _changed();
  }

  // ---- The live feed -----------------------------------------------------------------

  /// Opens the feed if it isn't open. Opened when something starts, or when
  /// the downloads page is shown (albums started elsewhere show up too).
  Future<void> watch() => _listen();

  Future<void> _listen() async {
    _linger?.cancel();
    if (_feed != null || _disposed) return;
    _reconnect?.cancel();
    // Claimed before the await, so two callers open one connection.
    final placeholder = const Stream<SbEvent>.empty().listen(null);
    _feed = placeholder;
    try {
      final stream = await client.updates();
      if (_disposed || _feed != placeholder) return;
      _feedFailures = 0;
      _feed = stream.listen(_onEvent, onDone: _feedEnded, onError: (Object _) => _feedEnded());
    } on Object {
      if (_feed == placeholder) _feed = null;
      _feedEnded();
    }
  }

  void _feedEnded() {
    _feed = null;
    if (_disposed || activeCount == 0) return;
    final delay = reconnectDelays[min(_feedFailures++, reconnectDelays.length - 1)];
    _reconnect = Timer(delay, () => unawaited(_listen()));
  }

  void _lingerOrClose() {
    if (activeCount > 0) return;
    _linger?.cancel();
    _linger = Timer(lingerAfterDone, () {
      if (activeCount == 0) {
        unawaited(_feed?.cancel());
        _feed = null;
      }
    });
  }

  void _onEvent(SbEvent e) {
    switch (e) {
      case SbProgressEvent(:final files):
        for (final f in files) {
          _file(f);
        }
      case SbReplacedEvent(:final previousItem, :final entry):
        for (final a in _albums.values) {
          a.files.removeWhere((_, f) => f.item == previousItem);
        }
        _file(entry);
      case SbAutoDownloadEvent(:final event):
        _auto(event);
      case SbUnknownEvent():
        return;
    }
    for (final a in _albums.values.toList()) {
      _settle(a);
    }
    _changed();
    _lingerOrClose();
  }

  AlbumDownload _owner(SbProgress f) {
    final byFile = _fileOwner[f.id];
    final batch = f.batchId;
    if (byFile != null && _albums[byFile] != null) {
      final d = _albums[byFile]!;
      if (batch != null) _rekey(d, batch);
      return d;
    }
    if (batch != null && _albums[batch] != null) return _albums[batch]!;
    // Started somewhere else (Soulbeet's page, the other device).
    final d = AlbumDownload._(batch ?? 'file-${f.id}', label: f.batchLabel ?? f.fileName)
      ..phase = AlbumPhase.downloading;
    d.source = f.source;
    _albums[d.key] = d;
    return d;
  }

  void _file(SbProgress f) {
    final d = _owner(f);
    _fileOwner[f.id] = d.key;
    d.files[f.id] = f;
    d.source ??= f.source;
    d.quality ??= _qualityOf(f.fileName);
  }

  static String? _qualityOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? null : name.substring(dot + 1).toLowerCase();
  }

  void _auto(SbAutoEvent e) {
    final d = _albums[e.batchId];
    if (d == null) return;
    switch (e.kind) {
      case SbAutoKind.pickedSource:
        d
          ..source = e.source
          ..quality = e.quality?.toLowerCase();
      case SbAutoKind.failed:
        d
          ..phase = AlbumPhase.failed
          ..error = e.error ?? 'Soulbeet couldn\'t download it.';
      case SbAutoKind.fallbackToManual:
        d
          ..phase = AlbumPhase.failed
          ..error = 'No copy matched well enough. Try Choose source.';
      default:
        break;
    }
  }

  /// Works out an album's phase from its files, and acts on what changed.
  void _settle(AlbumDownload d) {
    if (d.phase == AlbumPhase.cancelled || d.files.isEmpty) return;
    final kinds = d.files.values.map((f) => f.state.kind).toSet();
    final before = d.phase;
    final retrying = d.retryAskedAt != null && DateTime.now().difference(d.retryAskedAt!) < retryPatience;
    if (kinds.contains(SbStateKind.importing) ||
        kinds.contains(SbStateKind.importQueued) ||
        kinds.contains(SbStateKind.imported)) {
      d.retryAskedAt = null; // The retry has started (or finished).
    }
    if (kinds.contains(SbStateKind.imported)) {
      d.phase = AlbumPhase.imported;
    } else if (kinds.contains(SbStateKind.importSkipped)) {
      final skipped = d.files.values.firstWhere((f) => f.state.kind == SbStateKind.importSkipped);
      if (retrying) {
        d.phase = AlbumPhase.importing;
      } else if (!d.retriedWithRelease && d.releaseId != null) {
        // beets couldn't decide between pressings; the user already did.
        d
          ..retriedWithRelease = true
          ..retryAskedAt = DateTime.now()
          ..phase = AlbumPhase.importing;
        unawaited(
          client.retryImport(skipped, SbChooseRelease(d.releaseId!)).catchError((Object _) {
            d
              ..retryAskedAt = null
              ..phase = AlbumPhase.needsMatch
              ..error = skipped.error;
            _changed();
          }),
        );
      } else {
        d
          ..phase = AlbumPhase.needsMatch
          ..error = skipped.error;
      }
    } else if (kinds.contains(SbStateKind.importing) || kinds.contains(SbStateKind.importQueued)) {
      d.phase = AlbumPhase.importing;
    } else if (kinds.every((k) => k == SbStateKind.failed || k == SbStateKind.cancelled)) {
      final kept = d.keptFile;
      if (retrying && kept != null) {
        d.phase = AlbumPhase.importing; // The old rows until the retry's first event.
      } else if (kept != null && !d.retriedLookup && (kept.error ?? '').startsWith('Lookup failed')) {
        // beets couldn't reach MusicBrainz (it says "busy" when asked too
        // fast); the files are kept, so import again in a little while.
        d
          ..retriedLookup = true
          ..phase = AlbumPhase.importing
          ..error = null
          ..retryAskedAt = DateTime.now().add(lookupRetryAfter);
        Timer(lookupRetryAfter, () {
          if (!_disposed && d.phase == AlbumPhase.importing) {
            unawaited(_reimport(d, kept, const SbChooseAuto(), AlbumPhase.failed));
          }
        });
      } else {
        d.phase = kinds.contains(SbStateKind.failed) ? AlbumPhase.failed : AlbumPhase.cancelled;
        d.error ??= d.files.values.map((f) => f.error ?? f.state.detail).whereType<String>().firstOrNull;
      }
    } else if (kinds.every(
      (k) => k == SbStateKind.completed || k == SbStateKind.failed || k == SbStateKind.cancelled,
    )) {
      d.phase = AlbumPhase.importing; // All here; the import starts next.
    } else {
      d.phase = AlbumPhase.downloading;
    }
    if (d.phase == AlbumPhase.imported && before != AlbumPhase.imported) unawaited(_arrived(d));
  }

  /// Gets Navidrome to scan it in, then finds it there for "Open album".
  Future<void> _arrived(AlbumDownload d) async {
    await rescan?.call();
    final find = findInLibrary;
    if (find == null) return;
    for (var i = 0; i < 20 && !_disposed; i++) {
      final id = await find(d.title, d.artist).catchError((Object _) => null);
      if (id != null) {
        d.libraryAlbumId = id;
        _changed();
        return;
      }
      await Future<void>.delayed(pollEvery * 2);
    }
  }
}
