import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:sonar/data/subsonic/models.dart';
import 'package:sonar/data/subsonic/subsonic_client.dart';

/// Serves canned JSON per endpoint, or fails like an unreachable host.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.responses);
  final Map<String, Object> responses;
  final requests = <Uri>[];
  bool offline = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    if (offline) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
        error: const SocketException('Failed host lookup'),
      );
    }
    final endpoint = options.uri.pathSegments.last;
    final body =
        responses[endpoint] ??
        {
          'subsonic-response': {'status': 'ok'},
        };
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class MemoryCache implements ResponseCache {
  final store = <String, Json>{};
  @override
  Future<Json?> read(String key) async => store[key];
  @override
  Future<void> write(String key, Json value) async => store[key] = value;
}

Map<String, Object> ok(Map<String, Object> body) => {
  'subsonic-response': {'status': 'ok', 'version': '1.16.1', ...body},
};

const testCreds = ServerCredentials(baseUrl: 'https://music.example.ts.net/', username: 'alice', password: 's3cret!');

typedef FakeServer = ({SubsonicClient client, FakeAdapter adapter, MemoryCache cache, List<bool> reach});

FakeServer fakeServer(Map<String, Object> responses, {bool withCache = true}) {
  final adapter = FakeAdapter(responses);
  final dio = Dio()..httpClientAdapter = adapter;
  final cache = MemoryCache();
  final reach = <bool>[];
  final client = SubsonicClient(testCreds, dio: dio, cache: withCache ? cache : null, onReachability: reach.add);
  return (client: client, adapter: adapter, cache: cache, reach: reach);
}
