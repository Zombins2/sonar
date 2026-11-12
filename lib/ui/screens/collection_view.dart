import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/playback_source.dart';
import '../../core/nav.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/subsonic/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import '../widgets/download_widgets.dart';
import '../widgets/media_tiles.dart';
import '../widgets/now_playing_bars.dart';

/// Shared layout for album and playlist pages: cover-tinted gradient header,
/// big art, title block, play/shuffle, then the track list. With [loading]
/// it draws the header from what the previous page knew and placeholder rows.
class CollectionView extends ConsumerStatefulWidget {
  const CollectionView({
    super.key,
    required this.coverArt,
    required this.heroTag,
    required this.title,
    required this.byline,
    required this.meta,
    required this.songs,
    required this.source,
    this.onBylineTap,
    this.isStarred,
    this.onToggleStar,
    this.onMore,
    this.onEdit,
    this.numbered = false,
    this.albumId,
    this.placeholderIcon = Icons.album_rounded,
    this.loading = false,
    this.downloadable = true,
  });

  final String? coverArt;
  final Object heroTag;
  final String title;
  final String byline;
  final String meta;
  final List<Song> songs;
  final PlaybackSource source;
  final VoidCallback? onBylineTap;
  final bool? isStarred;
  final VoidCallback? onToggleStar;
  final VoidCallback? onMore;
  final VoidCallback? onEdit;

  /// Album pages show track numbers instead of per-row art.
  final bool numbered;
  final String? albumId;
  final IconData placeholderIcon;
  final bool loading;

  /// Off for mixes, which change from day to day.
  final bool downloadable;

  @override
  ConsumerState<CollectionView> createState() => _CollectionViewState();
}

class _CollectionViewState extends ConsumerState<CollectionView> {
  final _titleBar = ValueNotifier(0.0);

  @override
  void dispose() {
    _titleBar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final songs = w.songs;
    final color = watchCoverColor(ref, w.coverArt);
    final button = buttonColorFor(color);
    final handler = ref.read(controlsProvider);
    final current = ref.watch(currentSongIdProvider);
    final playing = ref.watch(playingProvider).valueOrNull ?? false;
    final currentSource = ref.watch(playbackSourceProvider).valueOrNull;
    // This page "owns" playback if it started it, or (for queues started from
    // search etc.) if the current track belongs to it.
    final isThisSource = currentSource == w.source || (currentSource == null && songs.any((s) => s.id == current));
    final playingThis = playing && isThisSource;
    final nowTitle = ref.watch(mediaItemProvider).valueOrNull?.title;
    final text = Theme.of(context).textTheme;
    final width = MediaQuery.sizeOf(context).width;
    // Wide windows put the cover beside the title, like a desktop player.
    final wide = isWideLayout(context);
    final artSize = wide ? 220.0 : (width * 0.62).clamp(160.0, 320.0);
    final multiDisc = w.numbered && songs.map((s) => s.discNumber ?? 1).toSet().length > 1;

    final rows = <Widget>[];
    int? disc;
    for (var i = 0; i < songs.length; i++) {
      final s = songs[i];
      if (multiDisc && s.discNumber != disc) {
        disc = s.discNumber;
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, 16, SonarSpacing.gutter, 6),
            child: Row(
              children: [
                const Icon(Icons.album_outlined, size: 18, color: SonarColors.textSecondary),
                const SizedBox(width: 8),
                Text('Disc ${disc ?? 1}', style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        );
      }
      rows.add(
        SongTile(
          song: s,
          queue: songs,
          index: i,
          showArt: !w.numbered,
          trackNumber: s.track ?? i + 1,
          contextAlbumId: w.albumId,
          // On an album, only name the artist on tracks by someone else (features, compilations).
          contextArtist: w.numbered ? w.byline : null,
          source: w.source,
        ),
      );
    }

    final cover = CoverArt(
      coverArt: w.coverArt,
      size: artSize,
      heroTag: w.heroTag,
      shadow: true,
      icon: w.placeholderIcon,
    );
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          w.title,
          maxLines: wide ? 2 : null,
          overflow: wide ? TextOverflow.ellipsis : null,
          style: wide
              ? text.headlineLarge?.copyWith(fontSize: 44, height: 1.1, fontWeight: FontWeight.w800)
              : text.headlineMedium?.copyWith(fontSize: 24),
        ),
        SizedBox(height: wide ? 12 : 6),
        GestureDetector(
          onTap: w.onBylineTap,
          child: MouseRegion(
            cursor: w.onBylineTap == null ? MouseCursor.defer : SystemMouseCursors.click,
            child: Text(w.byline, style: text.titleMedium?.copyWith(fontSize: wide ? 15 : 14)),
          ),
        ),
        const SizedBox(height: 4),
        AnimatedOpacity(
          opacity: w.meta.isEmpty ? 0 : 1,
          duration: SonarMotion.fast,
          child: Text(w.meta.isEmpty ? ' ' : w.meta, style: text.bodySmall),
        ),
        AnimatedSize(
          duration: SonarMotion.normal,
          curve: SonarMotion.curve,
          child: !isThisSource || nowTitle == null
              ? const SizedBox(width: double.infinity)
              : GestureDetector(
                  onTap: context.openNowPlaying,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(
                      children: [
                        NowPlayingBars(color: button, animate: playing, size: 14),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '${playing ? 'Now playing' : 'Paused'} · $nowTitle',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(
                              color: SonarColors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
    final star = w.onToggleStar == null
        ? null
        : IconButton(
            tooltip: w.isStarred == true ? 'Remove from favorites' : 'Add to favorites',
            icon: AnimatedSwitcher(
              duration: SonarMotion.fast,
              transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
              child: Icon(
                w.isStarred == true ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                key: ValueKey(w.isStarred == true),
                color: w.isStarred == true ? button : SonarColors.textSecondary,
              ),
            ),
            onPressed: w.onToggleStar,
          );
    final shuffle = IconButton(
      iconSize: 28,
      tooltip: 'Shuffle',
      icon: const Icon(Icons.shuffle_rounded, color: SonarColors.textSecondary),
      onPressed: songs.isEmpty ? null : () => handler.playSongs(songs, shuffle: true, source: w.source),
    );
    final play = PlayButton(
      color: button,
      playing: playingThis,
      onPressed: songs.isEmpty
          ? null
          : () {
              if (playingThis) {
                handler.pause();
              } else if (isThisSource) {
                handler.play();
              } else {
                handler.playSongs(songs, source: w.source);
              }
            },
    );
    final extras = <Widget>[
      if (songs.isNotEmpty && w.downloadable && !isDesktopPlatform)
        DownloadButton(
          kind: w.source.kind.name,
          sourceId: w.source.id,
          title: w.title,
          subtitle: w.byline,
          coverArt: w.coverArt,
          songs: songs,
          accent: button,
        ),
      if (w.onEdit != null)
        IconButton(
          tooltip: 'Edit playlist',
          icon: const Icon(Icons.edit_outlined, color: SonarColors.textSecondary),
          onPressed: w.onEdit,
        ),
      if (w.onMore != null)
        IconButton(
          tooltip: 'More',
          icon: const Icon(Icons.more_vert_rounded, color: SonarColors.textSecondary),
          onPressed: w.onMore,
        ),
    ];

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: FadingTitleBar(progress: _titleBar, title: w.title, color: barColorFor(color)),
      body: NotificationListener<ScrollNotification>(
        // The bar turns solid as the big title slides under it.
        onNotification: FadingTitleBar.tracker(_titleBar, wide ? artSize : artSize + 64, span: 40),
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: AnimatedContainer(
                duration: SonarMotion.normal,
                curve: SonarMotion.curve,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [color.withValues(alpha: 0.85), color.withValues(alpha: 0.25), SonarColors.background],
                    stops: const [0, 0.6, 1],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: wide
                        ? const EdgeInsets.fromLTRB(24, 8, 24, 8)
                        : const EdgeInsets.fromLTRB(SonarSpacing.gutter, 48, SonarSpacing.gutter, 0),
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              cover,
                              const SizedBox(width: 28),
                              Expanded(child: info),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Center(child: cover),
                              const SizedBox(height: 24),
                              info,
                            ],
                          ),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: wide
                    ? const EdgeInsets.fromLTRB(24, 16, 24, 8)
                    : const EdgeInsets.fromLTRB(4, 8, SonarSpacing.gutter, 8),
                child: Row(
                  children: wide
                      ? [play, const SizedBox(width: 16), shuffle, ?star, ...extras, const Spacer()]
                      : [?star, ...extras, const Spacer(), shuffle, const SizedBox(width: 8), play],
                ),
              ),
            ),
            if (w.loading)
              SliverToBoxAdapter(child: SkeletonRows(art: !w.numbered))
            else if (songs.isEmpty)
              const SliverToBoxAdapter(
                child: EmptyState(icon: Icons.music_off_rounded, title: 'No songs here yet'),
              )
            else
              SliverList.list(children: rows),
            const SliverBottomSpacer(),
          ],
        ),
      ),
    );
  }
}
