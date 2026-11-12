// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $ApiCacheTable extends ApiCache with TableInfo<$ApiCacheTable, ApiCacheData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ApiCacheTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
    'body',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, body, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'api_cache';
  @override
  VerificationContext validateIntegrity(Insertable<ApiCacheData> instance, {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(_keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('body')) {
      context.handle(_bodyMeta, body.isAcceptableOrUnknown(data['body']!, _bodyMeta));
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta, updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  ApiCacheData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ApiCacheData(
      key: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      body: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}body'])!,
      updatedAt: attachedDatabase.typeMapping.read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $ApiCacheTable createAlias(String alias) {
    return $ApiCacheTable(attachedDatabase, alias);
  }
}

class ApiCacheData extends DataClass implements Insertable<ApiCacheData> {
  final String key;
  final String body;
  final DateTime updatedAt;
  const ApiCacheData({required this.key, required this.body, required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['body'] = Variable<String>(body);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  ApiCacheCompanion toCompanion(bool nullToAbsent) {
    return ApiCacheCompanion(key: Value(key), body: Value(body), updatedAt: Value(updatedAt));
  }

  factory ApiCacheData.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ApiCacheData(
      key: serializer.fromJson<String>(json['key']),
      body: serializer.fromJson<String>(json['body']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'body': serializer.toJson<String>(body),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  ApiCacheData copyWith({String? key, String? body, DateTime? updatedAt}) =>
      ApiCacheData(key: key ?? this.key, body: body ?? this.body, updatedAt: updatedAt ?? this.updatedAt);
  ApiCacheData copyWithCompanion(ApiCacheCompanion data) {
    return ApiCacheData(
      key: data.key.present ? data.key.value : this.key,
      body: data.body.present ? data.body.value : this.body,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ApiCacheData(')
          ..write('key: $key, ')
          ..write('body: $body, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, body, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ApiCacheData && other.key == this.key && other.body == this.body && other.updatedAt == this.updatedAt);
}

class ApiCacheCompanion extends UpdateCompanion<ApiCacheData> {
  final Value<String> key;
  final Value<String> body;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const ApiCacheCompanion({
    this.key = const Value.absent(),
    this.body = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ApiCacheCompanion.insert({
    required String key,
    required String body,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       body = Value(body),
       updatedAt = Value(updatedAt);
  static Insertable<ApiCacheData> custom({
    Expression<String>? key,
    Expression<String>? body,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (body != null) 'body': body,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ApiCacheCompanion copyWith({Value<String>? key, Value<String>? body, Value<DateTime>? updatedAt, Value<int>? rowid}) {
    return ApiCacheCompanion(
      key: key ?? this.key,
      body: body ?? this.body,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ApiCacheCompanion(')
          ..write('key: $key, ')
          ..write('body: $body, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $KeyValuesTable extends KeyValues with TableInfo<$KeyValuesTable, KeyValue> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $KeyValuesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'key_values';
  @override
  VerificationContext validateIntegrity(Insertable<KeyValue> instance, {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(_keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(_valueMeta, value.isAcceptableOrUnknown(data['value']!, _valueMeta));
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  KeyValue map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return KeyValue(
      key: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      value: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}value'])!,
    );
  }

  @override
  $KeyValuesTable createAlias(String alias) {
    return $KeyValuesTable(attachedDatabase, alias);
  }
}

class KeyValue extends DataClass implements Insertable<KeyValue> {
  final String key;
  final String value;
  const KeyValue({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  KeyValuesCompanion toCompanion(bool nullToAbsent) {
    return KeyValuesCompanion(key: Value(key), value: Value(value));
  }

  factory KeyValue.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return KeyValue(key: serializer.fromJson<String>(json['key']), value: serializer.fromJson<String>(json['value']));
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{'key': serializer.toJson<String>(key), 'value': serializer.toJson<String>(value)};
  }

  KeyValue copyWith({String? key, String? value}) => KeyValue(key: key ?? this.key, value: value ?? this.value);
  KeyValue copyWithCompanion(KeyValuesCompanion data) {
    return KeyValue(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('KeyValue(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is KeyValue && other.key == this.key && other.value == this.value);
}

class KeyValuesCompanion extends UpdateCompanion<KeyValue> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const KeyValuesCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  KeyValuesCompanion.insert({required String key, required String value, this.rowid = const Value.absent()})
    : key = Value(key),
      value = Value(value);
  static Insertable<KeyValue> custom({Expression<String>? key, Expression<String>? value, Expression<int>? rowid}) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  KeyValuesCompanion copyWith({Value<String>? key, Value<String>? value, Value<int>? rowid}) {
    return KeyValuesCompanion(key: key ?? this.key, value: value ?? this.value, rowid: rowid ?? this.rowid);
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('KeyValuesCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DownloadedSongsTable extends DownloadedSongs with TableInfo<$DownloadedSongsTable, DownloadedSong> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DownloadedSongsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _songIdMeta = const VerificationMeta('songId');
  @override
  late final GeneratedColumn<String> songId = GeneratedColumn<String>(
    'song_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _songJsonMeta = const VerificationMeta('songJson');
  @override
  late final GeneratedColumn<String> songJson = GeneratedColumn<String>(
    'song_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _filenameMeta = const VerificationMeta('filename');
  @override
  late final GeneratedColumn<String> filename = GeneratedColumn<String>(
    'filename',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sizeBytesMeta = const VerificationMeta('sizeBytes');
  @override
  late final GeneratedColumn<int> sizeBytes = GeneratedColumn<int>(
    'size_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [songId, songJson, filename, status, sizeBytes];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'downloaded_songs';
  @override
  VerificationContext validateIntegrity(Insertable<DownloadedSong> instance, {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('song_id')) {
      context.handle(_songIdMeta, songId.isAcceptableOrUnknown(data['song_id']!, _songIdMeta));
    } else if (isInserting) {
      context.missing(_songIdMeta);
    }
    if (data.containsKey('song_json')) {
      context.handle(_songJsonMeta, songJson.isAcceptableOrUnknown(data['song_json']!, _songJsonMeta));
    } else if (isInserting) {
      context.missing(_songJsonMeta);
    }
    if (data.containsKey('filename')) {
      context.handle(_filenameMeta, filename.isAcceptableOrUnknown(data['filename']!, _filenameMeta));
    } else if (isInserting) {
      context.missing(_filenameMeta);
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta, status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('size_bytes')) {
      context.handle(_sizeBytesMeta, sizeBytes.isAcceptableOrUnknown(data['size_bytes']!, _sizeBytesMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {songId};
  @override
  DownloadedSong map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DownloadedSong(
      songId: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}song_id'])!,
      songJson: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}song_json'])!,
      filename: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}filename'])!,
      status: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      sizeBytes: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}size_bytes'])!,
    );
  }

  @override
  $DownloadedSongsTable createAlias(String alias) {
    return $DownloadedSongsTable(attachedDatabase, alias);
  }
}

class DownloadedSong extends DataClass implements Insertable<DownloadedSong> {
  final String songId;
  final String songJson;
  final String filename;
  final String status;
  final int sizeBytes;
  const DownloadedSong({
    required this.songId,
    required this.songJson,
    required this.filename,
    required this.status,
    required this.sizeBytes,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['song_id'] = Variable<String>(songId);
    map['song_json'] = Variable<String>(songJson);
    map['filename'] = Variable<String>(filename);
    map['status'] = Variable<String>(status);
    map['size_bytes'] = Variable<int>(sizeBytes);
    return map;
  }

  DownloadedSongsCompanion toCompanion(bool nullToAbsent) {
    return DownloadedSongsCompanion(
      songId: Value(songId),
      songJson: Value(songJson),
      filename: Value(filename),
      status: Value(status),
      sizeBytes: Value(sizeBytes),
    );
  }

  factory DownloadedSong.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DownloadedSong(
      songId: serializer.fromJson<String>(json['songId']),
      songJson: serializer.fromJson<String>(json['songJson']),
      filename: serializer.fromJson<String>(json['filename']),
      status: serializer.fromJson<String>(json['status']),
      sizeBytes: serializer.fromJson<int>(json['sizeBytes']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'songId': serializer.toJson<String>(songId),
      'songJson': serializer.toJson<String>(songJson),
      'filename': serializer.toJson<String>(filename),
      'status': serializer.toJson<String>(status),
      'sizeBytes': serializer.toJson<int>(sizeBytes),
    };
  }

  DownloadedSong copyWith({String? songId, String? songJson, String? filename, String? status, int? sizeBytes}) =>
      DownloadedSong(
        songId: songId ?? this.songId,
        songJson: songJson ?? this.songJson,
        filename: filename ?? this.filename,
        status: status ?? this.status,
        sizeBytes: sizeBytes ?? this.sizeBytes,
      );
  DownloadedSong copyWithCompanion(DownloadedSongsCompanion data) {
    return DownloadedSong(
      songId: data.songId.present ? data.songId.value : this.songId,
      songJson: data.songJson.present ? data.songJson.value : this.songJson,
      filename: data.filename.present ? data.filename.value : this.filename,
      status: data.status.present ? data.status.value : this.status,
      sizeBytes: data.sizeBytes.present ? data.sizeBytes.value : this.sizeBytes,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DownloadedSong(')
          ..write('songId: $songId, ')
          ..write('songJson: $songJson, ')
          ..write('filename: $filename, ')
          ..write('status: $status, ')
          ..write('sizeBytes: $sizeBytes')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(songId, songJson, filename, status, sizeBytes);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DownloadedSong &&
          other.songId == this.songId &&
          other.songJson == this.songJson &&
          other.filename == this.filename &&
          other.status == this.status &&
          other.sizeBytes == this.sizeBytes);
}

class DownloadedSongsCompanion extends UpdateCompanion<DownloadedSong> {
  final Value<String> songId;
  final Value<String> songJson;
  final Value<String> filename;
  final Value<String> status;
  final Value<int> sizeBytes;
  final Value<int> rowid;
  const DownloadedSongsCompanion({
    this.songId = const Value.absent(),
    this.songJson = const Value.absent(),
    this.filename = const Value.absent(),
    this.status = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DownloadedSongsCompanion.insert({
    required String songId,
    required String songJson,
    required String filename,
    required String status,
    this.sizeBytes = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : songId = Value(songId),
       songJson = Value(songJson),
       filename = Value(filename),
       status = Value(status);
  static Insertable<DownloadedSong> custom({
    Expression<String>? songId,
    Expression<String>? songJson,
    Expression<String>? filename,
    Expression<String>? status,
    Expression<int>? sizeBytes,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (songId != null) 'song_id': songId,
      if (songJson != null) 'song_json': songJson,
      if (filename != null) 'filename': filename,
      if (status != null) 'status': status,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DownloadedSongsCompanion copyWith({
    Value<String>? songId,
    Value<String>? songJson,
    Value<String>? filename,
    Value<String>? status,
    Value<int>? sizeBytes,
    Value<int>? rowid,
  }) {
    return DownloadedSongsCompanion(
      songId: songId ?? this.songId,
      songJson: songJson ?? this.songJson,
      filename: filename ?? this.filename,
      status: status ?? this.status,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (songId.present) {
      map['song_id'] = Variable<String>(songId.value);
    }
    if (songJson.present) {
      map['song_json'] = Variable<String>(songJson.value);
    }
    if (filename.present) {
      map['filename'] = Variable<String>(filename.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (sizeBytes.present) {
      map['size_bytes'] = Variable<int>(sizeBytes.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DownloadedSongsCompanion(')
          ..write('songId: $songId, ')
          ..write('songJson: $songJson, ')
          ..write('filename: $filename, ')
          ..write('status: $status, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DownloadedCollectionsTable extends DownloadedCollections
    with TableInfo<$DownloadedCollectionsTable, DownloadedCollection> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DownloadedCollectionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceIdMeta = const VerificationMeta('sourceId');
  @override
  late final GeneratedColumn<String> sourceId = GeneratedColumn<String>(
    'source_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _subtitleMeta = const VerificationMeta('subtitle');
  @override
  late final GeneratedColumn<String> subtitle = GeneratedColumn<String>(
    'subtitle',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _coverArtMeta = const VerificationMeta('coverArt');
  @override
  late final GeneratedColumn<String> coverArt = GeneratedColumn<String>(
    'cover_art',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _songsJsonMeta = const VerificationMeta('songsJson');
  @override
  late final GeneratedColumn<String> songsJson = GeneratedColumn<String>(
    'songs_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _addedAtMeta = const VerificationMeta('addedAt');
  @override
  late final GeneratedColumn<DateTime> addedAt = GeneratedColumn<DateTime>(
    'added_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, kind, sourceId, title, subtitle, coverArt, songsJson, addedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'downloaded_collections';
  @override
  VerificationContext validateIntegrity(Insertable<DownloadedCollection> instance, {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(_kindMeta, kind.isAcceptableOrUnknown(data['kind']!, _kindMeta));
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('source_id')) {
      context.handle(_sourceIdMeta, sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta));
    } else if (isInserting) {
      context.missing(_sourceIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(_titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('subtitle')) {
      context.handle(_subtitleMeta, subtitle.isAcceptableOrUnknown(data['subtitle']!, _subtitleMeta));
    } else if (isInserting) {
      context.missing(_subtitleMeta);
    }
    if (data.containsKey('cover_art')) {
      context.handle(_coverArtMeta, coverArt.isAcceptableOrUnknown(data['cover_art']!, _coverArtMeta));
    }
    if (data.containsKey('songs_json')) {
      context.handle(_songsJsonMeta, songsJson.isAcceptableOrUnknown(data['songs_json']!, _songsJsonMeta));
    } else if (isInserting) {
      context.missing(_songsJsonMeta);
    }
    if (data.containsKey('added_at')) {
      context.handle(_addedAtMeta, addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta));
    } else if (isInserting) {
      context.missing(_addedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DownloadedCollection map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DownloadedCollection(
      id: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      kind: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}kind'])!,
      sourceId: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}source_id'])!,
      title: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      subtitle: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}subtitle'])!,
      coverArt: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}cover_art']),
      songsJson: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}songs_json'])!,
      addedAt: attachedDatabase.typeMapping.read(DriftSqlType.dateTime, data['${effectivePrefix}added_at'])!,
    );
  }

  @override
  $DownloadedCollectionsTable createAlias(String alias) {
    return $DownloadedCollectionsTable(attachedDatabase, alias);
  }
}

class DownloadedCollection extends DataClass implements Insertable<DownloadedCollection> {
  final String id;
  final String kind;
  final String sourceId;
  final String title;
  final String subtitle;
  final String? coverArt;
  final String songsJson;
  final DateTime addedAt;
  const DownloadedCollection({
    required this.id,
    required this.kind,
    required this.sourceId,
    required this.title,
    required this.subtitle,
    this.coverArt,
    required this.songsJson,
    required this.addedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['kind'] = Variable<String>(kind);
    map['source_id'] = Variable<String>(sourceId);
    map['title'] = Variable<String>(title);
    map['subtitle'] = Variable<String>(subtitle);
    if (!nullToAbsent || coverArt != null) {
      map['cover_art'] = Variable<String>(coverArt);
    }
    map['songs_json'] = Variable<String>(songsJson);
    map['added_at'] = Variable<DateTime>(addedAt);
    return map;
  }

  DownloadedCollectionsCompanion toCompanion(bool nullToAbsent) {
    return DownloadedCollectionsCompanion(
      id: Value(id),
      kind: Value(kind),
      sourceId: Value(sourceId),
      title: Value(title),
      subtitle: Value(subtitle),
      coverArt: coverArt == null && nullToAbsent ? const Value.absent() : Value(coverArt),
      songsJson: Value(songsJson),
      addedAt: Value(addedAt),
    );
  }

  factory DownloadedCollection.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DownloadedCollection(
      id: serializer.fromJson<String>(json['id']),
      kind: serializer.fromJson<String>(json['kind']),
      sourceId: serializer.fromJson<String>(json['sourceId']),
      title: serializer.fromJson<String>(json['title']),
      subtitle: serializer.fromJson<String>(json['subtitle']),
      coverArt: serializer.fromJson<String?>(json['coverArt']),
      songsJson: serializer.fromJson<String>(json['songsJson']),
      addedAt: serializer.fromJson<DateTime>(json['addedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'kind': serializer.toJson<String>(kind),
      'sourceId': serializer.toJson<String>(sourceId),
      'title': serializer.toJson<String>(title),
      'subtitle': serializer.toJson<String>(subtitle),
      'coverArt': serializer.toJson<String?>(coverArt),
      'songsJson': serializer.toJson<String>(songsJson),
      'addedAt': serializer.toJson<DateTime>(addedAt),
    };
  }

  DownloadedCollection copyWith({
    String? id,
    String? kind,
    String? sourceId,
    String? title,
    String? subtitle,
    Value<String?> coverArt = const Value.absent(),
    String? songsJson,
    DateTime? addedAt,
  }) => DownloadedCollection(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    sourceId: sourceId ?? this.sourceId,
    title: title ?? this.title,
    subtitle: subtitle ?? this.subtitle,
    coverArt: coverArt.present ? coverArt.value : this.coverArt,
    songsJson: songsJson ?? this.songsJson,
    addedAt: addedAt ?? this.addedAt,
  );
  DownloadedCollection copyWithCompanion(DownloadedCollectionsCompanion data) {
    return DownloadedCollection(
      id: data.id.present ? data.id.value : this.id,
      kind: data.kind.present ? data.kind.value : this.kind,
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
      title: data.title.present ? data.title.value : this.title,
      subtitle: data.subtitle.present ? data.subtitle.value : this.subtitle,
      coverArt: data.coverArt.present ? data.coverArt.value : this.coverArt,
      songsJson: data.songsJson.present ? data.songsJson.value : this.songsJson,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DownloadedCollection(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('sourceId: $sourceId, ')
          ..write('title: $title, ')
          ..write('subtitle: $subtitle, ')
          ..write('coverArt: $coverArt, ')
          ..write('songsJson: $songsJson, ')
          ..write('addedAt: $addedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, kind, sourceId, title, subtitle, coverArt, songsJson, addedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DownloadedCollection &&
          other.id == this.id &&
          other.kind == this.kind &&
          other.sourceId == this.sourceId &&
          other.title == this.title &&
          other.subtitle == this.subtitle &&
          other.coverArt == this.coverArt &&
          other.songsJson == this.songsJson &&
          other.addedAt == this.addedAt);
}

class DownloadedCollectionsCompanion extends UpdateCompanion<DownloadedCollection> {
  final Value<String> id;
  final Value<String> kind;
  final Value<String> sourceId;
  final Value<String> title;
  final Value<String> subtitle;
  final Value<String?> coverArt;
  final Value<String> songsJson;
  final Value<DateTime> addedAt;
  final Value<int> rowid;
  const DownloadedCollectionsCompanion({
    this.id = const Value.absent(),
    this.kind = const Value.absent(),
    this.sourceId = const Value.absent(),
    this.title = const Value.absent(),
    this.subtitle = const Value.absent(),
    this.coverArt = const Value.absent(),
    this.songsJson = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DownloadedCollectionsCompanion.insert({
    required String id,
    required String kind,
    required String sourceId,
    required String title,
    required String subtitle,
    this.coverArt = const Value.absent(),
    required String songsJson,
    required DateTime addedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       kind = Value(kind),
       sourceId = Value(sourceId),
       title = Value(title),
       subtitle = Value(subtitle),
       songsJson = Value(songsJson),
       addedAt = Value(addedAt);
  static Insertable<DownloadedCollection> custom({
    Expression<String>? id,
    Expression<String>? kind,
    Expression<String>? sourceId,
    Expression<String>? title,
    Expression<String>? subtitle,
    Expression<String>? coverArt,
    Expression<String>? songsJson,
    Expression<DateTime>? addedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (kind != null) 'kind': kind,
      if (sourceId != null) 'source_id': sourceId,
      if (title != null) 'title': title,
      if (subtitle != null) 'subtitle': subtitle,
      if (coverArt != null) 'cover_art': coverArt,
      if (songsJson != null) 'songs_json': songsJson,
      if (addedAt != null) 'added_at': addedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DownloadedCollectionsCompanion copyWith({
    Value<String>? id,
    Value<String>? kind,
    Value<String>? sourceId,
    Value<String>? title,
    Value<String>? subtitle,
    Value<String?>? coverArt,
    Value<String>? songsJson,
    Value<DateTime>? addedAt,
    Value<int>? rowid,
  }) {
    return DownloadedCollectionsCompanion(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      sourceId: sourceId ?? this.sourceId,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      coverArt: coverArt ?? this.coverArt,
      songsJson: songsJson ?? this.songsJson,
      addedAt: addedAt ?? this.addedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (sourceId.present) {
      map['source_id'] = Variable<String>(sourceId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (subtitle.present) {
      map['subtitle'] = Variable<String>(subtitle.value);
    }
    if (coverArt.present) {
      map['cover_art'] = Variable<String>(coverArt.value);
    }
    if (songsJson.present) {
      map['songs_json'] = Variable<String>(songsJson.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<DateTime>(addedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DownloadedCollectionsCompanion(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('sourceId: $sourceId, ')
          ..write('title: $title, ')
          ..write('subtitle: $subtitle, ')
          ..write('coverArt: $coverArt, ')
          ..write('songsJson: $songsJson, ')
          ..write('addedAt: $addedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ApiCacheTable apiCache = $ApiCacheTable(this);
  late final $KeyValuesTable keyValues = $KeyValuesTable(this);
  late final $DownloadedSongsTable downloadedSongs = $DownloadedSongsTable(this);
  late final $DownloadedCollectionsTable downloadedCollections = $DownloadedCollectionsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [apiCache, keyValues, downloadedSongs, downloadedCollections];
}

typedef $$ApiCacheTableCreateCompanionBuilder =
    ApiCacheCompanion Function({
      required String key,
      required String body,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$ApiCacheTableUpdateCompanionBuilder =
    ApiCacheCompanion Function({Value<String> key, Value<String> body, Value<DateTime> updatedAt, Value<int> rowid});

class $$ApiCacheTableFilterComposer extends Composer<_$AppDatabase, $ApiCacheTable> {
  $$ApiCacheTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get body => $composableBuilder(column: $table.body, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$ApiCacheTableOrderingComposer extends Composer<_$AppDatabase, $ApiCacheTable> {
  $$ApiCacheTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$ApiCacheTableAnnotationComposer extends Composer<_$AppDatabase, $ApiCacheTable> {
  $$ApiCacheTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key => $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get body => $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt => $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$ApiCacheTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ApiCacheTable,
          ApiCacheData,
          $$ApiCacheTableFilterComposer,
          $$ApiCacheTableOrderingComposer,
          $$ApiCacheTableAnnotationComposer,
          $$ApiCacheTableCreateCompanionBuilder,
          $$ApiCacheTableUpdateCompanionBuilder,
          (ApiCacheData, BaseReferences<_$AppDatabase, $ApiCacheTable, ApiCacheData>),
          ApiCacheData,
          PrefetchHooks Function()
        > {
  $$ApiCacheTableTableManager(_$AppDatabase db, $ApiCacheTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () => $$ApiCacheTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () => $$ApiCacheTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () => $$ApiCacheTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> body = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ApiCacheCompanion(key: key, body: body, updatedAt: updatedAt, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String body,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => ApiCacheCompanion.insert(key: key, body: body, updatedAt: updatedAt, rowid: rowid),
          withReferenceMapper: (p0) => p0.map((e) => (e.readTable(table), BaseReferences(db, table, e))).toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ApiCacheTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ApiCacheTable,
      ApiCacheData,
      $$ApiCacheTableFilterComposer,
      $$ApiCacheTableOrderingComposer,
      $$ApiCacheTableAnnotationComposer,
      $$ApiCacheTableCreateCompanionBuilder,
      $$ApiCacheTableUpdateCompanionBuilder,
      (ApiCacheData, BaseReferences<_$AppDatabase, $ApiCacheTable, ApiCacheData>),
      ApiCacheData,
      PrefetchHooks Function()
    >;
typedef $$KeyValuesTableCreateCompanionBuilder =
    KeyValuesCompanion Function({required String key, required String value, Value<int> rowid});
typedef $$KeyValuesTableUpdateCompanionBuilder =
    KeyValuesCompanion Function({Value<String> key, Value<String> value, Value<int> rowid});

class $$KeyValuesTableFilterComposer extends Composer<_$AppDatabase, $KeyValuesTable> {
  $$KeyValuesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => ColumnFilters(column));
}

class $$KeyValuesTableOrderingComposer extends Composer<_$AppDatabase, $KeyValuesTable> {
  $$KeyValuesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => ColumnOrderings(column));
}

class $$KeyValuesTableAnnotationComposer extends Composer<_$AppDatabase, $KeyValuesTable> {
  $$KeyValuesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key => $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value => $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$KeyValuesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $KeyValuesTable,
          KeyValue,
          $$KeyValuesTableFilterComposer,
          $$KeyValuesTableOrderingComposer,
          $$KeyValuesTableAnnotationComposer,
          $$KeyValuesTableCreateCompanionBuilder,
          $$KeyValuesTableUpdateCompanionBuilder,
          (KeyValue, BaseReferences<_$AppDatabase, $KeyValuesTable, KeyValue>),
          KeyValue,
          PrefetchHooks Function()
        > {
  $$KeyValuesTableTableManager(_$AppDatabase db, $KeyValuesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () => $$KeyValuesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () => $$KeyValuesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () => $$KeyValuesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => KeyValuesCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({required String key, required String value, Value<int> rowid = const Value.absent()}) =>
                  KeyValuesCompanion.insert(key: key, value: value, rowid: rowid),
          withReferenceMapper: (p0) => p0.map((e) => (e.readTable(table), BaseReferences(db, table, e))).toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$KeyValuesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $KeyValuesTable,
      KeyValue,
      $$KeyValuesTableFilterComposer,
      $$KeyValuesTableOrderingComposer,
      $$KeyValuesTableAnnotationComposer,
      $$KeyValuesTableCreateCompanionBuilder,
      $$KeyValuesTableUpdateCompanionBuilder,
      (KeyValue, BaseReferences<_$AppDatabase, $KeyValuesTable, KeyValue>),
      KeyValue,
      PrefetchHooks Function()
    >;
typedef $$DownloadedSongsTableCreateCompanionBuilder =
    DownloadedSongsCompanion Function({
      required String songId,
      required String songJson,
      required String filename,
      required String status,
      Value<int> sizeBytes,
      Value<int> rowid,
    });
typedef $$DownloadedSongsTableUpdateCompanionBuilder =
    DownloadedSongsCompanion Function({
      Value<String> songId,
      Value<String> songJson,
      Value<String> filename,
      Value<String> status,
      Value<int> sizeBytes,
      Value<int> rowid,
    });

class $$DownloadedSongsTableFilterComposer extends Composer<_$AppDatabase, $DownloadedSongsTable> {
  $$DownloadedSongsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get songId =>
      $composableBuilder(column: $table.songId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get songJson =>
      $composableBuilder(column: $table.songJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get filename =>
      $composableBuilder(column: $table.filename, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => ColumnFilters(column));
}

class $$DownloadedSongsTableOrderingComposer extends Composer<_$AppDatabase, $DownloadedSongsTable> {
  $$DownloadedSongsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get songId =>
      $composableBuilder(column: $table.songId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get songJson =>
      $composableBuilder(column: $table.songJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get filename =>
      $composableBuilder(column: $table.filename, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => ColumnOrderings(column));
}

class $$DownloadedSongsTableAnnotationComposer extends Composer<_$AppDatabase, $DownloadedSongsTable> {
  $$DownloadedSongsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get songId => $composableBuilder(column: $table.songId, builder: (column) => column);

  GeneratedColumn<String> get songJson => $composableBuilder(column: $table.songJson, builder: (column) => column);

  GeneratedColumn<String> get filename => $composableBuilder(column: $table.filename, builder: (column) => column);

  GeneratedColumn<String> get status => $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get sizeBytes => $composableBuilder(column: $table.sizeBytes, builder: (column) => column);
}

class $$DownloadedSongsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DownloadedSongsTable,
          DownloadedSong,
          $$DownloadedSongsTableFilterComposer,
          $$DownloadedSongsTableOrderingComposer,
          $$DownloadedSongsTableAnnotationComposer,
          $$DownloadedSongsTableCreateCompanionBuilder,
          $$DownloadedSongsTableUpdateCompanionBuilder,
          (DownloadedSong, BaseReferences<_$AppDatabase, $DownloadedSongsTable, DownloadedSong>),
          DownloadedSong,
          PrefetchHooks Function()
        > {
  $$DownloadedSongsTableTableManager(_$AppDatabase db, $DownloadedSongsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () => $$DownloadedSongsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () => $$DownloadedSongsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () => $$DownloadedSongsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> songId = const Value.absent(),
                Value<String> songJson = const Value.absent(),
                Value<String> filename = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> sizeBytes = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DownloadedSongsCompanion(
                songId: songId,
                songJson: songJson,
                filename: filename,
                status: status,
                sizeBytes: sizeBytes,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String songId,
                required String songJson,
                required String filename,
                required String status,
                Value<int> sizeBytes = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DownloadedSongsCompanion.insert(
                songId: songId,
                songJson: songJson,
                filename: filename,
                status: status,
                sizeBytes: sizeBytes,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0.map((e) => (e.readTable(table), BaseReferences(db, table, e))).toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DownloadedSongsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DownloadedSongsTable,
      DownloadedSong,
      $$DownloadedSongsTableFilterComposer,
      $$DownloadedSongsTableOrderingComposer,
      $$DownloadedSongsTableAnnotationComposer,
      $$DownloadedSongsTableCreateCompanionBuilder,
      $$DownloadedSongsTableUpdateCompanionBuilder,
      (DownloadedSong, BaseReferences<_$AppDatabase, $DownloadedSongsTable, DownloadedSong>),
      DownloadedSong,
      PrefetchHooks Function()
    >;
typedef $$DownloadedCollectionsTableCreateCompanionBuilder =
    DownloadedCollectionsCompanion Function({
      required String id,
      required String kind,
      required String sourceId,
      required String title,
      required String subtitle,
      Value<String?> coverArt,
      required String songsJson,
      required DateTime addedAt,
      Value<int> rowid,
    });
typedef $$DownloadedCollectionsTableUpdateCompanionBuilder =
    DownloadedCollectionsCompanion Function({
      Value<String> id,
      Value<String> kind,
      Value<String> sourceId,
      Value<String> title,
      Value<String> subtitle,
      Value<String?> coverArt,
      Value<String> songsJson,
      Value<DateTime> addedAt,
      Value<int> rowid,
    });

class $$DownloadedCollectionsTableFilterComposer extends Composer<_$AppDatabase, $DownloadedCollectionsTable> {
  $$DownloadedCollectionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get kind => $composableBuilder(column: $table.kind, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get sourceId =>
      $composableBuilder(column: $table.sourceId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get subtitle =>
      $composableBuilder(column: $table.subtitle, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get coverArt =>
      $composableBuilder(column: $table.coverArt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get songsJson =>
      $composableBuilder(column: $table.songsJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => ColumnFilters(column));
}

class $$DownloadedCollectionsTableOrderingComposer extends Composer<_$AppDatabase, $DownloadedCollectionsTable> {
  $$DownloadedCollectionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get sourceId =>
      $composableBuilder(column: $table.sourceId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get subtitle =>
      $composableBuilder(column: $table.subtitle, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get coverArt =>
      $composableBuilder(column: $table.coverArt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get songsJson =>
      $composableBuilder(column: $table.songsJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => ColumnOrderings(column));
}

class $$DownloadedCollectionsTableAnnotationComposer extends Composer<_$AppDatabase, $DownloadedCollectionsTable> {
  $$DownloadedCollectionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id => $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get kind => $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get sourceId => $composableBuilder(column: $table.sourceId, builder: (column) => column);

  GeneratedColumn<String> get title => $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get subtitle => $composableBuilder(column: $table.subtitle, builder: (column) => column);

  GeneratedColumn<String> get coverArt => $composableBuilder(column: $table.coverArt, builder: (column) => column);

  GeneratedColumn<String> get songsJson => $composableBuilder(column: $table.songsJson, builder: (column) => column);

  GeneratedColumn<DateTime> get addedAt => $composableBuilder(column: $table.addedAt, builder: (column) => column);
}

class $$DownloadedCollectionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DownloadedCollectionsTable,
          DownloadedCollection,
          $$DownloadedCollectionsTableFilterComposer,
          $$DownloadedCollectionsTableOrderingComposer,
          $$DownloadedCollectionsTableAnnotationComposer,
          $$DownloadedCollectionsTableCreateCompanionBuilder,
          $$DownloadedCollectionsTableUpdateCompanionBuilder,
          (DownloadedCollection, BaseReferences<_$AppDatabase, $DownloadedCollectionsTable, DownloadedCollection>),
          DownloadedCollection,
          PrefetchHooks Function()
        > {
  $$DownloadedCollectionsTableTableManager(_$AppDatabase db, $DownloadedCollectionsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () => $$DownloadedCollectionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () => $$DownloadedCollectionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () => $$DownloadedCollectionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> sourceId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> subtitle = const Value.absent(),
                Value<String?> coverArt = const Value.absent(),
                Value<String> songsJson = const Value.absent(),
                Value<DateTime> addedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DownloadedCollectionsCompanion(
                id: id,
                kind: kind,
                sourceId: sourceId,
                title: title,
                subtitle: subtitle,
                coverArt: coverArt,
                songsJson: songsJson,
                addedAt: addedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String kind,
                required String sourceId,
                required String title,
                required String subtitle,
                Value<String?> coverArt = const Value.absent(),
                required String songsJson,
                required DateTime addedAt,
                Value<int> rowid = const Value.absent(),
              }) => DownloadedCollectionsCompanion.insert(
                id: id,
                kind: kind,
                sourceId: sourceId,
                title: title,
                subtitle: subtitle,
                coverArt: coverArt,
                songsJson: songsJson,
                addedAt: addedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0.map((e) => (e.readTable(table), BaseReferences(db, table, e))).toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DownloadedCollectionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DownloadedCollectionsTable,
      DownloadedCollection,
      $$DownloadedCollectionsTableFilterComposer,
      $$DownloadedCollectionsTableOrderingComposer,
      $$DownloadedCollectionsTableAnnotationComposer,
      $$DownloadedCollectionsTableCreateCompanionBuilder,
      $$DownloadedCollectionsTableUpdateCompanionBuilder,
      (DownloadedCollection, BaseReferences<_$AppDatabase, $DownloadedCollectionsTable, DownloadedCollection>),
      DownloadedCollection,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ApiCacheTableTableManager get apiCache => $$ApiCacheTableTableManager(_db, _db.apiCache);
  $$KeyValuesTableTableManager get keyValues => $$KeyValuesTableTableManager(_db, _db.keyValues);
  $$DownloadedSongsTableTableManager get downloadedSongs =>
      $$DownloadedSongsTableTableManager(_db, _db.downloadedSongs);
  $$DownloadedCollectionsTableTableManager get downloadedCollections =>
      $$DownloadedCollectionsTableTableManager(_db, _db.downloadedCollections);
}
