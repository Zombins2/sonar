import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'models.dart';

/// Where to put successful read responses, and where to find them again
/// when the server can't be reached. Implemented by the app's drift DB.
abstract interface class ResponseCache {
  Future<Json?> read(String key);
  Future<void> write(String key, Json value);
}

enum SubsonicErrorKind { unreachable, badCredentials, notHttps, server }

class SubsonicException implements Exception {
  const SubsonicException(this.kind, this.message, {this.code});
  final SubsonicErrorKind kind;
  final String message;
  final int? code;

  @override
  String toString() => message;
}

class ServerCredentials {
  const ServerCredentials({required this.baseUrl, required this.username, required this.password});
  final String baseUrl;
  final String username;
  final String password;
}

/// Typed Subsonic API client. UI-agnostic: no Flutter imports.
///
/// Uses token auth (`t = md5(password + salt)`, new salt per request), so the
/// plain password never appears in a URL. Nothing here logs URLs or tokens.
class SubsonicClient {
  SubsonicClient(this.credentials, {this.cache, this.onReachability, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 20),
              responseType: ResponseType.json,
            ),
          );

  static const apiVersion = '1.16.1';

  /// Sent as `c`. The desktop app names itself apart from the phone, so the
  /// server's saved queue says which device left it.
  static String clientName = 'sonar';
  static const desktopClientName = 'sonar-desktop';

  final ServerCredentials credentials;
  final ResponseCache? cache;

  /// Called with `true` after any successful request, `false` after a network failure.
  final void Function(bool reachable)? onReachability;
  final Dio _dio;
  final _random = Random.secure();

  String get _base {
    final b = credentials.baseUrl.trim();
    return b.endsWith('/') ? b.substring(0, b.length - 1) : b;
  }

  /// Validates and normalises a user-entered server URL. Throws [SubsonicException].
  static String normaliseUrl(String input) {
    var url = input.trim();
    if (url.isEmpty) {
      throw const SubsonicException(SubsonicErrorKind.notHttps, 'Enter your server URL.');
    }
    if (!url.contains('://')) url = 'https://$url';
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      throw const SubsonicException(SubsonicErrorKind.notHttps, 'That doesn\'t look like a valid URL.');
    }
    // Plain http only to this same computer (the desktop app next to its
    // server): that traffic never leaves the machine.
    final local = uri.scheme == 'http' && _loopbackHosts.contains(uri.host);
    if (uri.scheme != 'https' && !local) {
      throw const SubsonicException(
        SubsonicErrorKind.notHttps,
        'The server URL must use https://. A Tailscale ts.net address or a reverse proxy with a certificate both work.',
      );
    }
    return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  static const _loopbackHosts = {'localhost', '127.0.0.1', '[::1]', '::1'};

  Map<String, String> _authParams() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final salt = List.generate(12, (_) => chars[_random.nextInt(chars.length)]).join();
    final token = md5.convert(utf8.encode(credentials.password + salt)).toString();
    return {'u': credentials.username, 't': token, 's': salt, 'v': apiVersion, 'c': clientName, 'f': 'json'};
  }

  /// A fresh `{u, t, s}` (new salt), for Sonar Connect to prove the login to
  /// its relay, which checks it with this server. Sent in a request body.
  Map<String, String> loginProof() {
    final p = _authParams();
    return {'u': p['u']!, 't': p['t']!, 's': p['s']!};
  }

  static bool isLoopback(String host) => _loopbackHosts.contains(host);

  /// Builds an authenticated URL (cover art, streams, downloads). These
  /// contain a one-time token, never the password.
  Uri buildUrl(String endpoint, [Map<String, Object?> params = const {}]) {
    final query = <String, String>{..._authParams()};
    params.forEach((k, v) {
      if (v != null) query[k] = '$v';
    });
    return Uri.parse('$_base/rest/$endpoint').replace(queryParameters: query);
  }

  static String _cacheKey(String endpoint, Map<String, Object?> params) {
    final keys = params.keys.where((k) => params[k] != null).toList()..sort();
    return '$endpoint?${keys.map((k) => '$k=${params[k]}').join('&')}';
  }

  /// Performs a request and returns the unwrapped `subsonic-response` body.
  /// With [cached], a successful response is stored and served back when the
  /// server is unreachable.
  Future<Json> request(String endpoint, {Map<String, Object?> params = const {}, bool cached = false}) async {
    final key = _cacheKey(endpoint, params);
    try {
      final res = await _dio.getUri<Object>(buildUrl(endpoint, params));
      final body = _unwrap(res.data);
      onReachability?.call(true);
      if (cached) await cache?.write(key, body);
      return body;
    } on DioException catch (e) {
      final unreachable = _isNetworkError(e);
      if (unreachable) onReachability?.call(false);
      if (cached && cache != null) {
        final hit = await cache!.read(key);
        if (hit != null) return hit;
      }
      if (unreachable) {
        throw const SubsonicException(SubsonicErrorKind.unreachable, 'Server unreachable. Check your network, or your VPN if you use one (e.g. Tailscale).');
      }
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        throw const SubsonicException(SubsonicErrorKind.badCredentials, 'Wrong username or password.');
      }
      throw SubsonicException(
        SubsonicErrorKind.server,
        status == null ? 'Request failed.' : 'Server responded with HTTP $status.',
      );
    }
  }

  static bool _isNetworkError(DioException e) => switch (e.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.connectionError => true,
    DioExceptionType.unknown => e.error is SocketException || e.error is HandshakeException,
    _ => false,
  };

  static Json _unwrap(Object? data) {
    Object? decoded = data;
    if (decoded is String) {
      try {
        decoded = jsonDecode(decoded);
      } on FormatException {
        throw const SubsonicException(
          SubsonicErrorKind.server,
          'That URL answered, but it isn\'t a Navidrome / Subsonic server.',
        );
      }
    }
    final root = decoded is Map ? decoded['subsonic-response'] : null;
    if (root is! Map) {
      throw const SubsonicException(
        SubsonicErrorKind.server,
        'That URL answered, but it isn\'t a Navidrome / Subsonic server.',
      );
    }
    final body = root.cast<String, dynamic>();
    if (body['status'] != 'ok') {
      final err = body['error'];
      final code = err is Map ? (err['code'] as num?)?.toInt() : null;
      final message = err is Map ? '${err['message'] ?? 'Unknown server error'}' : 'Unknown server error';
      if (code == 40 || code == 41 || code == 44) {
        throw SubsonicException(SubsonicErrorKind.badCredentials, 'Wrong username or password.', code: code);
      }
      throw SubsonicException(SubsonicErrorKind.server, message, code: code);
    }
    return body;
  }

  // ---- Endpoints ---------------------------------------------------------

  Future<void> ping() => request('ping');

  Future<List<Album>> getAlbumList2(AlbumListType type, {int size = 20, int offset = 0}) async {
    final body = await request(
      'getAlbumList2',
      params: {'type': type.name, 'size': size, 'offset': offset},
      cached: type != AlbumListType.random,
    );
    return jsonList((body['albumList2'] as Map?)?['album']).map(Album.fromJson).toList();
  }

  Future<List<Genre>> getGenres() async {
    final body = await request('getGenres', cached: true);
    return jsonList((body['genres'] as Map?)?['genre']).map(Genre.fromJson).where((g) => g.name.isNotEmpty).toList();
  }

  Future<List<Album>> getAlbumsByGenre(String genre, {int size = 60, int offset = 0}) async {
    final body = await request(
      'getAlbumList2',
      params: {'type': 'byGenre', 'genre': genre, 'size': size, 'offset': offset},
      cached: true,
    );
    return jsonList((body['albumList2'] as Map?)?['album']).map(Album.fromJson).toList();
  }

  Future<List<Song>> getRandomSongs({String? genre, int size = 50}) async {
    final body = await request('getRandomSongs', params: {'size': size, 'genre': genre});
    return jsonList((body['randomSongs'] as Map?)?['song']).map(Song.fromJson).toList();
  }

  /// Songs in the library like [id] (a song, album or artist id), from the
  /// server's Last.fm / ListenBrainz agents. Empty when nothing matches.
  Future<List<Song>> getSimilarSongs2(String id, {int count = 50}) async {
    final body = await request('getSimilarSongs2', params: {'id': id, 'count': count});
    return jsonList((body['similarSongs2'] as Map?)?['song']).map(Song.fromJson).toList();
  }

  /// An artist's most popular songs that are in the library. Takes the name, not the id.
  Future<List<Song>> getTopSongs(String artist, {int count = 10}) async {
    final body = await request('getTopSongs', params: {'artist': artist, 'count': count}, cached: true);
    return jsonList((body['topSongs'] as Map?)?['song']).map(Song.fromJson).toList();
  }

  Future<ArtistInfo> getArtistInfo2(String id, {int count = 12}) async {
    final body = await request('getArtistInfo2', params: {'id': id, 'count': count}, cached: true);
    return ArtistInfo.fromJson((body['artistInfo2'] as Map?)?.cast() ?? const {});
  }

  Future<List<Artist>> getArtists() async {
    final body = await request('getArtists', cached: true);
    final indexes = jsonList((body['artists'] as Map?)?['index']);
    return [for (final i in indexes) ...jsonList(i['artist']).map(Artist.fromJson)];
  }

  Future<Artist> getArtist(String id) async {
    final body = await request('getArtist', params: {'id': id}, cached: true);
    return Artist.fromJson((body['artist'] as Map).cast());
  }

  Future<Album> getAlbum(String id) async {
    final body = await request('getAlbum', params: {'id': id}, cached: true);
    return Album.fromJson((body['album'] as Map).cast());
  }

  Future<Song> getSong(String id) async {
    final body = await request('getSong', params: {'id': id}, cached: true);
    return Song.fromJson((body['song'] as Map).cast());
  }

  Future<SearchResult> search3(
    String query, {
    int artistCount = 20,
    int albumCount = 20,
    int songCount = 20,
    int songOffset = 0,
    int albumOffset = 0,
    int artistOffset = 0,
    bool cached = false,
  }) async {
    final body = await request(
      'search3',
      cached: cached,
      params: {
        'query': query,
        'artistCount': artistCount,
        'albumCount': albumCount,
        'songCount': songCount,
        'songOffset': songOffset,
        'albumOffset': albumOffset,
        'artistOffset': artistOffset,
      },
    );
    return SearchResult.fromJson((body['searchResult3'] as Map?)?.cast() ?? const {});
  }

  Future<List<Playlist>> getPlaylists() async {
    final body = await request('getPlaylists', cached: true);
    return jsonList((body['playlists'] as Map?)?['playlist']).map(Playlist.fromJson).toList();
  }

  Future<Playlist> getPlaylist(String id) async {
    final body = await request('getPlaylist', params: {'id': id}, cached: true);
    return Playlist.fromJson((body['playlist'] as Map).cast());
  }

  Future<void> createPlaylist(String name, {List<String> songIds = const []}) =>
      _createPlaylist({'name': name}, songIds);

  /// Replaces a playlist's tracks with [songIds], in order. Covers reorder and remove.
  Future<void> replacePlaylistSongs(String playlistId, List<String> songIds) =>
      _createPlaylist({'playlistId': playlistId}, songIds);

  Future<void> _createPlaylist(Map<String, Object?> params, List<String> songIds) async {
    // Repeated `songId` params need a raw query string.
    final uri = buildUrl('createPlaylist', params);
    final extra = songIds.map((id) => 'songId=${Uri.encodeQueryComponent(id)}').join('&');
    await _rawGet(extra.isEmpty ? uri : Uri.parse('$uri&$extra'));
  }

  Future<void> renamePlaylist(String playlistId, String name) =>
      request('updatePlaylist', params: {'playlistId': playlistId, 'name': name});

  Future<void> deletePlaylist(String playlistId) => request('deletePlaylist', params: {'id': playlistId});

  Future<void> addToPlaylist(String playlistId, List<String> songIds) async {
    final uri = buildUrl('updatePlaylist', {'playlistId': playlistId});
    final extra = songIds.map((id) => 'songIdToAdd=${Uri.encodeQueryComponent(id)}').join('&');
    await _rawGet(Uri.parse('$uri&$extra'));
  }

  /// Saves the queue on the server, so another device can carry on from it.
  Future<void> savePlayQueue(List<String> songIds, {required String current, required Duration position}) async {
    final uri = buildUrl('savePlayQueue', {'current': current, 'position': position.inMilliseconds});
    final ids = songIds.map((id) => 'id=${Uri.encodeQueryComponent(id)}').join('&');
    await _rawGet(Uri.parse('$uri&$ids'));
  }

  /// The queue a device last saved, or null when there isn't one.
  Future<PlayQueue?> getPlayQueue() async {
    final body = await request('getPlayQueue');
    final queue = body['playQueue'];
    return queue is Map ? PlayQueue.fromJson(queue.cast()) : null;
  }

  Future<void> _rawGet(Uri uri) async {
    try {
      final res = await _dio.getUri<Object>(uri);
      _unwrap(res.data);
      onReachability?.call(true);
    } on DioException catch (e) {
      if (_isNetworkError(e)) {
        onReachability?.call(false);
        throw const SubsonicException(SubsonicErrorKind.unreachable, 'Server unreachable. Check your network, or your VPN if you use one (e.g. Tailscale).');
      }
      throw const SubsonicException(SubsonicErrorKind.server, 'Request failed.');
    }
  }

  Future<SearchResult> getStarred2() async {
    final body = await request('getStarred2', cached: true);
    return SearchResult.fromJson((body['starred2'] as Map?)?.cast() ?? const {});
  }

  Future<void> star({String? id, String? albumId, String? artistId}) =>
      request('star', params: {'id': id, 'albumId': albumId, 'artistId': artistId});

  Future<void> unstar({String? id, String? albumId, String? artistId}) =>
      request('unstar', params: {'id': id, 'albumId': albumId, 'artistId': artistId});

  Future<void> scrobble(String id, {required bool submission}) =>
      request('scrobble', params: {'id': id, 'submission': submission});

  Future<Lyrics?> getLyrics(String songId) async {
    try {
      final body = await request('getLyricsBySongId', params: {'id': songId}, cached: true);
      final list = body['lyricsList'];
      return list is Map ? Lyrics.fromLyricsList(list.cast()) : null;
    } on SubsonicException catch (e) {
      // Older servers without the OpenSubsonic extension.
      if (e.kind == SubsonicErrorKind.server) return null;
      rethrow;
    }
  }

  Uri coverArtUrl(String id, {int size = 600}) => buildUrl('getCoverArt', {'id': id, 'size': size});

  /// [maxBitRate] of 0 means original quality. [timeOffset] (whole seconds)
  /// starts a transcoded stream part-way in; the original file ignores it.
  Uri streamUrl(String id, {int maxBitRate = 0, int timeOffset = 0}) => buildUrl('stream', {
    'id': id,
    if (maxBitRate > 0) 'maxBitRate': maxBitRate,
    if (maxBitRate > 0) 'format': 'mp3',
    if (timeOffset > 0) 'timeOffset': timeOffset,
  });

  Uri downloadUrl(String id) => buildUrl('download', {'id': id});
}
