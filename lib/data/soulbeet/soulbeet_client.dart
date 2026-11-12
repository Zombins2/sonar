import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../subsonic/subsonic_client.dart';
import 'soulbeet_models.dart';

/// Talks to the Soulbeet server beside Navidrome (docs/SOULBEET_PLAN.md).
///
/// Logs in with the same Navidrome account as the rest of the app. The
/// password goes once in a POST body (HTTPS, or this same computer), never in
/// a URL; after that only the `auth_token` cookie is sent. Nothing here logs
/// the password, the cookie or request bodies.

enum SoulbeetErrorKind { unreachable, badLogin, refused, format }

class SoulbeetException implements Exception {
  const SoulbeetException(this.kind, this.message);
  final SoulbeetErrorKind kind;
  final String message;
  @override
  String toString() => message;
}

/// Soulbeet's address for a Navidrome server: the same Tailscale name on
/// port 8443, or its own port for a login to this same computer.
Uri soulbeetBaseFor(String serverUrl) {
  final uri = Uri.parse(serverUrl.trim());
  if (uri.scheme == 'http' && SubsonicClient.isLoopback(uri.host)) return Uri.parse('http://127.0.0.1:9765');
  return Uri(scheme: 'https', host: uri.host, port: 8443);
}

class SoulbeetClient {
  SoulbeetClient({
    required this.base,
    required this.username,
    required String password,
    String? token,
    this.savedToken,
    this.onToken,
    HttpClient? http,
    this.timeout = const Duration(seconds: 20),
  }) : _password = password,
       _token = token,
       _http = http ?? HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 8);
  }

  static const cookieName = 'auth_token';

  final Uri base;
  final String username;
  final String _password;
  final Duration timeout;
  final HttpClient _http;

  /// Called with each new login cookie (or null when it stops working), so
  /// the app can keep it and skip logging in next time.
  final void Function(String? token)? onToken;

  /// The cookie kept from last time, read before the first call.
  final Future<String?> Function()? savedToken;
  bool _readSaved = false;
  String? _token;
  Future<void>? _loggingIn;

  bool get loggedIn => _token != null;

  void close() => _http.close(force: true);

  Uri _url(String path) => base.replace(path: path);

  // ---- Login --------------------------------------------------------------------

  Future<void> login() => _loggingIn ??= _login().whenComplete(() => _loggingIn = null);

  Future<void> _login() async {
    final (status, body, response) = await _send('POST', '/api/auth/login', {
      'username': username,
      'password': _password,
    });
    if (status == 401 || status == 403) {
      throw const SoulbeetException(SoulbeetErrorKind.badLogin, 'Soulbeet didn\'t accept your Navidrome login.');
    }
    if (status != 200) throw _refused(status, body);
    final cookie = response.cookies.where((c) => c.name == cookieName && c.value.isNotEmpty).firstOrNull;
    if (cookie == null) {
      throw const SoulbeetException(SoulbeetErrorKind.format, 'Soulbeet logged in but sent no session.');
    }
    _token = cookie.value;
    onToken?.call(_token);
  }

  // ---- Calls ---------------------------------------------------------------------

  Future<SbHealth> health() async => SbHealth.fromJson(await _map('GET', '/api/system/health'));

  Future<List<SbFolder>> folders() async => [
    for (final f in (await _list('GET', '/api/folders')).whereType<SbJson>()) SbFolder.fromJson(f),
  ];

  /// Makes a library folder for this login. Soulbeet's folders belong to
  /// each user, so every new login starts with none.
  Future<SbFolder> createFolder({String name = 'Music', String path = '/music'}) async =>
      SbFolder.fromJson(await _map('POST', '/api/folders', {'name': name, 'path': path}));

  Future<List<SbAlbum>> searchAlbums(String query, {String? artist}) async {
    final r = await _map('POST', '/api/metadata/search/album', {
      'input': {'query': query, 'artist': _blankToNull(artist), 'provider': 'musicbrainz'},
    });
    return [
      for (final a in _results(r))
        if (a['kind'] == null || a['kind'] == 'Album') SbAlbum.fromJson(a),
    ];
  }

  Future<List<SbTrack>> searchTracks(String query, {String? artist}) async {
    final r = await _map('POST', '/api/metadata/search/track', {
      'input': {'query': query, 'artist': _blankToNull(artist), 'provider': 'musicbrainz'},
    });
    return [for (final t in _results(r)) SbTrack.fromJson(t)];
  }

  Future<SbAlbumDetail> album(String id) async => SbAlbumDetail.fromJson(
    await _map('POST', '/api/metadata/album', {
      'input': {'id': id, 'provider': 'musicbrainz'},
    }),
  );

  /// Soulbeet searches Soulseek, picks a copy and downloads it into
  /// [folder]. Returns the batch id its progress events carry.
  Future<String> autoDownload(SbAlbum album, SbFolder folder) async {
    final r = await _map('POST', '/api/auto-download', {
      'req': {
        'query': {'album': album.request, 'tracks': const <Object>[], 'backend': null},
        'folder_id': folder.id,
        'folder_path': folder.path,
      },
    });
    final accepted = r['Accepted'];
    if (accepted is SbJson && accepted['batch_id'] is String) return accepted['batch_id']! as String;
    throw SoulbeetException(SoulbeetErrorKind.refused, '${r['Error'] ?? 'Soulbeet couldn\'t start the download.'}');
  }

  /// Starts looking for copies of [album] on Soulseek; poll with [pollSources].
  Future<String> startSourceSearch(SbAlbum album) async {
    final r = await _call('POST', '/api/download/search/start', {
      'data': {'album': album.request, 'tracks': const <Object>[], 'backend': null},
    });
    if (r is String && r.isNotEmpty) return r;
    throw SoulbeetFormatException('search id is ${r.runtimeType}');
  }

  Future<SbSourceSearch> pollSources(String searchId) async => SbSourceSearch.fromJson(
    await _map('POST', '/api/download/search/poll', {
      'input': {'search_id': searchId, 'backend': null},
    }),
  );

  /// Downloads [files] (one person's copy) into [folder]. Returns the ids of
  /// the files it took on; their progress events carry the same ids.
  Future<List<String>> queue(List<SbSourceFile> files, SbFolder folder) async {
    final r = await _list('POST', '/api/downloads/queue', {
      'req': {
        'items': [for (final f in files) f.raw],
        'target_folder': folder.path,
        'backend': null,
      },
    });
    final ids = <String>[];
    String? failure;
    for (final q in r.whereType<SbJson>()) {
      final status = q['status'];
      if (status == 'Enqueued' || status == 'AlreadyInFlight') {
        if (q['id'] is String) ids.add(q['id']! as String);
      } else if (status is SbJson && status['Failed'] != null) {
        failure ??= '${status['Failed']}';
      }
    }
    if (ids.isEmpty) throw SoulbeetException(SoulbeetErrorKind.refused, failure ?? 'Nothing was queued.');
    return ids;
  }

  Future<void> cancel(SbProgress file) => _call('POST', '/api/downloads/cancel', {
    'req': {'id': file.id, 'source': file.source, 'item': file.item, 'backend': file.backend},
  });

  /// The matches beets found for a skipped import.
  Future<List<SbMatch>> importChoices(SbProgress file) async {
    final r = await _map('POST', '/api/downloads/import-choices', {'item': file.item});
    return [for (final c in (r['candidates'] as List<Object?>? ?? const []).whereType<SbJson>()) SbMatch.fromJson(c)];
  }

  /// Imports a skipped (or failed) album again; progress follows on [updates].
  Future<void> retryImport(SbProgress file, SbImportChoice choice) =>
      _call('POST', '/api/downloads/retry-import', {'item': file.item, 'choice': choice.toJson()});

  /// Live download events, until the connection drops (the caller reconnects).
  Future<Stream<SbEvent>> updates() async {
    await _ensureLogin();
    Future<WebSocket> open() => WebSocket.connect(
      _url('/api/downloads/updates').replace(scheme: base.scheme == 'https' ? 'wss' : 'ws').toString(),
      headers: {HttpHeaders.cookieHeader: '$cookieName=$_token'},
      customClient: _http,
    ).timeout(timeout);
    WebSocket socket;
    try {
      socket = await open();
    } on WebSocketException catch (e) {
      // A refused upgrade is most likely an expired login.
      if (!'$e'.contains('401')) {
        throw const SoulbeetException(SoulbeetErrorKind.unreachable, 'Download updates unavailable.');
      }
      _forget();
      await login();
      socket = await open();
    } on SocketException {
      throw const SoulbeetException(SoulbeetErrorKind.unreachable, 'Can\'t reach Soulbeet.');
    } on TimeoutException {
      throw const SoulbeetException(SoulbeetErrorKind.unreachable, 'Can\'t reach Soulbeet.');
    }
    socket.pingInterval = const Duration(seconds: 20);
    return socket.map((frame) {
      final text = frame is String ? frame : utf8.decode(frame as List<int>, allowMalformed: true);
      try {
        return SbEvent.fromJson(jsonDecode(text));
      } catch (_) {
        return SbUnknownEvent(text);
      }
    });
  }

  // ---- Plumbing --------------------------------------------------------------------

  static String? _blankToNull(String? s) => s == null || s.trim().isEmpty ? null : s.trim();

  static List<SbJson> _results(SbJson r) => (r['results'] as List<Object?>? ?? const []).whereType<SbJson>().toList();

  void _forget() {
    if (_token == null) return;
    _token = null;
    onToken?.call(null);
  }

  Future<SbJson> _map(String method, String path, [Object? body]) async {
    final r = await _call(method, path, body);
    if (r is SbJson) return r;
    throw SoulbeetFormatException('$path sent ${r.runtimeType}');
  }

  Future<List<Object?>> _list(String method, String path, [Object? body]) async {
    final r = await _call(method, path, body);
    if (r is List<Object?>) return r;
    throw SoulbeetFormatException('$path sent ${r.runtimeType}');
  }

  Future<void> _ensureLogin() async {
    if (_token == null && !_readSaved && savedToken != null) {
      _readSaved = true;
      try {
        _token = await savedToken!();
      } catch (_) {}
    }
    if (_token == null) await login();
  }

  /// An authenticated call; logs in first, and once more if the cookie expired.
  Future<Object?> _call(String method, String path, [Object? body]) async {
    await _ensureLogin();
    var (status, reply, _) = await _send(method, path, body, auth: true);
    if (status == 401) {
      _forget();
      await login();
      (status, reply, _) = await _send(method, path, body, auth: true);
    }
    if (status == 401) throw const SoulbeetException(SoulbeetErrorKind.badLogin, 'Soulbeet logged you out.');
    if (status != 200) throw _refused(status, reply);
    return reply;
  }

  static SoulbeetException _refused(int status, Object? reply) {
    var message = reply is String && reply.trim().isNotEmpty ? reply.trim() : 'Soulbeet said no ($status).';
    if (message.length > 200) message = '${message.substring(0, 200)}…';
    return SoulbeetException(SoulbeetErrorKind.refused, message);
  }

  Future<(int, Object?, HttpClientResponse)> _send(
    String method,
    String path,
    Object? body, {
    bool auth = false,
  }) async {
    try {
      final request = await _http.openUrl(method, _url(path)).timeout(timeout);
      if (auth && _token != null) request.cookies.add(Cookie(cookieName, _token!));
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(timeout);
      final text = await response.transform(utf8.decoder).join().timeout(timeout);
      Object? reply = text;
      if ((response.headers.contentType?.mimeType ?? '') == 'application/json' ||
          text.startsWith('{') ||
          text.startsWith('[') ||
          text.startsWith('"')) {
        try {
          reply = text.isEmpty ? null : jsonDecode(text);
        } catch (_) {}
      }
      return (response.statusCode, reply, response);
    } on SocketException {
      throw const SoulbeetException(SoulbeetErrorKind.unreachable, 'Can\'t reach Soulbeet.');
    } on HandshakeException {
      throw const SoulbeetException(SoulbeetErrorKind.unreachable, 'Can\'t reach Soulbeet securely.');
    } on TimeoutException {
      throw const SoulbeetException(SoulbeetErrorKind.unreachable, 'Soulbeet took too long to answer.');
    } on HttpException {
      throw const SoulbeetException(SoulbeetErrorKind.unreachable, 'Can\'t reach Soulbeet.');
    }
  }
}
