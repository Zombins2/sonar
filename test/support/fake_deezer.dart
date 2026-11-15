import 'dart:convert';
import 'dart:io';

/// Reads a reply recorded from Deezer in `test/fixtures/deezer` (trimmed to
/// the fields Sonar reads, and a few more).
Map<String, Object?> deezerFixture(String name) =>
    jsonDecode(File('test/fixtures/deezer/$name.json').readAsStringSync()) as Map<String, Object?>;

/// Deezer on loopback, answering with the recordings.
///
/// A request answers with the recording made for the same path and
/// parameters (ignoring case), or, as Deezer does, with nothing found for a
/// search and a "no data" error for anything else.
class FakeDeezer {
  FakeDeezer._(this._server);

  final HttpServer _server;

  /// Every request: its path and parameters.
  final requests = <({String path, Map<String, String> asked})>[];

  /// Replies to give before any other, by path. Each is used once.
  final queued = <String, List<Object?>>{};

  /// Every request fails, as when Deezer can't be reached.
  bool down = false;

  static final _recordings = [
    for (final f in Directory('test/fixtures/deezer').listSync().whereType<File>())
      if (f.path.endsWith('.json')) f.uri.pathSegments.last.replaceAll('.json', ''),
  ];

  String get base => 'http://127.0.0.1:${_server.port}';

  static Future<FakeDeezer> start() async {
    final fake = FakeDeezer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    fake._server.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final asked = req.uri.queryParameters;
    requests.add((path: path, asked: asked));
    final res = req.response;
    if (down) return _reply(res, 500, 'down');
    final queue = queued[path];
    if (queue != null && queue.isNotEmpty) return _reply(res, 200, queue.removeAt(0));
    for (final name in _recordings) {
      final f = deezerFixture(name);
      final r = f['request']! as Map;
      if (r['path'] == path && _sameParams(r['query']! as Map, asked)) return _reply(res, 200, f['response']);
    }
    if (path.startsWith('/search')) return _reply(res, 200, {'data': <Object?>[], 'total': 0});
    return _reply(res, 200, {
      'error': {'type': 'DataException', 'message': 'no data', 'code': 800},
    });
  }

  static bool _sameParams(Map<Object?, Object?> recorded, Map<String, String> asked) {
    final want = {for (final e in recorded.entries) '${e.key}': '${e.value}'.toLowerCase()};
    return want.length == asked.length && want.entries.every((e) => asked[e.key]?.toLowerCase() == e.value);
  }

  Future<void> _reply(HttpResponse res, int status, Object? body) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }
}
