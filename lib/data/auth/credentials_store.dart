import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../subsonic/subsonic_client.dart';

/// Server URL, username and password live only in Android's encrypted storage.
class CredentialsStore {
  CredentialsStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kUrl = 'server_url';
  static const _kUser = 'username';
  static const _kPass = 'password';

  Future<ServerCredentials?> load() async {
    final values = await _storage.readAll();
    final url = values[_kUrl], user = values[_kUser], pass = values[_kPass];
    if (url == null || user == null || pass == null) return null;
    return ServerCredentials(baseUrl: url, username: user, password: pass);
  }

  Future<void> save(ServerCredentials c) async {
    await _storage.write(key: _kUrl, value: c.baseUrl);
    await _storage.write(key: _kUser, value: c.username);
    await _storage.write(key: _kPass, value: c.password);
  }

  /// Soulbeet's login cookie (30 days), so the app doesn't send the password
  /// to it every launch. Cleared with everything else on logout.
  static const _kSoulbeet = 'soulbeet_token';
  Future<String?> soulbeetToken() => _storage.read(key: _kSoulbeet);
  Future<void> saveSoulbeetToken(String? token) =>
      token == null ? _storage.delete(key: _kSoulbeet) : _storage.write(key: _kSoulbeet, value: token);

  Future<void> clear() => _storage.deleteAll();
}
