import 'dart:async';

import 'package:dio/dio.dart';

import '../soulbeet/soulbeet_models.dart';

/// Deezer didn't answer, or answered with an error.
class DeezerException implements Exception {
  const DeezerException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// An artist on Deezer, with how many people follow them.
class DeezerArtist {
  const DeezerArtist(this.id, this.name, {this.fans = 0, this.picture});
  final String id;
  final String name;
  final int fans;
  final Uri? picture;
}

/// What Deezer says about one album: its barcode, which finds the same
/// album on MusicBrainz.
class DeezerAlbumInfo {
  const DeezerAlbumInfo({required this.title, required this.artist, this.upc, this.releaseDate, this.kind});
  final String title;
  final String artist;
  final String? upc;
  final String? releaseDate;

  /// "album", "single", "ep" or "compile".
  final String? kind;

  bool get isSingle => kind == 'single';
}

/// Searches Deezer's catalogue for Get music. Sends only the words searched
/// for; Deezer needs no account or key.
///
/// MusicBrainz's search matches names exactly as it has them: "kanye bully"
/// found nothing (MusicBrainz credits Ye), a typo found nothing, and its
/// results come in no useful order. Deezer's search, like a streaming app's,
/// forgives typos and puts the most played first, in well under a second.
/// What's picked is then looked up on MusicBrainz by its barcode
/// (`MusicBrainzClient.pressingOf`), as Soulbeet files music by MusicBrainz.
///
/// Deezer takes 50 requests every 5 seconds, far more than a search needs,
/// so nothing waits in line. Replies are kept a while.
class DeezerClient {
  DeezerClient({
    Dio? dio,
    this.base = 'https://api.deezer.com',
    this.keep = 100,
    this.quotaWait = const Duration(seconds: 1),
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 6),
               receiveTimeout: const Duration(seconds: 10),
               headers: {'Accept': 'application/json'},
             ),
           );

  final String base;

  /// How many replies to keep.
  final int keep;

  /// How long to wait before asking again when Deezer says too many
  /// requests came at once.
  final Duration quotaWait;

  final Dio _dio;
  final _kept = <String, Map<String, Object?>>{};

  void close() => _dio.close(force: true);

  /// Songs matching [words], most played and best matched first, each once
  /// (a song on an album and on its deluxe pressing is listed once).
  Future<List<SbTrack>> searchSongs(String words) async => _once([
    for (final t in _list((await _get('/search', {'q': words, 'limit': '25'}))['data'])) ?_song(t),
  ]);

  /// Albums and EPs matching [words], best first, each once (Deezer lists
  /// the clean and explicit copies apart). Singles are left out: their song
  /// is found as a song.
  Future<List<SbAlbum>> searchAlbums(String words) async => _once([
    for (final a in _list((await _get('/search/album', {'q': words, 'limit': '25'}))['data']))
      if (a['record_type'] != 'single') ?_album(a),
  ]);

  /// Artists matching [words], best first.
  Future<List<DeezerArtist>> searchArtists(String words) async => [
    for (final a in _list((await _get('/search/artist', {'q': words, 'limit': '5'}))['data'])) ?_artist(a),
  ];

  /// [artist]'s albums and EPs, most followed first.
  Future<List<SbAlbum>> albumsBy(DeezerArtist artist) async {
    final reply = await _get('/artist/${artist.id}/albums', {'limit': '100'});
    final found = [
      for (final a in _list(reply['data']))
        if (a['record_type'] != 'single')
          if (_album(a, artist: artist.name) case final album?) (album, _int(a['fans'])),
    ];
    final order = {for (final (i, f) in found.indexed) f.$1: i};
    found.sort((a, b) {
      final c = b.$2.compareTo(a.$2);
      return c != 0 ? c : order[a.$1]!.compareTo(order[b.$1]!);
    });
    return _once([for (final (album, _) in found) album]);
  }

  /// Artists whose listeners also play [artist], likeliest first.
  Future<List<DeezerArtist>> related(DeezerArtist artist) async => [
    for (final a in _list((await _get('/artist/${artist.id}/related', {'limit': '20'}))['data'])) ?_artist(a),
  ];

  /// [artist]'s most played songs, each once.
  Future<List<SbTrack>> topSongs(DeezerArtist artist) async => _once([
    for (final t in _list((await _get('/artist/${artist.id}/top', {'limit': '10'}))['data'])) ?_song(t),
  ]);

  /// The first of each title by each artist, ignoring case and punctuation.
  static List<T> _once<T>(List<T> found) {
    String plain(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    final seen = <String>{};
    return [
      for (final x in found)
        if (seen.add(
          x is SbAlbum ? '${plain(x.title)}|${plain(x.artist)}' : '${plain((x as SbTrack).title)}|${plain(x.artist)}',
        ))
          x,
    ];
  }

  /// One album's barcode and details, by its Deezer id.
  Future<DeezerAlbumInfo> album(String id) async {
    final a = await _get('/album/$id', const {});
    final title = a['title'];
    if (title is! String) throw const DeezerException('Deezer sent something unexpected.');
    final upc = a['upc'];
    return DeezerAlbumInfo(
      title: title,
      artist: _name(a['artist']) ?? '',
      upc: upc is String && upc.isNotEmpty ? upc : null,
      releaseDate: a['release_date'] as String?,
      kind: a['record_type'] as String?,
    );
  }

  Future<Map<String, Object?>> _get(String path, Map<String, String> params) async {
    final key = '$path?${params.entries.map((e) => '${e.key}=${e.value}').join('&')}';
    final kept = _kept.remove(key);
    if (kept != null) return _kept[key] = kept;
    for (var attempt = 1; ; attempt++) {
      final Object? data;
      try {
        data = (await _dio.get<Object>('$base$path', queryParameters: params)).data;
      } on DioException {
        throw const DeezerException('Couldn\'t reach Deezer.');
      }
      if (data is! Map<String, Object?>) throw const DeezerException('Deezer sent something unexpected.');
      // Deezer answers errors as 200s: {"error": {"code": 4, ...}} is "too
      // many requests at once".
      final error = data['error'];
      if (error is Map) {
        if (error['code'] == 4 && attempt < 3) {
          await Future<void>.delayed(quotaWait);
          continue;
        }
        throw DeezerException('Deezer said: ${error['message'] ?? error}');
      }
      _kept[key] = data;
      while (_kept.length > keep) {
        _kept.remove(_kept.keys.first);
      }
      return data;
    }
  }

  static SbTrack? _song(Map<String, Object?> t) {
    final id = t['id'], title = t['title'];
    final album = t['album'] is Map ? (t['album']! as Map).cast<String, Object?>() : const <String, Object?>{};
    if (id == null || title is! String) return null;
    return SbTrack.deezer(
      id: '$id',
      title: title,
      artist: _name(t['artist']) ?? '',
      albumId: album['id'] == null ? null : '${album['id']}',
      albumTitle: album['title'] as String?,
      seconds: _int(t['duration']),
      cover: _uri(album['cover_medium']),
    );
  }

  static SbAlbum? _album(Map<String, Object?> a, {String? artist}) {
    final id = a['id'], title = a['title'];
    if (id == null || title is! String) return null;
    return SbAlbum.deezer(
      id: '$id',
      title: title,
      artist: _name(a['artist']) ?? artist ?? '',
      releaseDate: a['release_date'] as String?,
      kinds: a['record_type'] == 'compile' ? const ['Compilation'] : const [],
      cover: _uri(a['cover_medium']),
    );
  }

  static DeezerArtist? _artist(Map<String, Object?> a) {
    final id = a['id'], name = a['name'];
    if (id == null || name is! String) return null;
    return DeezerArtist('$id', name, fans: _int(a['nb_fan']), picture: _uri(a['picture_medium']));
  }

  static String? _name(Object? artist) => artist is Map && artist['name'] is String ? artist['name']! as String : null;

  static int _int(Object? v) => v is num ? v.toInt() : 0;

  static Uri? _uri(Object? v) => v is String && v.startsWith('https://') ? Uri.tryParse(v) : null;

  static Iterable<Map<String, Object?>> _list(Object? v) =>
      v is List ? v.whereType<Map<Object?, Object?>>().map((m) => m.cast<String, Object?>()) : const [];
}
