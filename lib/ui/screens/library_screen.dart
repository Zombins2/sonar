import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/nav.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/subsonic/models.dart';
import '../../downloads/download_manager.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import '../widgets/media_tiles.dart';

enum LibrarySort {
  recent('Recently added', AlbumListType.newest),
  alpha('A–Z', AlbumListType.alphabeticalByName),
  artist('Artist', AlbumListType.alphabeticalByArtist);

  const LibrarySort(this.label, this.albumType);
  final String label;
  final AlbumListType albumType;
}

final librarySortProvider = StateProvider<LibrarySort>((_) => LibrarySort.recent);
final libraryGridProvider = StateProvider<bool>((_) => true);

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sort = ref.watch(librarySortProvider);
    final grid = ref.watch(libraryGridProvider);
    // No Downloads tab on desktop, which plays straight from the server.
    final downloads = !isDesktopPlatform;
    return DefaultTabController(
      length: downloads ? 5 : 4,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 72,
          title: Text('Library', style: Theme.of(context).textTheme.headlineMedium),
          actions: [
            PopupMenuButton<LibrarySort>(
              tooltip: 'Sort',
              icon: const Icon(Icons.sort_rounded),
              color: SonarColors.surfaceElevated,
              initialValue: sort,
              onSelected: (s) => ref.read(librarySortProvider.notifier).state = s,
              itemBuilder: (_) => [
                for (final s in LibrarySort.values)
                  CheckedPopupMenuItem(value: s, checked: s == sort, child: Text(s.label)),
              ],
            ),
            IconButton(
              tooltip: grid ? 'List view' : 'Grid view',
              icon: Icon(grid ? Icons.view_list_rounded : Icons.grid_view_rounded),
              onPressed: () => ref.read(libraryGridProvider.notifier).state = !grid,
            ),
            const SizedBox(width: 4),
          ],
          bottom: TabBar(
            isScrollable: true,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            tabs: [
              const Tab(text: 'Playlists'),
              const Tab(text: 'Albums'),
              const Tab(text: 'Artists'),
              const Tab(text: 'Songs'),
              if (downloads) const Tab(text: 'Downloads'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            const _PlaylistsTab(),
            _AlbumsTab(key: ValueKey(sort), sort: sort),
            const _ArtistsTab(),
            const _SongsTab(),
            if (downloads) const _DownloadsTab(),
          ],
        ),
      ),
    );
  }
}

EdgeInsets _listPadding(BuildContext context) => EdgeInsets.only(top: 8, bottom: bottomInset(context));

SliverGridDelegate get _gridDelegate => const SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 200,
  mainAxisSpacing: 20,
  crossAxisSpacing: 14,
  childAspectRatio: 0.74,
);

class _PlaylistsTab extends ConsumerWidget {
  const _PlaylistsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grid = ref.watch(libraryGridProvider);
    final sort = ref.watch(librarySortProvider);
    return ref
        .watch(playlistsProvider)
        .when(
          loading: () => const LoadingState(),
          error: (e, _) => ErrorState(error: e, onRetry: () => ref.invalidate(playlistsProvider)),
          data: (all) {
            if (all.isEmpty) {
              return const EmptyState(icon: Icons.queue_music_rounded, title: 'No playlists yet');
            }
            final list = [...all];
            switch (sort) {
              case LibrarySort.recent:
                list.sort((a, b) => (b.changed ?? DateTime(0)).compareTo(a.changed ?? DateTime(0)));
              case LibrarySort.alpha:
                list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
              case LibrarySort.artist:
                list.sort((a, b) => (a.owner ?? '').compareTo(b.owner ?? ''));
            }
            return RefreshIndicator(
              onRefresh: () => ref.refresh(playlistsProvider.future),
              child: grid
                  ? GridView.builder(
                      padding: _listPadding(context).add(const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter)),
                      gridDelegate: _gridDelegate,
                      itemCount: list.length,
                      itemBuilder: (_, i) => PlaylistCard(playlist: list[i]),
                    )
                  : ListView.builder(
                      padding: _listPadding(context),
                      itemCount: list.length,
                      itemBuilder: (_, i) => PlaylistListTile(playlist: list[i]),
                    ),
            );
          },
        );
  }
}

class _ArtistsTab extends ConsumerWidget {
  const _ArtistsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grid = ref.watch(libraryGridProvider);
    return ref
        .watch(artistsProvider)
        .when(
          loading: () => const LoadingState(),
          error: (e, _) => ErrorState(error: e, onRetry: () => ref.invalidate(artistsProvider)),
          data: (artists) {
            if (artists.isEmpty) return const EmptyState(icon: Icons.person_rounded, title: 'No artists');
            return RefreshIndicator(
              onRefresh: () => ref.refresh(artistsProvider.future),
              child: grid
                  ? GridView.builder(
                      padding: _listPadding(context).add(const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter)),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 160,
                        mainAxisSpacing: 20,
                        crossAxisSpacing: 14,
                        childAspectRatio: 0.8,
                      ),
                      itemCount: artists.length,
                      itemBuilder: (_, i) => LayoutBuilder(
                        builder: (_, c) => ArtistCard(artist: artists[i], width: c.maxWidth),
                      ),
                    )
                  : ListView.builder(
                      padding: _listPadding(context),
                      itemCount: artists.length,
                      itemBuilder: (_, i) => ArtistListTile(artist: artists[i]),
                    ),
            );
          },
        );
  }
}

/// Infinite-scrolling list fed by an offset-based loader.
abstract class _PagedState<W extends ConsumerStatefulWidget, T> extends ConsumerState<W> {
  static const pageSize = 60;
  final items = <T>[];
  Object? error;
  bool loading = false;
  bool done = false;

  Future<List<T>> fetch(int offset);

  @override
  void initState() {
    super.initState();
    loadMore();
  }

  Future<void> loadMore() async {
    if (loading || done) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = await fetch(items.length);
      if (!mounted) return;
      setState(() {
        items.addAll(page);
        done = page.length < pageSize;
      });
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> reload() async {
    setState(() {
      items.clear();
      done = false;
    });
    await loadMore();
  }

  bool onScroll(ScrollNotification n) {
    if (n.metrics.extentAfter < 600) loadMore();
    return false;
  }

  Widget buildPaged(BuildContext context, {required Widget Function() builder, required Widget empty}) {
    if (items.isEmpty && error != null) return ErrorState(error: error!, onRetry: reload);
    if (items.isEmpty && loading) return const LoadingState();
    if (items.isEmpty && done) return empty;
    return RefreshIndicator(
      onRefresh: reload,
      child: NotificationListener<ScrollNotification>(onNotification: onScroll, child: builder()),
    );
  }
}

class _AlbumsTab extends ConsumerStatefulWidget {
  const _AlbumsTab({super.key, required this.sort});
  final LibrarySort sort;

  @override
  ConsumerState<_AlbumsTab> createState() => _AlbumsTabState();
}

class _AlbumsTabState extends _PagedState<_AlbumsTab, Album> {
  @override
  Future<List<Album>> fetch(int offset) =>
      requireClientOf(ref).getAlbumList2(widget.sort.albumType, size: _PagedState.pageSize, offset: offset);

  @override
  Widget build(BuildContext context) {
    final grid = ref.watch(libraryGridProvider);
    return buildPaged(
      context,
      empty: const EmptyState(icon: Icons.album_rounded, title: 'No albums'),
      builder: () => grid
          ? GridView.builder(
              padding: _listPadding(context).add(const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter)),
              gridDelegate: _gridDelegate,
              itemCount: items.length,
              itemBuilder: (_, i) => AlbumCard(album: items[i], heroPrefix: 'lib'),
            )
          : ListView.builder(
              padding: _listPadding(context),
              itemCount: items.length,
              itemBuilder: (_, i) => AlbumListTile(album: items[i], heroPrefix: 'lib-list'),
            ),
    );
  }
}

class _SongsTab extends ConsumerStatefulWidget {
  const _SongsTab();

  @override
  ConsumerState<_SongsTab> createState() => _SongsTabState();
}

class _SongsTabState extends _PagedState<_SongsTab, Song> {
  // Navidrome returns every song for an empty search3 query, paged by offset.
  @override
  Future<List<Song>> fetch(int offset) async => (await requireClientOf(
    ref,
  ).search3('', artistCount: 0, albumCount: 0, songCount: _PagedState.pageSize, songOffset: offset)).songs;

  @override
  Widget build(BuildContext context) => buildPaged(
    context,
    empty: const EmptyState(icon: Icons.music_note_rounded, title: 'No songs'),
    builder: () => ListView.builder(
      padding: _listPadding(context),
      itemCount: items.length,
      itemBuilder: (_, i) => SongTile(song: items[i], queue: items, index: i),
    ),
  );
}

final _downloadBytesProvider = FutureProvider.autoDispose<int>((ref) {
  final dm = ref.watch(downloadManagerProvider);
  return dm.totalBytes();
});

/// Everything saved for offline play, newest first.
class _DownloadsTab extends ConsumerWidget {
  const _DownloadsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dm = ref.watch(downloadManagerProvider);
    final collections = dm.collections;
    if (collections.isEmpty) {
      return const EmptyState(
        icon: Icons.download_for_offline_outlined,
        title: 'No downloads yet',
        message: 'Tap the download button on an album or playlist to keep it on your phone for offline play.',
      );
    }
    final bytes = ref.watch(_downloadBytesProvider).valueOrNull;
    final allSongs = {
      for (final c in collections)
        for (final s in c.songs)
          if (dm.isDownloaded(s.id)) s.id: s,
    }.values.toList();
    final text = Theme.of(context).textTheme;

    return ListView(
      padding: _listPadding(context),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, 8, SonarSpacing.gutter, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${allSongs.length} songs${bytes == null ? '' : ' · ${_formatBytes(bytes)}'}',
                  style: text.bodyMedium,
                ),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                ),
                onPressed: allSongs.isEmpty
                    ? null
                    : () => ref.read(controlsProvider).playSongs(allSongs, shuffle: true),
                icon: const Icon(Icons.shuffle_rounded, size: 20),
                label: const Text('Shuffle'),
              ),
            ],
          ),
        ),
        for (final c in collections) _DownloadRow(collection: c),
      ],
    );
  }
}

class _DownloadRow extends ConsumerWidget {
  const _DownloadRow({required this.collection});
  final DownloadedCollection collection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dm = ref.watch(downloadManagerProvider);
    final (:done, :active) = dm.progressOf(collection.songs);
    final kindLabel = switch (collection.kind) {
      'album' => 'Album',
      'playlist' => 'Playlist',
      _ => 'Song',
    };
    final status = done >= 1
        ? '$kindLabel · ${collection.subtitle}'
        : active
        ? 'Downloading ${(done * 100).round()}%'
        : 'Some songs failed — open to retry';
    return InkWell(
      onTap: () => switch (collection.kind) {
        'album' => context.openAlbum(collection.sourceId),
        'playlist' => context.openPlaylist(collection.sourceId),
        _ => ref.read(controlsProvider).playSongs(collection.songs),
      },
      onLongPress: () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            backgroundColor: SonarColors.surfaceElevated,
            title: const Text('Remove download?'),
            content: Text('"${collection.title}" will no longer be available offline.'),
            actions: [
              TextButton(onPressed: () => Navigator.of(d).pop(false), child: const Text('Keep')),
              TextButton(onPressed: () => Navigator.of(d).pop(true), child: const Text('Remove')),
            ],
          ),
        );
        if (ok != true) return;
        await dm.removeCollection(collection.kind, collection.sourceId);
        if (context.mounted) showSnack(context, 'Removed "${collection.title}"');
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter, vertical: 6),
        child: Row(
          children: [
            CoverArt(
              coverArt: collection.coverArt,
              size: 56,
              radius: 8,
              icon: collection.kind == 'playlist' ? Icons.queue_music_rounded : Icons.album_rounded,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    collection.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (active) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: done, minHeight: 2, borderRadius: BorderRadius.circular(2)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              done >= 1 ? Icons.download_for_offline_rounded : Icons.downloading_rounded,
              color: done >= 1 ? SonarColors.accentDefault : SonarColors.textSecondary,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

String _formatBytes(int b) {
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(0)} MB';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
