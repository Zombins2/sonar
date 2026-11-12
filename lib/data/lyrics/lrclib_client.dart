import 'package:dio/dio.dart';

import '../subsonic/models.dart';

/// Finds time-synced lyrics on LRCLIB (lrclib.net), a free public lyrics
/// database, for songs whose files only carry plain text. Sends the track's
/// title and artist; nothing about the user or their server.
class LrclibClient {
  LrclibClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://lrclib.net',
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 10),
              headers: {'User-Agent': 'Sonar (Navidrome client for Android)'},
            ),
          );

  static const credit = 'LRCLIB';

  /// Timing from a different master (remaster, single edit) drifts, so only
  /// accept a match whose length is this close to the file's.
  static const tolerance = Duration(seconds: 3);

  final Dio _dio;

  /// LRC text of the best synced match, or null if LRCLIB has none for this
  /// exact recording. Throws [DioException] when LRCLIB can't be reached.
  Future<String?> findLrc({required String title, required String artist, required Duration duration}) async {
    final res = await _dio.get<Object>('/api/search', queryParameters: {'track_name': title, 'artist_name': artist});
    final results = res.data;
    if (results is! List) return null;
    String? best;
    var bestGap = tolerance + const Duration(milliseconds: 1);
    for (final r in results) {
      if (r is! Map || r['instrumental'] == true) continue;
      final lrc = r['syncedLyrics'];
      if (lrc is! String || Lyrics.fromLrc(lrc) == null) continue;
      final length = Duration(milliseconds: (((r['duration'] as num?) ?? 0) * 1000).round());
      final gap = duration > Duration.zero ? (length - duration).abs() : Duration.zero;
      if (gap >= bestGap) continue;
      best = lrc;
      bestGap = gap;
      if (duration <= Duration.zero) break; // Unknown length: first synced hit.
    }
    return best;
  }
}
