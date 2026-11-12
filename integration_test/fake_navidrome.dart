// A tiny Subsonic server on 127.0.0.1 for running the real Windows app
// against: two albums of quiet test tones, with byte-range streaming, a
// play queue that can be set as if the phone left it, and token auth.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Test-only account for the fake server (never a real login).
const fakeUser = 'tester';
const fakePassword = 'test-only-password';

/// Length of every test tone.
const toneLength = Duration(seconds: 24);

class _Track {
  const _Track(this.id, this.title, this.albumId, this.artistId, this.artist, this.album, this.track, this.hz);
  final String id, title, albumId, artistId, artist, album;
  final int track;
  final double hz;

  Map<String, Object> toJson() => {
    'id': id,
    'title': title,
    'album': album,
    'albumId': albumId,
    'artist': artist,
    'artistId': artistId,
    'track': track,
    'discNumber': 1,
    'duration': toneLength.inSeconds,
    'coverArt': albumId,
    'suffix': 'wav',
    'contentType': 'audio/wav',
    'bitRate': 352,
  };
}

const tracks = [
  _Track('a1', 'Tone A', 'al1', 'ar1', 'Test Signal', 'Night Tones', 1, 330),
  _Track('a2', 'Tone B', 'al1', 'ar1', 'Test Signal', 'Night Tones', 2, 392),
  _Track('b1', 'Tone C', 'al2', 'ar2', 'Other Signal', 'Day Tones', 1, 440),
];

class FakeNavidrome {
  FakeNavidrome._(this._server, this._cover);
  final HttpServer _server;
  final Uint8List _cover;
  final _tones = <String, Uint8List>{};

  /// Every request's endpoint and query, oldest first.
  final requests = <Uri>[];

  /// The queue getPlayQueue answers with (as if another device saved it).
  Map<String, Object?>? playQueue;

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<FakeNavidrome> start(Uint8List cover) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeNavidrome._(server, cover);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  Iterable<Uri> calls(String endpoint) => requests.where((u) => u.pathSegments.last == endpoint);

  /// Sets the server's saved queue as the phone would leave it.
  void phoneLeft(String currentId, Duration position) => playQueue = {
    'current': currentId,
    'position': position.inMilliseconds,
    'changed': DateTime.now().toUtc().toIso8601String(),
    'changedBy': 'sonar',
    'username': fakeUser,
    'entry': [for (final t in tracks) t.toJson()],
  };

  Uint8List _tone(_Track t) => _tones.putIfAbsent(t.id, () {
    // Quiet (about -30 dBFS) mono 16-bit PCM with short fades at the ends.
    const rate = 22050;
    final samples = rate * toneLength.inSeconds;
    final data = ByteData(44 + samples * 2);
    void ascii(int at, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 36 + samples * 2, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, 1, Endian.little)
      ..setUint32(24, rate, Endian.little)
      ..setUint32(28, rate * 2, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, samples * 2, Endian.little);
    for (var i = 0; i < samples; i++) {
      final edge = min(1.0, min(i, samples - i) / (rate * 0.02));
      final v = (sin(2 * pi * t.hz * i / rate) * 1000 * edge).round();
      data.setInt16(44 + i * 2, v, Endian.little);
    }
    return data.buffer.asUint8List();
  });

  bool _authorised(Map<String, String> q) {
    final salt = q['s'] ?? '';
    return q['u'] == fakeUser && q['t'] == md5.convert(utf8.encode(fakePassword + salt)).toString();
  }

  Future<void> _handle(HttpRequest req) async {
    final q = req.uri.queryParameters;
    requests.add(req.uri);
    final endpoint = req.uri.pathSegments.isEmpty ? '' : req.uri.pathSegments.last.replaceAll('.view', '');
    final res = req.response;
    if (!_authorised(q)) {
      return _json(res, {
        'status': 'failed',
        'error': {'code': 40, 'message': 'Wrong username or password'},
      });
    }
    switch (endpoint) {
      case 'stream' || 'download':
        final t = tracks.firstWhere((t) => t.id == q['id'], orElse: () => tracks.first);
        return _bytes(req, _tone(t), 'audio/wav');
      case 'getCoverArt':
        return _bytes(req, _cover, 'image/png');
      case 'getAlbumList2':
        return _ok(res, {
          'albumList2': {'album': _albums},
        });
      case 'getAlbum':
        final album = _albums.firstWhere((a) => a['id'] == q['id'], orElse: () => _albums.first);
        return _ok(res, {
          'album': {
            ...album,
            'song': [for (final t in tracks.where((t) => t.albumId == album['id'])) t.toJson()],
          },
        });
      case 'getPlayQueue':
        return _ok(res, playQueue == null ? {} : {'playQueue': playQueue});
      default:
        return _ok(res, {});
    }
  }

  List<Map<String, Object>> get _albums => [
    for (final id in {for (final t in tracks) t.albumId})
      () {
        final songs = tracks.where((t) => t.albumId == id).toList();
        final t = songs.first;
        return {
          'id': id,
          'name': t.album,
          'artist': t.artist,
          'artistId': t.artistId,
          'coverArt': id,
          'songCount': songs.length,
          'duration': toneLength.inSeconds * songs.length,
          'year': 2026,
        };
      }(),
  ];

  Future<void> _ok(HttpResponse res, Map<String, Object?> body) =>
      _json(res, {'status': 'ok', 'version': '1.16.1', 'openSubsonic': true, ...body});

  Future<void> _json(HttpResponse res, Map<String, Object?> body) async {
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode({'subsonic-response': body}));
    await res.close();
  }

  /// Serves [bytes], honouring a byte Range like a real file server.
  Future<void> _bytes(HttpRequest req, Uint8List bytes, String type) async {
    final res = req.response;
    res.headers
      ..set(HttpHeaders.contentTypeHeader, type)
      ..set(HttpHeaders.acceptRangesHeader, 'bytes');
    final range = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(req.headers.value(HttpHeaders.rangeHeader) ?? '');
    var start = 0, end = bytes.length - 1;
    if (range != null) {
      start = int.parse(range[1]!);
      if (range[2]!.isNotEmpty) end = min(int.parse(range[2]!), end);
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${bytes.length}');
    }
    res.contentLength = end - start + 1;
    res.add(Uint8List.sublistView(bytes, start, end + 1));
    await res.close();
  }
}
