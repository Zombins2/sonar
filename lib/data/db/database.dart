import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../subsonic/models.dart';
import '../subsonic/subsonic_client.dart';

part 'database.g.dart';

/// API responses cached for offline browsing, keyed by endpoint + params.
class ApiCache extends Table {
  TextColumn get key => text()();
  TextColumn get body => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Small app state: settings, recent searches, the persisted play queue.
class KeyValues extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// One row per track saved for offline play. [status] is queued / done / failed.
class DownloadedSongs extends Table {
  TextColumn get songId => text()();
  TextColumn get songJson => text()();
  TextColumn get filename => text()();
  TextColumn get status => text()();
  IntColumn get sizeBytes => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {songId};
}

/// An album, playlist or single song the user chose to download. Holds its own
/// copy of the track list so it still opens offline after "Clear cache".
class DownloadedCollections extends Table {
  TextColumn get id => text()(); // "<kind>:<sourceId>"
  TextColumn get kind => text()();
  TextColumn get sourceId => text()();
  TextColumn get title => text()();
  TextColumn get subtitle => text()();
  TextColumn get coverArt => text().nullable()();
  TextColumn get songsJson => text()();
  DateTimeColumn get addedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [ApiCache, KeyValues, DownloadedSongs, DownloadedCollections])
class AppDatabase extends _$AppDatabase implements ResponseCache {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? driftDatabase(name: 'sonar'));

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(downloadedSongs);
        await m.createTable(downloadedCollections);
      }
    },
  );

  // ---- ResponseCache ----------------------------------------------------

  @override
  Future<Json?> read(String key) async {
    final row = await (select(apiCache)..where((t) => t.key.equals(key))).getSingleOrNull();
    if (row == null) return null;
    final decoded = jsonDecode(row.body);
    return decoded is Map ? decoded.cast<String, dynamic>() : null;
  }

  @override
  Future<void> write(String key, Json value) => into(
    apiCache,
  ).insertOnConflictUpdate(ApiCacheCompanion.insert(key: key, body: jsonEncode(value), updatedAt: DateTime.now()));

  Future<int> apiCacheBytes() async {
    final sum = apiCache.body.length.sum();
    final row = await (selectOnly(apiCache)..addColumns([sum])).getSingle();
    return row.read(sum) ?? 0;
  }

  Future<void> clearApiCache() => delete(apiCache).go();

  // ---- Key/value --------------------------------------------------------

  Future<String?> getValue(String key) async =>
      (await (select(keyValues)..where((t) => t.key.equals(key))).getSingleOrNull())?.value;

  Future<void> setValue(String key, String value) =>
      into(keyValues).insertOnConflictUpdate(KeyValuesCompanion.insert(key: key, value: value));

  Future<void> removeValue(String key) => (delete(keyValues)..where((t) => t.key.equals(key))).go();

  Future<Object?> getJson(String key) async {
    final v = await getValue(key);
    return v == null ? null : jsonDecode(v);
  }

  Future<void> setJson(String key, Object? value) => setValue(key, jsonEncode(value));

  /// Wipes everything tied to an account (used on logout).
  Future<void> clearAll() => transaction(() async {
    await delete(apiCache).go();
    await delete(keyValues).go();
  });
}
