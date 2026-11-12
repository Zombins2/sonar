import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/subsonic/subsonic_client.dart';

/// Sonar Connect: this account's other devices, what they're playing, and
/// commands between them, through the relay beside Navidrome
/// (`server/sonar_connect`, design in docs/CONNECT_PLAN.md).

enum ConnectStatus { off, connecting, online, unavailable }

class ConnectDeviceInfo {
  const ConnectDeviceInfo({required this.id, required this.name, required this.kind});
  final String id;
  final String name;

  /// `pc` or `phone`.
  final String kind;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'kind': kind};
}

/// Another device on the account, and the last state it sent.
@immutable
class ConnectDevice {
  const ConnectDevice({
    required this.id,
    required this.name,
    required this.kind,
    required this.state,
    required this.positionAt,
  });

  final String id;
  final String name;
  final String kind;
  final Map<String, Object?> state;

  /// When `positionMs` arrived. While playing, the song has moved on since.
  final DateTime positionAt;

  ConnectDevice merge(Map<String, Object?> patch, DateTime now) => ConnectDevice(
    id: id,
    name: name,
    kind: kind,
    state: {...state, ...patch},
    positionAt: patch.containsKey('positionMs') ? now : positionAt,
  );

  bool get playing => state['playing'] == true;
  bool get hasSong => state['song'] is Map;

  /// Playing with sound coming out: not still opening or buffering the
  /// stream. (Older reports without `ready` count as ready.)
  bool get audible => playing && state['ready'] != false;

  /// Where its song is up to now.
  Duration position(DateTime now) {
    var ms = (state['positionMs'] as num?)?.toInt() ?? 0;
    if (audible) ms += now.difference(positionAt).inMilliseconds;
    final total = (state['durationMs'] as num?)?.toInt() ?? 0;
    return Duration(milliseconds: total > 0 ? ms.clamp(0, total) : max(0, ms));
  }
}

class ConnectCommand {
  const ConnectCommand(this.from, this.cmd, this.args);
  final String from;
  final String cmd;
  final Map<String, Object?> args;
}

/// A [ValueListenable] as a stream: its value now, then each change.
Stream<T> valueStream<T>(ValueListenable<T> v) {
  late final StreamController<T> c;
  void emit() => c.add(v.value);
  c = StreamController<T>(
    onListen: () {
      v.addListener(emit);
      emit();
    },
    onCancel: () => v.removeListener(emit),
  );
  return c.stream;
}

/// The relay's address for a server: beside Navidrome at `/sonar-connect`,
/// or straight to its port for a login to this same computer.
Uri connectBaseFor(String serverUrl) {
  final uri = Uri.parse(serverUrl.trim());
  if (uri.scheme == 'http' && SubsonicClient.isLoopback(uri.host)) return Uri.parse('http://127.0.0.1:4534');
  final path = uri.path.endsWith('/') ? uri.path.substring(0, uri.path.length - 1) : uri.path;
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: '$path/sonar-connect');
}

class ConnectClient {
  ConnectClient({
    required this.base,
    required this.me,
    required this.loginProof,
    HttpClient? http,
    this.retryDelays = const [Duration(seconds: 1), Duration(seconds: 3), Duration(seconds: 10), Duration(seconds: 30)],
    this.silenceLimit = const Duration(seconds: 40),
  }) : _http = http ?? HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 8);
  }

  final Uri base;
  final ConnectDeviceInfo me;

  /// A fresh `{u, t, s}` for each hello.
  final Map<String, String> Function() loginProof;
  final List<Duration> retryDelays;

  /// The relay writes at least every 15 s; nothing for this long means the
  /// connection died quietly (a phone changing networks).
  final Duration silenceLimit;
  final HttpClient _http;

  /// The account's other devices, by id.
  final devices = ValueNotifier<Map<String, ConnectDevice>>(const {});
  final status = ValueNotifier(ConnectStatus.off);
  final _commands = StreamController<ConnectCommand>.broadcast();
  Stream<ConnectCommand> get commands => _commands.stream;

  /// Each time the connection comes up: send this device's whole state.
  VoidCallback? onOnline;

  bool _running = false;
  String? _session;
  int _failures = 0;
  Timer? _retry;
  Timer? _silence;
  StreamSubscription<String>? _events;

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_connect());
  }

  Future<void> dispose() async {
    _running = false;
    _retry?.cancel();
    _silence?.cancel();
    await _events?.cancel();
    _session = null;
    _http.close(force: true);
    status.value = ConnectStatus.off;
    devices.value = const {};
    await _commands.close();
  }

  Uri _url(String path) => base.replace(path: '${base.path}$path');

  Future<void> _connect() async {
    if (!_running) return;
    if (status.value != ConnectStatus.unavailable) status.value = ConnectStatus.connecting;
    try {
      final hello = await _post('/hello', {...loginProof(), 'device': me.toJson()}, session: null);
      final session = hello.$2['session'];
      if (hello.$1 != 200 || session is! String) throw const HttpException('hello refused');
      final request = await _http.getUrl(_url('/events'));
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $session')
        ..set(HttpHeaders.acceptHeader, 'text/event-stream');
      final response = await request.close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw const HttpException('events refused');
      }
      if (!_running) return;
      _session = session;
      _failures = 0;
      status.value = ConnectStatus.online;
      onOnline?.call();
      await _read(response);
    } catch (_) {
      // Retried below.
    }
    _session = null;
    _silence?.cancel();
    if (!_running) return;
    devices.value = const {};
    _failures++;
    // Say "unavailable" once it has failed a few times, not on a blip.
    status.value = _failures >= 3 ? ConnectStatus.unavailable : ConnectStatus.connecting;
    _retry = Timer(retryDelays[min(_failures - 1, retryDelays.length - 1)], _connect);
  }

  Future<void> _read(HttpClientResponse response) {
    final done = Completer<void>();
    String? event;
    final data = StringBuffer();
    void quiet() {
      _silence?.cancel();
      _silence = Timer(silenceLimit, () {
        unawaited(_events?.cancel());
        if (!done.isCompleted) done.complete();
      });
    }

    quiet();
    _events = response
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            quiet();
            if (line.isEmpty) {
              if (event != null && data.isNotEmpty) _dispatch(event!, data.toString());
              event = null;
              data.clear();
            } else if (line.startsWith('event:')) {
              event = line.substring(6).trim();
            } else if (line.startsWith('data:')) {
              if (data.isNotEmpty) data.write('\n');
              data.write(line.substring(5).trimLeft());
            }
          },
          onDone: () => done.isCompleted ? null : done.complete(),
          onError: (Object _) => done.isCompleted ? null : done.complete(),
          cancelOnError: true,
        );
    return done.future;
  }

  void _dispatch(String event, String raw) {
    final Object? data;
    try {
      data = jsonDecode(raw);
    } catch (_) {
      return;
    }
    final now = DateTime.now();
    switch (event) {
      case 'devices' when data is List:
        devices.value = {
          for (final d in data.whereType<Map<String, Object?>>())
            if (d['id'] is String && d['id'] != me.id)
              d['id']! as String: ConnectDevice(
                id: d['id']! as String,
                name: '${d['name'] ?? ''}',
                kind: '${d['kind'] ?? ''}',
                state: d['state'] is Map<String, Object?> ? d['state']! as Map<String, Object?> : const {},
                positionAt: now,
              ),
        };
      case 'state' when data is Map<String, Object?>:
        final id = data['id'];
        final patch = data['state'];
        final known = devices.value[id];
        if (known != null && patch is Map<String, Object?>) {
          devices.value = {...devices.value, known.id: known.merge(patch, now)};
        }
      case 'command' when data is Map<String, Object?>:
        final cmd = data['cmd'];
        if (cmd is String && data['from'] is String) {
          _commands.add(ConnectCommand(data['from']! as String, cmd, data));
        }
    }
  }

  // ---- Sending ----------------------------------------------------------------

  Map<String, Object?> _pending = {};
  bool _sending = false;

  /// Sends changes to this device's state. Changes made while one is in flight
  /// go out together after it.
  void publish(Map<String, Object?> patch) {
    _pending.addAll(patch);
    unawaited(_flush());
  }

  Future<void> _flush() async {
    if (_sending || _session == null || _pending.isEmpty) return;
    _sending = true;
    final body = _pending;
    _pending = {};
    try {
      await _post('/state', body, session: _session);
    } catch (_) {
      // The reconnect sends the whole state again.
    } finally {
      _sending = false;
    }
    if (_pending.isNotEmpty) unawaited(_flush());
  }

  /// Asks device [to] to do [cmd]. False if it isn't connected.
  ///
  /// [args] can't use `to`, `cmd` or `from`: the relay addresses and signs
  /// commands with those.
  Future<bool> send(String to, String cmd, [Map<String, Object?> args = const {}]) async {
    assert(!args.containsKey('to') && !args.containsKey('cmd') && !args.containsKey('from'), 'reserved key in $args');
    final session = _session;
    if (session == null) return false;
    try {
      final r = await _post('/command', {...args, 'to': to, 'cmd': cmd}, session: session);
      return r.$1 == 200;
    } catch (_) {
      return false;
    }
  }

  /// Asks the relay to have Navidrome scan for new music (an album Soulbeet
  /// just filed). True if a scan started or one is already running; false if
  /// the relay can't (not connected, or no admin login set up on the server).
  Future<bool> rescan() async {
    final session = _session;
    if (session == null) return false;
    try {
      final r = await _post('/rescan', const {}, session: session);
      return r.$1 == 200;
    } catch (_) {
      return false;
    }
  }

  /// Shows a change on another device straight away, ahead of it reporting
  /// back (a pause pressed here), so the controls feel immediate.
  void assume(String deviceId, Map<String, Object?> patch) {
    final known = devices.value[deviceId];
    if (known != null) devices.value = {...devices.value, deviceId: known.merge(patch, DateTime.now())};
  }

  Future<(int, Map<String, Object?>)> _post(String path, Map<String, Object?> body, {required String? session}) async {
    final request = await _http.postUrl(_url(path));
    request.headers.contentType = ContentType.json;
    if (session != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $session');
    final bytes = utf8.encode(jsonEncode(body));
    // The relay reads Content-Length; a chunked body would arrive empty.
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close().timeout(const Duration(seconds: 10));
    final text = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
    Object? json;
    try {
      json = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {}
    return (response.statusCode, json is Map<String, Object?> ? json : const <String, Object?>{});
  }
}
