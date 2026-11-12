import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/playback_source.dart';
import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/subsonic/models.dart';
import '../../state/providers.dart';
import 'common.dart';
import 'cover_art.dart';
import 'download_widgets.dart';
import 'now_playing_bars.dart';
import 'song_menu.dart';

/// Square art with a two-line caption, for carousels and grids.
class AlbumCard extends StatelessWidget {
  const AlbumCard({super.key, required this.album, this.width, this.heroPrefix = 'album', this.subtitle});
  final Album album;
  final double? width;
  final String heroPrefix;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final tag = '$heroPrefix-${album.id}';
    final text = Theme.of(context).textTheme;
    final card = GestureDetector(
      onTap: () => context.openAlbum(album.id, heroTag: tag, preview: album),
      onLongPress: () => showAlbumQuickActions(context, album),
      onSecondaryTap: () => showAlbumQuickActions(context, album),
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _withBadge(
            CoverArt(coverArt: album.coverArt, size: width, heroTag: tag, shadow: true),
            PlayingBadge.album(album.id),
          ),
          const SizedBox(height: 8),
          Text(
            album.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(subtitle ?? album.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
        ],
      ),
    );
    return width == null ? card : SizedBox(width: width, child: card);
  }
}

class AlbumListTile extends StatelessWidget {
  const AlbumListTile({super.key, required this.album, this.heroPrefix = 'album-list'});
  final Album album;
  final String heroPrefix;

  @override
  Widget build(BuildContext context) {
    final tag = '$heroPrefix-${album.id}';
    return _MediaRow(
      leading: _withBadge(
        CoverArt(coverArt: album.coverArt, size: 56, heroTag: tag, radius: 8),
        PlayingBadge.album(album.id),
        inset: 3,
      ),
      title: album.name,
      subtitle: [album.artist, if (album.year != null && album.year! > 0) '${album.year}'].join(' · '),
      onTap: () => context.openAlbum(album.id, heroTag: tag, preview: album),
      onLongPress: () => showAlbumQuickActions(context, album),
    );
  }
}

class ArtistCard extends StatelessWidget {
  const ArtistCard({super.key, required this.artist, this.width = 120});
  final Artist artist;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: GestureDetector(
      onTap: () => context.openArtist(artist.id),
      behavior: HitTestBehavior.opaque,
      child: Column(
        children: [
          CoverArt(coverArt: artist.coverArt, size: width, circle: true, icon: Icons.person_rounded),
          const SizedBox(height: 8),
          Text(
            artist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    ),
  );
}

class ArtistListTile extends StatelessWidget {
  const ArtistListTile({super.key, required this.artist});
  final Artist artist;

  @override
  Widget build(BuildContext context) => _MediaRow(
    leading: CoverArt(coverArt: artist.coverArt, size: 56, circle: true, icon: Icons.person_rounded),
    title: artist.name,
    subtitle: artist.albumCount == 1 ? '1 album' : '${artist.albumCount} albums',
    onTap: () => context.openArtist(artist.id),
  );
}

class PlaylistListTile extends StatelessWidget {
  const PlaylistListTile({super.key, required this.playlist});
  final Playlist playlist;

  @override
  Widget build(BuildContext context) => _MediaRow(
    leading: _withBadge(
      CoverArt(
        coverArt: playlist.coverArt,
        size: 56,
        radius: 8,
        icon: Icons.queue_music_rounded,
        heroTag: 'playlist-${playlist.id}',
      ),
      PlayingBadge.playlist(playlist.id),
      inset: 3,
    ),
    title: playlist.name,
    subtitle: '${playlist.songCount} songs${playlist.owner != null ? ' · ${playlist.owner}' : ''}',
    onTap: () => context.openPlaylist(playlist.id, preview: playlist),
    onLongPress: () => showPlaylistQuickActions(context, playlist),
  );
}

class PlaylistCard extends StatelessWidget {
  const PlaylistCard({super.key, required this.playlist});
  final Playlist playlist;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => context.openPlaylist(playlist.id, preview: playlist),
    onLongPress: () => showPlaylistQuickActions(context, playlist),
    onSecondaryTap: () => showPlaylistQuickActions(context, playlist),
    behavior: HitTestBehavior.opaque,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _withBadge(
          CoverArt(
            coverArt: playlist.coverArt,
            shadow: true,
            icon: Icons.queue_music_rounded,
            heroTag: 'playlist-${playlist.id}',
          ),
          PlayingBadge.playlist(playlist.id),
        ),
        const SizedBox(height: 8),
        Text(
          playlist.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        Text('${playlist.songCount} songs', style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

/// A track row. [queue] + [index] say what to play when it's tapped.
class SongTile extends ConsumerWidget {
  const SongTile({
    super.key,
    required this.song,
    required this.queue,
    required this.index,
    this.showArt = true,
    this.trackNumber,
    this.contextAlbumId,
    this.contextArtist,
    this.source,
  });

  final Song song;
  final List<Song> queue;
  final int index;
  final bool showArt;
  final int? trackNumber;

  /// Set on album pages so the menu hides the redundant "Go to album".
  final String? contextAlbumId;

  /// The page's artist: rows by them skip the artist line (cleaner album pages).
  final String? contextArtist;

  /// The page this list belongs to, recorded when a tap starts playback.
  final PlaybackSource? source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCurrent = ref.watch(currentSongIdProvider) == song.id;
    final playing = isCurrent && (ref.watch(playingProvider).valueOrNull ?? false);
    final accent = isCurrent ? buttonColorFor(watchCoverColor(ref, song.coverArt)) : null;
    final Widget leading;
    if (showArt) {
      leading = SizedBox.square(
        dimension: 48,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CoverArt(coverArt: song.coverArt, size: 48, radius: 6),
            if (isCurrent)
              DecoratedBox(
                decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(6)),
                child: Center(
                  child: NowPlayingBars(color: Colors.white, animate: playing, size: 18),
                ),
              ),
          ],
        ),
      );
    } else {
      leading = SizedBox(
        width: 28,
        child: isCurrent
            ? Center(
                child: NowPlayingBars(color: accent!, animate: playing),
              )
            : Text(
                trackNumber?.toString() ?? '',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
      );
    }

    // Offline, tracks that aren't downloaded can't play: fade them back.
    final unavailable =
        !ref.watch(reachableProvider) && !ref.watch(downloadManagerProvider.select((m) => m.isDownloaded(song.id)));

    final row = _MediaRow(
      leading: leading,
      title: song.title,
      titleColor: accent,
      subtitle: showArt
          ? (song.artist == contextArtist ? song.album : '${song.artist} · ${song.album}')
          : song.artist == contextArtist
          ? ''
          : song.artist,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SongDownloadMark(song.id),
          Text(formatDuration(song.duration), style: Theme.of(context).textTheme.bodySmall),
          IconButton(
            tooltip: 'More',
            // Compact keeps one-line album rows tight; the tap target is still 40dp.
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.more_vert_rounded, color: SonarColors.textSecondary),
            onPressed: () => showSongMenu(context, song, hideAlbumLink: contextAlbumId == song.albumId),
          ),
        ],
      ),
      dense: !showArt,
      onTap: () {
        final handler = ref.read(controlsProvider);
        // Tapping the track that's already loaded just toggles it.
        if (isCurrent) {
          playing ? handler.pause() : handler.play();
        } else {
          handler.playSongs(queue, index: index, source: source);
        }
      },
      onLongPress: () => showSongMenu(context, song, hideAlbumLink: contextAlbumId == song.albumId),
    );

    return SwipeToQueue(
      song: song,
      child: AnimatedOpacity(opacity: unavailable ? 0.4 : 1, duration: SonarMotion.fast, child: row),
    );
  }
}

/// Swipe a track right to add it to the end of the queue. The row springs back;
/// nothing is removed.
class SwipeToQueue extends ConsumerWidget {
  const SwipeToQueue({super.key, required this.song, required this.child});
  final Song song;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Dismissible(
    // Only needs to be unique among its siblings, which is just this child.
    key: ValueKey('swipe-${song.id}'),
    direction: DismissDirection.startToEnd,
    dismissThresholds: const {DismissDirection.startToEnd: 0.25},
    background: Container(
      color: SonarColors.accentDefault,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 24),
      child: const Row(
        children: [
          Icon(Icons.queue_music_rounded, color: Colors.black),
          SizedBox(width: 10),
          Text(
            'Add to queue',
            style: TextStyle(color: Colors.black, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    ),
    confirmDismiss: (_) async {
      HapticFeedback.mediumImpact();
      await ref.read(controlsProvider).addToQueue([song]);
      if (context.mounted) showSnack(context, 'Added "${song.title}" to queue');
      return false;
    },
    child: child,
  );
}

/// Queue row built from a [MediaItem] rather than a [Song].
class MediaItemTile extends ConsumerWidget {
  const MediaItemTile({super.key, required this.item, this.trailing, this.onTap, this.highlight});
  final MediaItem item;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Set for the current track: tints the title and overlays playing bars.
  final Color? highlight;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _MediaRow(
    leading: SizedBox.square(
      dimension: 48,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CoverArt(coverArt: item.extras?['coverArt'] as String?, size: 48, radius: 6),
          if (highlight != null)
            DecoratedBox(
              decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(6)),
              child: Center(
                child: NowPlayingBars(
                  color: Colors.white,
                  animate: ref.watch(playingProvider).valueOrNull ?? false,
                  size: 18,
                ),
              ),
            ),
        ],
      ),
    ),
    title: item.title,
    titleColor: highlight,
    subtitle: item.artist ?? '',
    trailing: trailing,
    onTap: onTap,
  );
}

/// Pins a [PlayingBadge] to the bottom-right corner of cover art.
Widget _withBadge(Widget art, Widget badge, {double inset = 8}) => Stack(
  children: [
    art,
    Positioned(right: inset, bottom: inset, child: badge),
  ],
);

/// Spacing-separated row, no dividers (the Apple Music cleanliness).
class _MediaRow extends StatelessWidget {
  const _MediaRow({
    required this.leading,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.titleColor,
    this.dense = false,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? titleColor;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress, // Right-click on desktop.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter, vertical: 6),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleMedium?.copyWith(fontSize: 15, color: titleColor),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                  ],
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// Horizontal carousel of album cards.
class AlbumCarousel extends StatelessWidget {
  const AlbumCarousel({super.key, required this.albums, required this.heroPrefix, this.cardWidth = 148});
  final List<Album> albums;
  final String heroPrefix;
  final double cardWidth;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: cardWidth + 52,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter),
      itemCount: albums.length,
      separatorBuilder: (_, _) => const SizedBox(width: 14),
      itemBuilder: (_, i) => AlbumCard(album: albums[i], width: cardWidth, heroPrefix: heroPrefix),
    ),
  );
}
