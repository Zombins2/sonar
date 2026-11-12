import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/db/database.dart';
import '../data/subsonic/models.dart';
import '../data/subsonic/subsonic_client.dart';

enum DownloadStatus { queued, done, failed }

class SongDownload {
  const SongDownload(this.status, [this.progress = 0]);
  final DownloadStatus status;

  /// 0..1 while downloading.
  final double progress;
}

/// A downloaded album, playlist or single song, with its own track list.
class DownloadedCollection {
  const DownloadedCollection({
    required this.kind,
    required this.sourceId,
    required this.title,
    required this.subtitle,
    required this.coverArt,
    required this.songs,
  });

  final String kind; // album | playlist | song
  final String sourceId;
  final String title;
  final String subtitle;
  final String? coverArt;
  final List<Song> songs;

  String get key => '$kind:$sourceId';
}

/// Saves original files from the `download` endpoint into app storage and
/// keeps track of what's on the phone. The player asks [localPath] before
/// streaming, so downloaded tracks play without the server.
class DownloadManager extends ChangeNotifier {
  DownloadManager(this._db);

  static const _group = 'sonar-music';
  static const _dir = 'music';

  final AppDatabase _db;
  SubsonicClient? _client;
  late final String _basePath;

  final _songs = <String, SongDownload>{};
  final _filenames = <String, String>{};
  final _collections = <String, DownloadedCollection>{};

  /// Whether queued downloads may use mobile data.
  bool allowCellular = false;

  /// Precaches cover art for offline use. Set by the UI layer.
  Future<void> Function(String coverArt)? precacheCover;

  Map<String, SongDownload> get songs => Map.unmodifiable(_songs);
  List<DownloadedCollection> get collections => _collections.values.toList().reversed.toList();
  DownloadedCollection? collection(String kind, String id) => _collections['$kind:$id'];

  set client(SubsonicClient? c) => _client = c;

  Future<void> init() async {
    _basePath = p.join((await getApplicationSupportDirectory()).path, _dir);
    for (final row in await _db.select(_db.downloadedSongs).get()) {
      final status = DownloadStatus.values.byName(row.status);
      _songs[row.songId] = SongDownload(status);
      _filenames[row.songId] = row.filename;
    }
    final rows = await (_db.select(
      _db.downloadedCollections,
    )..orderBy([(t) => OrderingTerm(expression: t.addedAt)])).get();
    for (final row in rows) {
      _collections[row.id] = DownloadedCollection(
        kind: row.kind,
        sourceId: row.sourceId,
        title: row.title,
        subtitle: row.subtitle,
        coverArt: row.coverArt,
        songs: jsonList(jsonDecode(row.songsJson)).map(Song.fromJson).toList(),
      );
    }

    final fd = FileDownloader();
    fd.configureNotification(
      running: const TaskNotification('Downloading music', '{numFinished} of {numTotal} songs'),
      complete: const TaskNotification('Downloads finished', '{numTotal} songs ready offline'),
      error: const TaskNotification('Some downloads failed', '{numFailed} songs failed'),
      progressBar: true,
      groupNotificationId: _group,
    );
    fd.updates.listen(_onUpdate);
    await fd.start();
    notifyListeners();
  }

  // ---- Queries -----------------------------------------------------------------

  SongDownload? statusOf(String songId) => _songs[songId];

  bool isDownloaded(String songId) => _songs[songId]?.status == DownloadStatus.done;

  /// Absolute path of a finished download, or null.
  String? localPath(String songId) {
    if (!isDownloaded(songId)) return null;
    final name = _filenames[songId];
    if (name == null) return null;
    final path = p.join(_basePath, name);
    return File(path).existsSync() ? path : null;
  }

  /// Fraction of [songs] that are on the phone, and whether any are still queued.
  ({double done, bool active}) progressOf(List<Song> songs) {
    if (songs.isEmpty) return (done: 0, active: false);
    var total = 0.0;
    var active = false;
    for (final s in songs) {
      final d = _songs[s.id];
      if (d == null) continue;
      if (d.status == DownloadStatus.done) total += 1;
      if (d.status == DownloadStatus.queued) {
        total += d.progress;
        active = true;
      }
    }
    return (done: total / songs.length, active: active);
  }

  Future<int> totalBytes() async {
    final dir = Directory(_basePath);
    if (!await dir.exists()) return 0;
    var bytes = 0;
    await for (final f in dir.list(followLinks: false)) {
      if (f is File) bytes += await f.length();
    }
    return bytes;
  }

  String get storagePath => _basePath;

  // ---- Commands ------------------------------------------------------------------

  Future<void> downloadCollection({
    required String kind,
    required String sourceId,
    required String title,
    required String subtitle,
    required String? coverArt,
    required List<Song> songs,
  }) async {
    final collection = DownloadedCollection(
      kind: kind,
      sourceId: sourceId,
      title: title,
      subtitle: subtitle,
      coverArt: coverArt,
      songs: songs,
    );
    final previous = _collections[collection.key];
    _collections[collection.key] = collection;
    if (previous != null) {
      // Re-saving an edited playlist: drop files for tracks nothing needs any more.
      final stillNeeded = {for (final c in _collections.values) ...c.songs.map((s) => s.id)};
      await _deleteSongs(previous.songs.map((s) => s.id).where((id) => !stillNeeded.contains(id)).toList());
    }
    await _db
        .into(_db.downloadedCollections)
        .insertOnConflictUpdate(
          DownloadedCollectionsCompanion.insert(
            id: collection.key,
            kind: kind,
            sourceId: sourceId,
            title: title,
            subtitle: subtitle,
            coverArt: Value(coverArt),
            songsJson: jsonEncode(songs.map((s) => s.toJson()).toList()),
            addedAt: DateTime.now(),
          ),
        );
    await _enqueue(songs);
    for (final art in {coverArt, ...songs.map((s) => s.coverArt)}.whereType<String>()) {
      unawaited(precacheCover?.call(art).catchError((_) {}));
    }
    notifyListeners();
  }

  /// Retry anything in [songs] that failed or was never queued.
  Future<void> retry(List<Song> songs) => _enqueue(songs);

  Future<void> _enqueue(List<Song> songs) async {
    final client = _client;
    if (client == null) return;
    final tasks = <DownloadTask>[];
    for (final s in songs) {
      final existing = _songs[s.id]?.status;
      if (existing == DownloadStatus.done || existing == DownloadStatus.queued) continue;
      final filename = '${s.id}.${s.suffix ?? 'audio'}';
      _songs[s.id] = const SongDownload(DownloadStatus.queued);
      _filenames[s.id] = filename;
      await _db
          .into(_db.downloadedSongs)
          .insertOnConflictUpdate(
            DownloadedSongsCompanion.insert(
              songId: s.id,
              songJson: jsonEncode(s.toJson()),
              filename: filename,
              status: DownloadStatus.queued.name,
            ),
          );
      tasks.add(
        DownloadTask(
          taskId: s.id,
          url: client.downloadUrl(s.id).toString(),
          filename: filename,
          directory: _dir,
          baseDirectory: BaseDirectory.applicationSupport,
          group: _group,
          updates: Updates.statusAndProgress,
          requiresWiFi: !allowCellular,
          retries: 3,
          allowPause: true,
          displayName: s.title,
        ),
      );
    }
    if (tasks.isNotEmpty) {
      await FileDownloader().enqueueAll(tasks);
      notifyListeners();
    }
  }

  Future<void> removeCollection(String kind, String sourceId) async {
    final removed = _collections.remove('$kind:$sourceId');
    await (_db.delete(_db.downloadedCollections)..where((t) => t.id.equals('$kind:$sourceId'))).go();
    if (removed == null) return;
    // Keep tracks another downloaded album / playlist still needs.
    final stillNeeded = {for (final c in _collections.values) ...c.songs.map((s) => s.id)};
    await _deleteSongs(removed.songs.map((s) => s.id).where((id) => !stillNeeded.contains(id)).toList());
    notifyListeners();
  }

  Future<void> removeAll() async {
    await FileDownloader().cancelTasksWithIds(_songs.keys.toList());
    _songs.clear();
    _filenames.clear();
    _collections.clear();
    await _db.delete(_db.downloadedSongs).go();
    await _db.delete(_db.downloadedCollections).go();
    final dir = Directory(_basePath);
    if (await dir.exists()) await dir.delete(recursive: true);
    notifyListeners();
  }

  Future<void> _deleteSongs(List<String> ids) async {
    if (ids.isEmpty) return;
    await FileDownloader().cancelTasksWithIds(ids);
    for (final id in ids) {
      final name = _filenames.remove(id);
      _songs.remove(id);
      if (name != null) {
        final f = File(p.join(_basePath, name));
        if (await f.exists()) await f.delete();
      }
    }
    await (_db.delete(_db.downloadedSongs)..where((t) => t.songId.isIn(ids))).go();
  }

  // ---- Updates from the downloader -------------------------------------------------

  void _onUpdate(TaskUpdate update) {
    final id = update.task.taskId;
    // Ignore tasks for tracks removed while they were in flight.
    if (!_songs.containsKey(id)) return;
    switch (update) {
      case TaskProgressUpdate(:final progress):
        if (progress >= 0 && progress <= 1) {
          _songs[id] = SongDownload(DownloadStatus.queued, progress);
          notifyListeners();
        }
      case TaskStatusUpdate(:final status):
        final next = switch (status) {
          TaskStatus.complete => DownloadStatus.done,
          TaskStatus.failed || TaskStatus.notFound || TaskStatus.canceled => DownloadStatus.failed,
          _ => null,
        };
        if (next == null) return;
        _songs[id] = SongDownload(next, next == DownloadStatus.done ? 1 : 0);
        _saveStatus(id, next);
        notifyListeners();
    }
  }

  Future<void> _saveStatus(String id, DownloadStatus status) async {
    var size = 0;
    final name = _filenames[id];
    if (status == DownloadStatus.done && name != null) {
      final f = File(p.join(_basePath, name));
      if (await f.exists()) size = await f.length();
    }
    await (_db.update(_db.downloadedSongs)..where((t) => t.songId.equals(id))).write(
      DownloadedSongsCompanion(status: Value(status.name), sizeBytes: Value(size)),
    );
  }
}
