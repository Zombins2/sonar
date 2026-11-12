import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/nav.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/discovery.dart';
import '../../data/subsonic/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import '../widgets/media_tiles.dart';
import '../widgets/now_playing_bars.dart';
import '../widgets/song_menu.dart';

String greeting([DateTime? now]) {
  final h = (now ?? DateTime.now()).hour;
  if (h < 5) return 'Good night';
  if (h < 12) return 'Good morning';
  if (h < 18) return 'Good afternoon';
  return 'Good evening';
}

const _topRows = [(AlbumListType.newest, 'Recently Added'), (AlbumListType.recent, 'Recently Played')];
const _bottomRows = [
  (AlbumListType.frequent, 'Most Played'),
  (AlbumListType.random, 'Random Picks'),
  (AlbumListType.starred, 'Favorites'),
];
const _rows = [..._topRows, ..._bottomRows];

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _refresh(WidgetRef ref) async {
    for (final (type, _) in _rows) {
      ref.invalidate(albumListProvider(type));
    }
    ref
      ..invalidate(starredProvider)
      ..invalidate(mixSeedsProvider)
      ..invalidate(mixProvider)
      ..invalidate(rediscoverProvider)
      ..invalidate(unplayedProvider);
    await Future.wait([
      for (final (type, _) in _rows) ref.read(albumListProvider(type).future).catchError((_) => <Album>[]),
    ]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(albumListProvider(AlbumListType.recent));
    final newest = ref.watch(albumListProvider(AlbumListType.newest));
    final quick = (recent.valueOrNull?.isNotEmpty ?? false)
        ? recent.valueOrNull!
        : newest.valueOrNull ?? const <Album>[];
    final allFailed = newest.hasError && recent.hasError;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () => _refresh(ref),
        edgeOffset: MediaQuery.paddingOf(context).top,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverSafeArea(
              bottom: false,
              sliver: SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, 20, 8, 4),
                  child: Row(
                    children: [
                      Expanded(child: Text(greeting(), style: Theme.of(context).textTheme.headlineMedium)),
                      // Wide windows have Settings in the sidebar.
                      if (!isWideLayout(context))
                        IconButton(
                          icon: const Icon(Icons.settings_outlined),
                          tooltip: 'Settings',
                          onPressed: context.openSettings,
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (allFailed)
              SliverFillRemaining(
                hasScrollBody: false,
                child: ErrorState(error: newest.error!, onRetry: () => _refresh(ref)),
              )
            else if (newest.isLoading && recent.isLoading)
              const SliverFillRemaining(hasScrollBody: false, child: LoadingState())
            else ...[
              if (quick.isNotEmpty) _QuickPicks(albums: quick.take(6).toList()),
              const _MadeForYou(),
              for (final (type, title) in _topRows) _AlbumRow(type: type, title: title),
              _DiscoveryRow(title: 'Rediscover', albums: ref.watch(rediscoverProvider).valueOrNull, id: 'rediscover'),
              _DiscoveryRow(title: 'Not played yet', albums: ref.watch(unplayedProvider).valueOrNull, id: 'unplayed'),
              for (final (type, title) in _bottomRows) _AlbumRow(type: type, title: title),
            ],
            const SliverBottomSpacer(),
          ],
        ),
      ),
    );
  }
}

/// The Spotify-style 2-column grid of compact album tiles.
class _QuickPicks extends StatelessWidget {
  const _QuickPicks({required this.albums});
  final List<Album> albums;

  @override
  Widget build(BuildContext context) => SliverPadding(
    padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, 16, SonarSpacing.gutter, 0),
    sliver: SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: isWideLayout(context) ? 3 : 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        mainAxisExtent: 56,
      ),
      itemCount: albums.length,
      itemBuilder: (context, i) {
        final a = albums[i];
        final tag = 'quick-${a.id}';
        return Material(
          color: SonarColors.surfaceElevated,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => context.openAlbum(a.id, heroTag: tag, preview: a),
            onLongPress: () => showAlbumQuickActions(context, a),
            onSecondaryTap: () => showAlbumQuickActions(context, a),
            child: Row(
              children: [
                CoverArt(coverArt: a.coverArt, size: 56, radius: 0, heroTag: tag),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    a.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: SonarColors.textPrimary, fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _AlbumRow extends ConsumerWidget {
  const _AlbumRow({required this.type, required this.title});
  final AlbumListType type;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      _DiscoveryRow(title: title, albums: ref.watch(albumListProvider(type)).valueOrNull, id: type.name);
}

/// A titled album carousel that stays out of the way until it has something.
class _DiscoveryRow extends StatelessWidget {
  const _DiscoveryRow({required this.title, required this.albums, required this.id});
  final String title;
  final List<Album>? albums;
  final String id;

  @override
  Widget build(BuildContext context) {
    final list = albums;
    if (list == null || list.isEmpty) return const SliverToBoxAdapter();
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(title),
          AlbumCarousel(albums: list, heroPrefix: 'home-$id'),
        ],
      ),
    );
  }
}

/// Mixes around the artists played most, each topped up with similar ones.
class _MadeForYou extends ConsumerWidget {
  const _MadeForYou();

  static const _width = 148.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seeds = ref.watch(mixSeedsProvider).valueOrNull;
    if (seeds == null || seeds.isEmpty) return const SliverToBoxAdapter();
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader('Made for you'),
          SizedBox(
            height: _width + 60,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter),
              itemCount: seeds.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (_, i) => _MixCard(seed: seeds[i], width: _width),
            ),
          ),
        ],
      ),
    );
  }
}

class _MixCard extends ConsumerWidget {
  const _MixCard({required this.seed, required this.width});
  final MixSeed seed;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songs = ref.watch(mixProvider(seed.artistId)).valueOrNull;
    final band = barColorFor(watchCoverColor(ref, seed.coverArt));
    final text = Theme.of(context).textTheme;
    final tag = 'home-mix-${seed.artistId}';
    return SizedBox(
      width: width,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => context.openMix(
          seed.artistId,
          preview: DetailPreview(heroTag: tag, title: mixTitle(seed), subtitle: seed.artist, coverArt: seed.coverArt),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox.square(
              dimension: width,
              child: Stack(
                children: [
                  CoverArt(coverArt: seed.coverArt, size: width, heroTag: tag, shadow: true),
                  // The cover's own colour rising from the bottom, with the artist on it.
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(SonarRadius.art),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [band.withValues(alpha: 0), band.withValues(alpha: 0.95)],
                          stops: const [0.35, 1],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 10,
                    right: 10,
                    bottom: 10,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'MIX',
                          style: text.labelSmall?.copyWith(
                            color: const Color(0xCCFFFFFF),
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.4,
                          ),
                        ),
                        Text(
                          seed.artist,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleMedium?.copyWith(
                            color: SonarColors.textPrimary,
                            fontWeight: FontWeight.w800,
                            height: 1.15,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned(top: 8, right: 8, child: PlayingBadge.mix(seed.artistId)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              songs == null ? 'Made for you' : mixSubtitle(seed, songs),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
