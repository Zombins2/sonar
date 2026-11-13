import 'dart:convert';
import 'dart:io';

/// Reads a reply recorded from MusicBrainz or ListenBrainz in
/// `test/fixtures/musicbrainz` (trimmed of tags, credited artists' aliases
/// and each album's releases after its first official one).
Map<String, Object?> musicBrainzFixture(String name) =>
    jsonDecode(File('test/fixtures/musicbrainz/$name.json').readAsStringSync()) as Map<String, Object?>;

/// MusicBrainz and ListenBrainz on loopback, answering with the recordings.
///
/// A search answers with the recording made for the same query (ignoring
/// case, as MusicBrainz does), or with nothing found. Listener counts answer
/// for exactly the ids asked about, as ListenBrainz does.
class FakeMusicBrainz {
  FakeMusicBrainz._(this._server);

  final HttpServer _server;

  /// Every request: when, path, what it asked (MusicBrainz: its parameters;
  /// ListenBrainz: the ids), and the User-Agent it came with.
  final requests = <({DateTime at, String path, Object? asked, String? agent})>[];

  /// Replies to give before any other, by path: (status, body). Each is used once.
  final queued = <String, List<(int, Object?)>>{};

  /// Every ListenBrainz request fails.
  bool listenBrainzDown = false;

  /// How long to take answering each request to a path, as a busy server would.
  final slow = <String, Duration>{};

  static const _recordings = [
    'artist_kanye_west',
    'artist_jpeg_mafia',
    'albums_by_jpegmafia',
    'albums_by_ye',
    'albums_by_ye_100',
    'pressings_of_yeezus',
    'songs_of_yeezus',
    'album_search_kanye_west',
    'album_search_gemini_rights',
    'song_search_pure_colour',
    'song_search_sky_is_the_limit',
    'loose_songs_sky_is_the_limit_rebelution',
    'loose_albums_rebelution_peace_of_mind',
    'pressings_of_late_registration',
    'songs_of_late_registration',
    'pressings_of_mbdtf',
    'songs_of_mbdtf',
    'pressings_of_graduation',
    'songs_of_graduation',
  ];

  String get base => 'http://127.0.0.1:${_server.port}';

  static Future<FakeMusicBrainz> start() async {
    final fake = FakeMusicBrainz._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    fake._server.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  /// The MusicBrainz searches and browses made (not lookups of one thing):
  /// (path after /ws/2/, the search query, or the other parameters).
  List<(String, String)> get searches => [
    for (final (path, asked) in _mb)
      if (!path.contains('/')) (path, asked),
  ];

  /// The MusicBrainz lookups of one thing made: (path after /ws/2/, parameters).
  List<(String, String)> get lookups => [
    for (final (path, asked) in _mb)
      if (path.contains('/')) (path, asked),
  ];

  List<(String, String)> get _mb => [
    for (final r in requests)
      if (r.path.startsWith('/ws/2/'))
        (r.path.substring(6), (r.asked! as Map<String, String>)['query'] ?? _describe(r.asked! as Map<String, String>)),
  ];

  static String _describe(Map<String, String> params) => [
    for (final e in params.entries)
      if (e.key != 'fmt') '${e.key}=${e.value}',
  ].join('&');

  static bool _sameParams(Map<Object?, Object?> recorded, Map<String, String> asked) {
    String norm(Object? v) => '$v'.toLowerCase();
    final want = {
      for (final e in recorded.entries)
        if (e.key != 'fmt') '${e.key}': norm(e.value),
    };
    final got = {
      for (final e in asked.entries)
        if (e.key != 'fmt') e.key: norm(e.value),
    };
    return want.length == got.length && want.entries.every((e) => got[e.key] == e.value);
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final text = await utf8.decoder.bind(req).join();
    final body = text.isEmpty ? null : jsonDecode(text);
    final asked = path.startsWith('/ws/2/') ? req.uri.queryParameters : body;
    requests.add((at: DateTime.now(), path: path, asked: asked, agent: req.headers.value('user-agent')));
    final res = req.response;
    final wait = slow[path];
    if (wait != null) await Future<void>.delayed(wait);

    final queue = queued[path];
    if (queue != null && queue.isNotEmpty) {
      final (status, reply) = queue.removeAt(0);
      return _reply(res, status, reply);
    }
    if (path.startsWith('/1/popularity/')) {
      if (listenBrainzDown) return _reply(res, 503, {'error': 'down'});
      final kind = path.split('/').last;
      final (key, idKey, file) = kind == 'recording'
          ? ('recording_mbids', 'recording_mbid', 'popularity_recordings')
          : ('release_group_mbids', 'release_group_mbid', 'popularity_release_groups');
      final known = {
        for (final p in (musicBrainzFixture(file)['response']! as List).cast<Map<String, Object?>>()) p[idKey]: p,
      };
      final ids = ((body! as Map)[key]! as List).cast<String>();
      return _reply(res, 200, [
        for (final id in ids) known[id] ?? {idKey: id, 'total_listen_count': null, 'total_user_count': null},
      ]);
    }
    if (path.startsWith('/ws/2/')) {
      final entity = path.substring(6);
      for (final name in _recordings) {
        final f = musicBrainzFixture(name);
        final r = f['request']! as Map;
        if (r['path'] == path && _sameParams(r['query']! as Map, req.uri.queryParameters)) {
          return _reply(res, 200, f['response']);
        }
      }
      if (entity.contains('/')) return _reply(res, 404, {'error': 'Not Found'});
      final listKey = switch (entity) {
        'artist' => 'artists',
        'recording' => 'recordings',
        _ => 'release-groups',
      };
      return _reply(res, 200, {'count': 0, 'offset': 0, listKey: <Object?>[]});
    }
    return _reply(res, 404, 'not found');
  }

  Future<void> _reply(HttpResponse res, int status, Object? body) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }
}
