import 'package:audio_service/audio_service.dart';

import '../data/subsonic/models.dart';
import '../data/subsonic/subsonic_client.dart';
import '../downloads/download_manager.dart';
import 'playback_source.dart';

/// The menu tree Android Auto browses. IDs:
///   root → folders below
///   `albums:<type>` → albums           `playlists` → playlists
///   `downloads` → downloaded albums / playlists
///   `album:<id>` / `playlist:<id>` → tracks
///   `play:<kind>:<id>:<index>` → playable track inside that collection
class CarBrowser {
  CarBrowser(this.client, this.downloads);
  final SubsonicClient client;
  final DownloadManager? downloads;

  static const _folders = [
    ('albums:recent', 'Recently played'),
    ('albums:newest', 'Recently added'),
    ('albums:starred', 'Favorites'),
    ('playlists', 'Playlists'),
    ('downloads', 'Downloads'),
  ];

  Uri? _art(String? coverArt) => coverArt == null ? null : client.coverArtUrl(coverArt, size: 300);

  MediaItem _folder(String id, String title, {String? subtitle, String? coverArt}) =>
      MediaItem(id: id, title: title, artist: subtitle, artUri: _art(coverArt), playable: false);

  Future<List<MediaItem>> children(String parentId) async {
    if (parentId == AudioService.browsableRootId) {
      return [for (final (id, title) in _folders) _folder(id, title)];
    }
    final colon = parentId.indexOf(':');
    final head = colon < 0 ? parentId : parentId.substring(0, colon);
    final rest = colon < 0 ? '' : parentId.substring(colon + 1);
    switch (head) {
      case 'albums':
        final type = AlbumListType.values.byName(rest);
        final albums = await client.getAlbumList2(type, size: 40);
        return [for (final a in albums) _folder('album:${a.id}', a.name, subtitle: a.artist, coverArt: a.coverArt)];
      case 'playlists':
        final lists = await client.getPlaylists();
        return [
          for (final p in lists)
            _folder('playlist:${p.id}', p.name, subtitle: '${p.songCount} songs', coverArt: p.coverArt),
        ];
      case 'downloads':
        return [
          for (final c in downloads?.collections ?? const <DownloadedCollection>[])
            if (c.kind != 'song')
              _folder('${c.kind}:${c.sourceId}', c.title, subtitle: c.subtitle, coverArt: c.coverArt),
        ];
      case 'album' || 'playlist':
        final (:songs, title: _) = await tracks(head, rest);
        return [
          for (var i = 0; i < songs.length; i++)
            MediaItem(
              id: 'play:$head:$rest:$i',
              title: songs[i].title,
              artist: songs[i].artist,
              album: songs[i].album,
              duration: songs[i].duration,
              artUri: _art(songs[i].coverArt),
            ),
        ];
    }
    return const [];
  }

  /// Track list of an album or playlist, falling back to the downloaded copy offline.
  Future<({List<Song> songs, String title})> tracks(String kind, String id) async {
    try {
      if (kind == 'album') {
        final a = await client.getAlbum(id);
        return (songs: a.songs, title: a.name);
      }
      final p = await client.getPlaylist(id);
      return (songs: p.songs, title: p.name);
    } on SubsonicException {
      final saved = downloads?.collection(kind, id);
      if (saved == null) rethrow;
      return (songs: saved.songs, title: saved.title);
    }
  }

  /// Resolves a `play:` id to the queue, start index and source to play.
  Future<({List<Song> songs, int index, PlaybackSource source})?> resolve(String mediaId) async {
    final parts = mediaId.split(':');
    if (parts.length != 4 || parts[0] != 'play') return null;
    final kind = parts[1], id = parts[2];
    final index = int.tryParse(parts[3]) ?? 0;
    final (:songs, :title) = await tracks(kind, id);
    if (songs.isEmpty) return null;
    return (
      songs: songs,
      index: index.clamp(0, songs.length - 1),
      source: PlaybackSource(kind == 'album' ? SourceKind.album : SourceKind.playlist, id, title),
    );
  }

  /// Voice search ("play X on Sonar"): best-matching songs.
  Future<List<Song>> searchSongs(String query) async =>
      (await client.search3(query, artistCount: 0, albumCount: 0, songCount: 30)).songs;
}
