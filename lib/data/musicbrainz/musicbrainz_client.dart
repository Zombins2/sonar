import 'dart:async';

import 'package:dio/dio.dart';

import '../soulbeet/soulbeet_models.dart';

/// MusicBrainz didn't answer, or kept saying it was busy.
class MusicBrainzException implements Exception {
  const MusicBrainzException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What a request waiting its turn checks before it's sent: a search the
/// user has moved on from (typed more, left the screen) drops out of line.
class MbCancel {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// A request dropped because its [MbCancel] was cancelled.
class MbCancelled implements Exception {
  const MbCancelled();
}

/// How soon a request goes, among those waiting.
enum MbTurn {
  /// What the screen is waiting for.
  now,

  /// The rest of a search, after what's waiting for [now].
  soon,

  /// Fetching ahead (an album's songs before it's opened): only when
  /// nothing else is waiting.
  spare,
}

/// An artist on MusicBrainz whose name (or one of whose other names) is the
/// one searched for. [matchedAs] is that other name ("Kanye West" for Ye).
class MbArtist {
  const MbArtist(this.id, this.name, {this.matchedAs});
  final String id;
  final String name;
  final String? matchedAs;
}

/// Finds music on MusicBrainz, and how many people listen to it on
/// ListenBrainz, for Get music. Sends only the words searched for.
///
/// Get music used to search through Soulbeet, which asks for 25 results in no
/// useful order and drops the singles among them, so an artist's search could
/// show three of their albums, and a famous album sat below tribute records
/// with its name in their titles. Searching MusicBrainz here lets Sonar ask
/// for an artist's whole discography and rank everything by listeners.
///
/// MusicBrainz takes one request a second, so requests wait in line, the
/// ones the screen is waiting for first ([MbTurn]), and those of a search the
/// user has moved on from drop out ([MbCancel]). Replies are kept a while, so
/// searching again, or opening an album fetched ahead, needs no wait.
///
/// The albums found are the same releases Soulbeet's search picks (the first
/// official one of each album), so downloads work exactly as before.
class MusicBrainzClient {
  MusicBrainzClient({
    Dio? dio,
    this.musicBrainz = 'https://musicbrainz.org',
    this.listenBrainz = 'https://api.listenbrainz.org',
    this.spacing = const Duration(milliseconds: 1100),
    this.busyWait = const Duration(seconds: 2),
    this.keep = 200,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 8),
               receiveTimeout: const Duration(seconds: 20),
               headers: {'User-Agent': userAgent, 'Accept': 'application/json'},
             ),
           );

  /// MusicBrainz asks every program to say what it is and where it lives.
  static const userAgent = 'Sonar/1.0 ( github.com/Zombins2/sonar )';

  final String musicBrainz;
  final String listenBrainz;

  /// MusicBrainz allows one request a second from each address.
  final Duration spacing;

  /// How long to wait before asking again after "busy" (503), times the try.
  final Duration busyWait;

  /// How many MusicBrainz replies to keep.
  final int keep;

  final Dio _dio;
  final _waiting = <_Request>[];

  /// Kept replies, oldest first (a map keeps the order things went in).
  final _kept = <String, Map<String, Object?>>{};
  final _listeners = <String, int?>{};
  bool _sending = false;
  DateTime? _last;

  /// MusicBrainz requests actually sent (not answered from what was kept).
  int sent = 0;

  void close() => _dio.close(force: true);

  static const _albumish = '(primarytype:album OR primarytype:ep)';

  /// Albums and EPs called [title] (by [artist]).
  Future<List<SbAlbum>> searchAlbums(
    String title, {
    String? artist,
    MbTurn turn = MbTurn.now,
    MbCancel? cancel,
  }) async => _albums(
    await _search(
      'release-group',
      ['releasegroup:${_phrase(title)}', _albumish, if (artist != null) 'artist:${_phrase(artist)}'].join(' AND '),
      25,
      turn,
      cancel,
    ),
  );

  /// Albums and EPs whose artist and title were both typed in [words], in
  /// either order ("rebelution peace of mind").
  Future<List<SbAlbum>> searchAlbumsLoosely(String words, {MbTurn turn = MbTurn.now, MbCancel? cancel}) async {
    final reply = await _get('release-group', {'query': words, 'dismax': 'true', 'limit': '25'}, turn, cancel);
    return [
      for (final g in _list(reply['release-groups']))
        if (_bothTyped(g, words) && (g['primary-type'] == 'Album' || g['primary-type'] == 'EP')) ?_album(g),
    ];
  }

  /// Songs whose artist and title were both typed in [words], in either
  /// order ("sky is the limit rebelution").
  Future<List<SbTrack>> searchSongsLoosely(String words, {MbTurn turn = MbTurn.now, MbCancel? cancel}) async {
    final reply = await _get('recording', {'query': words, 'dismax': 'true', 'limit': '25'}, turn, cancel);
    return [
      for (final r in _list(reply['recordings']))
        if (_bothTyped(r, words)) ?_song(r),
    ];
  }

  /// Whether one of [found]'s artists was typed in [words], and what else was
  /// typed is in its title ("Sky Is the Limit (Acoustic)" for "sky is the
  /// limit rebelution"). A free-text search matches any word, so another
  /// artist's song of the same name scores well too: those are noise.
  static bool _bothTyped(Map<String, Object?> found, String words) {
    final typed = _plain(words);
    final title = _plain('${found['title'] ?? ''}');
    for (final c in _list(found['artist-credit'])) {
      for (final name in [c['name'], (c['artist'] as Map?)?['name']].whereType<String>()) {
        final artist = _plain(name);
        final at = artist.isEmpty ? -1 : typed.indexOf(artist);
        if (at >= 0 && title.contains(typed.replaceRange(at, at + artist.length, ''))) return true;
      }
    }
    return false;
  }

  /// Most albums an artist's list goes to: three pages.
  static const maxAlbumsBy = 300;

  /// Every album and EP by [artist], without their pressings (see
  /// [pressingOf]). Browsed, not searched: MusicBrainz's search index leaves
  /// some out (Ye's "Yeezus" and "808s & Heartbreak").
  Future<List<SbAlbum>> albumsBy(MbArtist artist, {MbTurn turn = MbTurn.now, MbCancel? cancel}) async {
    final albums = <SbAlbum>[];
    for (var offset = 0; offset < maxAlbumsBy; offset += 100) {
      final reply = await _get(
        'release-group',
        {'artist': artist.id, 'type': 'album|ep', 'inc': 'artist-credits', 'limit': '100', 'offset': '$offset'},
        turn,
        cancel,
      );
      final page = _list(reply['release-groups']).toList();
      for (final g in page) {
        final id = g['id'], title = g['title'];
        if (id is! String || title is! String) continue;
        albums.add(
          SbAlbum.found(
            groupId: id,
            title: title,
            artist: _credit(g['artist-credit']),
            releaseDate: g['first-release-date'] as String?,
            kinds: _kinds(g),
          ),
        );
      }
      final count = reply['release-group-count'];
      if (page.length < 100 || count is! num || offset + 100 >= count) break;
    }
    return albums;
  }

  /// [album] as the pressing Soulbeet would pick (its first official one),
  /// for an album found without one.
  Future<SbAlbum> pressingOf(SbAlbum album, {MbTurn turn = MbTurn.now, MbCancel? cancel}) async {
    final group = album.groupId;
    if (!album.needsPressing || group == null) return album;
    final reply = await _get('release-group/$group', {'inc': 'releases'}, turn, cancel);
    final releases = _list(reply['releases']);
    final release = releases.where((r) => r['status'] == 'Official').firstOrNull ?? releases.firstOrNull;
    final id = release?['id'];
    if (id is! String) throw const MusicBrainzException('MusicBrainz has no pressing of this album to download.');
    return SbAlbum.found(
      pressing: id,
      groupId: group,
      title: album.title,
      artist: album.artist,
      releaseDate: album.releaseDate,
      kinds: album.kinds,
    );
  }

  /// [album]'s pressing with its songs, shaped as Soulbeet's album lookup
  /// sends it (so its songs can be sent back to download some of them).
  Future<SbAlbumDetail> songsOf(SbAlbum album, {MbTurn turn = MbTurn.now, MbCancel? cancel}) async {
    final pressed = await pressingOf(album, turn: turn, cancel: cancel);
    final reply = await _get('release/${pressed.id}', {'inc': 'recordings+artist-credits'}, turn, cancel);
    final title = reply['title'] is String ? reply['title']! as String : pressed.title;
    final date = reply['date'] as String?;
    final tracks = <SbTrack>[];
    for (final medium in _list(reply['media'])) {
      for (final t in _list(medium['tracks'])) {
        final rec = t['recording'];
        if (rec is! Map) continue;
        final r = rec.cast<String, Object?>();
        final id = r['id'], name = r['title'];
        if (id is! String || name is! String) continue;
        tracks.add(
          SbTrack.fromJson({
            'id': id,
            'title': name,
            'artist': _credit(r['artist-credit']),
            'album_id': pressed.id,
            'album_title': title,
            'release_date': date,
            'duration': _clock(r['length']),
            'mbid': id,
            'release_mbid': pressed.id,
          }),
        );
      }
    }
    final credit = _credit(reply['artist-credit']);
    return SbAlbumDetail(
      SbAlbum.found(
        pressing: pressed.id,
        groupId: pressed.groupId ?? pressed.id,
        title: title,
        artist: credit.isEmpty ? pressed.artist : credit,
        releaseDate: date ?? pressed.releaseDate,
        kinds: pressed.kinds,
      ),
      tracks,
    );
  }

  /// Songs called [title] (by [artist]), each on the album it's best found on.
  Future<List<SbTrack>> searchSongs(String title, {String? artist, MbTurn turn = MbTurn.now, MbCancel? cancel}) async {
    final reply = await _search(
      'recording',
      ['recording:${_phrase(title)}', if (artist != null) 'artist:${_phrase(artist)}'].join(' AND '),
      25,
      turn,
      cancel,
    );
    return [for (final r in _list(reply['recordings'])) ?_song(r)];
  }

  /// Artists whose name, or another name they go by, is [name], ignoring
  /// case, spaces and punctuation ("jpeg mafia" is JPEGMAFIA). At most two.
  Future<List<MbArtist>> findArtists(String name, {MbTurn turn = MbTurn.now, MbCancel? cancel}) async {
    final want = _plain(name);
    if (want.isEmpty) return const [];
    final reply = await _search('artist', _escape(name), 5, turn, cancel);
    final found = <MbArtist>[];
    for (final a in _list(reply['artists'])) {
      final id = a['id'], artistName = a['name'];
      if (id is! String || artistName is! String) continue;
      if (_plain(artistName) == want) {
        found.add(MbArtist(id, artistName));
      } else {
        final alias = _list(a['aliases']).map((x) => x['name']).whereType<String>().where((n) => _plain(n) == want);
        if (alias.isNotEmpty) found.add(MbArtist(id, artistName, matchedAs: alias.first));
      }
      if (found.length == 2) break;
    }
    return found;
  }

  /// How many people have listened to each album (by [SbAlbum.groupId]) and
  /// song (by id) on ListenBrainz. Missing ones nobody has played, or
  /// ListenBrainz didn't answer: ranking is a nicety, never a failure.
  /// ListenBrainz takes many requests at once, so these don't wait in line.
  Future<Map<String, int>> listeners({Iterable<String> albums = const [], Iterable<String> songs = const []}) async {
    Future<void> ask(String kind, String key, String idKey, Iterable<String> ids) async {
      final unknown = ids.where((id) => !_listeners.containsKey(id)).toSet().toList();
      if (unknown.isEmpty) return;
      try {
        final res = await _dio.post<Object>('$listenBrainz/1/popularity/$kind', data: {key: unknown});
        for (final id in unknown) {
          _listeners[id] = null;
        }
        for (final p in _list(res.data)) {
          final id = p[idKey], users = p['total_user_count'];
          if (id is String && users is num) _listeners[id] = users.toInt();
        }
      } on DioException {
        return;
      }
    }

    await Future.wait([
      ask('release-group', 'release_group_mbids', 'release_group_mbid', albums),
      ask('recording', 'recording_mbids', 'recording_mbid', songs),
    ]);
    return {
      for (final id in [...albums, ...songs]) id: ?_listeners[id],
    };
  }

  Future<Map<String, Object?>> _search(String entity, String query, int limit, MbTurn turn, MbCancel? cancel) =>
      _get(entity, {'query': query, 'limit': '$limit'}, turn, cancel);

  /// One MusicBrainz request: what was kept if it's been asked before, else
  /// in line, a second after the last one sent.
  Future<Map<String, Object?>> _get(String path, Map<String, String> params, MbTurn turn, MbCancel? cancel) {
    final key =
        '$path?${(params.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => '${e.key}=${e.value}').join('&')}';
    final kept = _kept.remove(key);
    if (kept != null) {
      _kept[key] = kept;
      return Future.value(kept);
    }
    if (cancel?.cancelled ?? false) return Future.error(const MbCancelled());
    final r = _Request(key, path, params, turn, cancel);
    _waiting.add(r);
    unawaited(_send());
    return r.done.future;
  }

  Future<void> _send() async {
    if (_sending) return;
    _sending = true;
    try {
      while (true) {
        _dropCancelled();
        if (_waiting.isEmpty) return;
        final last = _last;
        final wait = last == null ? Duration.zero : last.add(spacing).difference(DateTime.now());
        // Even with no wait, a turn of the event loop: what is asked along
        // with this (an answer's next steps, more urgent ones among them) is
        // in line before one is chosen.
        await Future<void>.delayed(wait > Duration.zero ? wait : Duration.zero);
        // Chosen after the wait: something more urgent may have come in.
        _dropCancelled();
        if (_waiting.isEmpty) return;
        final r = _waiting.reduce((a, b) => b.turn.index < a.turn.index ? b : a);
        _waiting.remove(r);
        final kept = _kept[r.key];
        if (kept != null) {
          r.done.complete(kept);
          continue;
        }
        try {
          final reply = await _fetch(r);
          _kept[r.key] = reply;
          while (_kept.length > keep) {
            _kept.remove(_kept.keys.first);
          }
          r.done.complete(reply);
        } on Object catch (e, st) {
          r.done.completeError(e, st);
        }
      }
    } finally {
      _sending = false;
    }
  }

  void _dropCancelled() => _waiting.removeWhere((r) {
    if (!(r.cancel?.cancelled ?? false)) return false;
    r.done.completeError(const MbCancelled());
    return true;
  });

  /// Sends [r], asking again (each time after the pause) when busy.
  Future<Map<String, Object?>> _fetch(_Request r) async {
    for (var attempt = 1; ; attempt++) {
      _last = DateTime.now();
      sent++;
      try {
        final res = await _dio.get<Object>(
          '$musicBrainz/ws/2/${r.path}',
          queryParameters: {...r.params, 'fmt': 'json'},
        );
        final data = res.data;
        if (data is Map<String, Object?>) return data;
        throw const MusicBrainzException('MusicBrainz sent something unexpected. Try again.');
      } on DioException catch (e) {
        final busy = e.response?.statusCode == 503 || e.response?.statusCode == 429;
        if (busy && attempt < 4) {
          await Future<void>.delayed(busyWait * attempt);
          continue;
        }
        throw MusicBrainzException(
          busy ? 'MusicBrainz is busy right now. Try again in a minute.' : 'Couldn\'t reach MusicBrainz.',
        );
      }
    }
  }

  /// Albums from release groups, as the release Soulbeet's search would pick.
  static List<SbAlbum> _albums(Map<String, Object?> reply) => [
    for (final g in _list(reply['release-groups'])) ?_album(g),
  ];

  static SbAlbum? _album(Map<String, Object?> g) {
    final releases = _list(g['releases']);
    final release = releases.where((r) => r['status'] == 'Official').firstOrNull ?? releases.firstOrNull;
    final id = release?['id'], title = g['title'], groupId = g['id'];
    if (id is! String || title is! String || groupId is! String) return null;
    return SbAlbum.found(
      pressing: id,
      title: title,
      artist: _credit(g['artist-credit']),
      releaseDate: g['first-release-date'] as String?,
      groupId: groupId,
      kinds: _kinds(g),
    );
  }

  static List<String> _kinds(Map<String, Object?> g) =>
      (g['secondary-types'] is List ? (g['secondary-types']! as List).whereType<String>().toList() : const []);

  /// A song on its best release: official before anything else, then an
  /// album, then an EP, then the earliest.
  static SbTrack? _song(Map<String, Object?> r) {
    final id = r['id'], title = r['title'];
    if (id is! String || title is! String) return null;
    int rank(Map<String, Object?> release) {
      final type = (release['release-group'] as Map?)?['primary-type'];
      return (release['status'] == 'Official' ? 4 : 0) + (type == 'Album' ? 2 : (type == 'EP' ? 1 : 0));
    }

    final releases = _list(r['releases']).toList()
      ..sort((a, b) {
        final byRank = rank(b).compareTo(rank(a));
        if (byRank != 0) return byRank;
        return ((a['date'] as String?) ?? '9999').compareTo((b['date'] as String?) ?? '9999');
      });
    final release = releases.firstOrNull;
    return SbTrack.fromJson({
      'id': id,
      'title': title,
      'artist': _credit(r['artist-credit']),
      'album_id': release?['id'],
      'album_title': release?['title'],
      'release_date': release?['date'],
      'duration': _clock(r['length']),
      'mbid': id,
      'release_mbid': release?['id'],
    });
  }

  /// A length in milliseconds as Soulbeet writes it: "03:07".
  static String? _clock(Object? ms) {
    if (ms is! num) return null;
    final s = (ms / 1000).round();
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  /// "Steve Lacy, Erykah Badu", as MusicBrainz credits it.
  static String _credit(Object? credit) =>
      _list(credit).map((c) => '${c['name'] ?? ''}${c['joinphrase'] ?? ''}').join().trim();

  static Iterable<Map<String, Object?>> _list(Object? v) =>
      v is List ? v.whereType<Map<Object?, Object?>>().map((m) => m.cast<String, Object?>()) : const [];

  /// The name as letters and digits only, lower case.
  static String _plain(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

  /// Words searched exactly as a phrase.
  static String _phrase(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  /// Words searched as words, their search-syntax characters made plain.
  static String _escape(String s) => s.replaceAllMapped(RegExp(r'[+\-&|!(){}\[\]^"~*?:\\/]'), (m) => '\\${m[0]}');
}

class _Request {
  _Request(this.key, this.path, this.params, this.turn, this.cancel);
  final String key;
  final String path;
  final Map<String, String> params;
  final MbTurn turn;
  final MbCancel? cancel;
  final done = Completer<Map<String, Object?>>();
}
