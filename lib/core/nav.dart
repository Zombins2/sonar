import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../data/subsonic/models.dart';
import 'platform.dart';

const shellBranches = ['home', 'search', 'library'];

/// The tab under any full-screen route; kept current by the app shell.
final currentShellBranch = ValueNotifier<String>('home');

/// What the tapped card already knows, so a detail page can draw its header
/// (and land the cover's hero flight) before the full track list arrives.
class DetailPreview {
  const DetailPreview({this.heroTag, this.title, this.subtitle, this.coverArt});
  DetailPreview.album(Album a, {this.heroTag}) : title = a.name, subtitle = a.artist, coverArt = a.coverArt;
  DetailPreview.playlist(Playlist p, {this.heroTag}) : title = p.name, subtitle = p.owner, coverArt = p.coverArt;

  final Object? heroTag;
  final String? title;
  final String? subtitle;
  final String? coverArt;

  /// Route `extra` may be a bare hero tag (older callers) or a preview.
  static DetailPreview of(Object? extra) => extra is DetailPreview ? extra : DetailPreview(heroTag: extra);
}

/// Detail pages live inside whichever tab they were opened from, so the bottom
/// nav and mini player stay put and each tab keeps its own back stack.
extension SonarNav on BuildContext {
  String get _branch {
    String location;
    try {
      location = GoRouterState.of(this).matchedLocation;
    } catch (_) {
      location = GoRouter.of(this).state.matchedLocation;
    }
    final segments = location.split('/').where((s) => s.isNotEmpty);
    final first = segments.isEmpty ? '' : segments.first;
    return shellBranches.contains(first) ? first : currentShellBranch.value;
  }

  void openAlbum(String id, {Object? heroTag, Album? preview}) =>
      push('/$_branch/album/$id', extra: preview == null ? heroTag : DetailPreview.album(preview, heroTag: heroTag));
  void openArtist(String id) => push('/$_branch/artist/$id');
  void openPlaylist(String id, {Playlist? preview}) => push(
    '/$_branch/playlist/$id',
    extra: preview == null ? null : DetailPreview.playlist(preview, heroTag: 'playlist-$id'),
  );
  void openMix(String artistId, {DetailPreview? preview}) => push('/$_branch/mix/$artistId', extra: preview);
  void openGenre(String name, {Color? color}) => push('/$_branch/genre/${Uri.encodeComponent(name)}', extra: color);

  /// Get music, searching [query] straight away if given.
  void openGetMusic({String? query}) => push('/$_branch/get-music', extra: query);
  void openMusicDownloads() {
    if (!isMusicDownloadsLocation(GoRouter.of(this).state.matchedLocation)) push('/$_branch/get-music/downloads');
  }

  void openNowPlaying() => push('/now-playing');
  void openQueue() => push('/queue');
  void openSettings() {
    if (!isWideLayout(this)) {
      push('/settings');
    } else if (!isSettingsLocation(GoRouter.of(this).state.matchedLocation)) {
      push('/$_branch/settings');
    }
  }
}

bool isGetMusicLocation(String location) => location.contains('/get-music');
bool isMusicDownloadsLocation(String location) => location.endsWith('/get-music/downloads');

/// Settings, either full-screen (phone) or inside a tab (wide windows).
bool isSettingsLocation(String location) => location == '/settings' || location.endsWith('/settings');
