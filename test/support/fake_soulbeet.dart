import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Reads a recorded reply from `test/fixtures/soulbeet` (see docs/SOULBEET_PLAN.md).
Map<String, Object?> soulbeetFixture(String name) =>
    jsonDecode(File('test/fixtures/soulbeet/$name.json').readAsStringSync()) as Map<String, Object?>;

/// A Soulbeet server on loopback that answers with the recorded replies.
///
/// It checks what a real one checks (the login, the `auth_token` cookie) and
/// keeps every request body so tests can compare them with the recordings.
class FakeSoulbeet {
  FakeSoulbeet._(this._server);

  static const username = 'me';
  static const password = 'test-password';

  final HttpServer _server;
  final requests = <(String path, Object? body)>[];
  int logins = 0;

  /// The token the next login hands out; changing it expires older ones.
  String token = 'token-1';

  /// Replies to override, by path: (status, body).
  final overrides = <String, (int, Object?)>{};

  /// What the WebSocket sends, one binary frame each (as the real server does).
  List<Object?> frames = const [];
  final sockets = <WebSocket>[];

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}');

  static Future<FakeSoulbeet> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeSoulbeet._(server);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> close() async {
    for (final s in sockets) {
      await s.close();
    }
    await _server.close(force: true);
  }

  /// Sends [event] to every open WebSocket, as one binary frame.
  void push(Object? event) {
    for (final s in sockets.toList()) {
      if (s.closeCode == null) s.add(utf8.encode(jsonEncode(event)));
    }
  }

  /// Drops every open WebSocket (a network blip).
  Future<void> dropSockets() async {
    for (final s in sockets.toList()) {
      await s.close();
    }
    sockets.clear();
  }

  /// Called after each request (path, body), before the reply.
  void Function(String path, Object? body)? onRequest;

  /// The JSON bodies sent to [path], in order.
  List<Object?> bodiesFor(String path) => [
    for (final r in requests)
      if (r.$1 == path) r.$2,
  ];

  static const _fixtureFor = {
    '/api/auth/me': 'auth_me',
    '/api/system/health': 'system_health',
    '/api/folders': 'folders',
    '/api/metadata/search/album': 'search_album',
    '/api/metadata/search/track': 'search_track',
    '/api/metadata/album': 'album',
    '/api/download/search/start': 'download_search_start',
    '/api/download/search/poll': 'download_search_poll_done',
    '/api/downloads/import-choices': 'import_choices',
    '/api/downloads/retry-import': 'retry_import',
  };

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final text = await utf8.decoder.bind(req).join();
    Object? body;
    if (text.isNotEmpty) body = jsonDecode(text);
    requests.add((path, body));
    onRequest?.call(path, body);
    final res = req.response;

    if (path == '/api/auth/login') {
      final ok = body is Map && body['username'] == username && body['password'] == password;
      if (!ok) return _reply(res, 401, 'Invalid credentials');
      logins++;
      res.cookies.add(
        Cookie('auth_token', token)
          ..httpOnly = true
          ..path = '/',
      );
      return _reply(res, 200, {'username': username, 'user_id': 'u1', 'navidrome_status': 'Connected'});
    }
    final cookie = req.cookies.where((c) => c.name == 'auth_token').firstOrNull;
    if (cookie?.value != token) return _reply(res, 401, 'No auth token found');

    if (path == '/api/downloads/updates' && WebSocketTransformer.isUpgradeRequest(req)) {
      final socket = await WebSocketTransformer.upgrade(req);
      sockets.add(socket);
      socket.listen((_) {}, onDone: () => sockets.remove(socket), cancelOnError: true);
      for (final f in frames) {
        socket.add(utf8.encode(jsonEncode(f)));
      }
      return;
    }
    if (overrides[path] case (final status, final reply)) return _reply(res, status, reply);
    switch (path) {
      case '/api/auto-download':
        return _reply(res, 200, {
          'Accepted': {'batch_id': 'batch-1'},
        });
      case '/api/downloads/queue':
        final items = ((body as Map)['req'] as Map)['items'] as List;
        return _reply(res, 200, [
          for (final (i, it) in items.indexed)
            {
              'id': 'transfer-$i',
              'source': (it as Map)['source'],
              'item': it['id'],
              'size': it['size'],
              'status': 'Enqueued',
            },
        ]);
      case '/api/downloads/cancel':
        return _reply(res, 200, null);
    }
    final name = _fixtureFor[path];
    if (name == null) return _reply(res, 404, 'not found');
    final f = soulbeetFixture(name);
    return _reply(res, f['status']! as int, f['response']);
  }

  Future<void> _reply(HttpResponse res, int status, Object? body) async {
    res.statusCode = status;
    if (body is String && status != 200) {
      res.headers.contentType = ContentType.text;
      res.write(body);
    } else {
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(body));
    }
    await res.close();
  }
}
