import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/playback_source.dart';
import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/discovery.dart';
import '../../data/subsonic/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import '../widgets/media_tiles.dart';
import '../widgets/song_menu.dart';
import 'collection_view.dart';
import 'edit_playlist_screen.dart';

/// Scaffold with a transparent app bar for loading / error states of detail pages.
Widget _statePage(Widget child) => Scaffold(appBar: AppBar(), body: child);

/// While the tracks load, draw the header from what the tapped card knew.
Widget _loadingPage(String id, DetailPreview preview, SourceKind kind, IconData icon) => preview.title == null
    ? _statePage(const LoadingState())
    : CollectionView(
        coverArt: preview.coverArt,
        heroTag: preview.heroTag ?? '${kind.name}-$id',
        title: preview.title!,
        byline: preview.subtitle ?? '',
        meta: '',
        songs: const [],
        source: PlaybackSource(kind, id, preview.title!),
        numbered: kind == SourceKind.album,
        placeholderIcon: icon,
        loading: true,
      );

class AlbumScreen extends ConsumerWidget {
  const AlbumScreen({super.key, required this.id, this.preview = const DetailPreview()});
  final String id;
  final DetailPreview preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final album = ref.watch(albumProvider(id));
    final starred = ref.watch(starredProvider).valueOrNull?.contains(id);
    final heroTag = preview.heroTag;
    return album.when(
      loading: () => _loadingPage(id, preview, SourceKind.album, Icons.album_rounded),
      error: (e, _) => _statePage(ErrorState(error: e, onRetry: () => ref.invalidate(albumProvider(id)))),
      data: (a) {
        final parts = [
          'Album',
          if (a.year != null && a.year! > 0) '${a.year}',
          '${a.songs.length} ${a.songs.length == 1 ? 'song' : 'songs'}',
          formatLongDuration(a.duration),
        ];
        return CollectionView(
          coverArt: a.coverArt,
          heroTag: heroTag ?? 'album-${a.id}',
          title: a.name,
          byline: a.artist,
          meta: parts.join(' · '),
          songs: a.songs,
          source: PlaybackSource(SourceKind.album, a.id, a.name),
          numbered: true,
          albumId: a.id,
          onBylineTap: a.artistId == null ? null : () => context.openArtist(a.artistId!),
          isStarred: starred ?? a.starred,
          onToggleStar: () async {
            try {
              await ref.read(starredProvider.notifier).toggleAlbum(a.id);
            } catch (e) {
              if (context.mounted) showSnack(context, errorText(e));
            }
          },
          onMore: () => showCollectionMenu(context, ref, a.songs, artistId: a.artistId),
        );
      },
    );
  }
}

class PlaylistScreen extends ConsumerWidget {
  const PlaylistScreen({super.key, required this.id, this.preview = const DetailPreview()});
  final String id;
  final DetailPreview preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlist = ref.watch(playlistProvider(id));
    final me = ref.watch(sessionProvider).valueOrNull?.username;
    return playlist.when(
      loading: () => _loadingPage(id, preview, SourceKind.playlist, Icons.queue_music_rounded),
      error: (e, _) => _statePage(ErrorState(error: e, onRetry: () => ref.invalidate(playlistProvider(id)))),
      data: (p) => CollectionView(
        coverArt: p.coverArt,
        heroTag: 'playlist-${p.id}',
        title: p.name,
        byline: p.owner ?? 'Playlist',
        meta: ['Playlist', '${p.songs.length} songs', formatLongDuration(p.duration)].join(' · '),
        songs: p.songs,
        source: PlaybackSource(SourceKind.playlist, p.id, p.name),
        placeholderIcon: Icons.queue_music_rounded,
        onMore: () => showCollectionMenu(context, ref, p.songs),
        // Navidrome only lets the owner change a playlist.
        onEdit: p.owner == null || p.owner == me
            ? () async {
                final deleted = await EditPlaylistScreen.open(context, p);
                if (deleted == true && context.mounted) Navigator.of(context).maybePop();
              }
            : null,
      ),
    );
  }
}

/// A "Made for you" mix around one artist, laid out like a playlist.
class MixScreen extends ConsumerWidget {
  const MixScreen({super.key, required this.artistId, this.preview = const DetailPreview()});
  final String artistId;
  final DetailPreview preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mix = ref.watch(mixProvider(artistId));
    final seed = ref.watch(mixSeedsProvider).valueOrNull?.where((s) => s.artistId == artistId).firstOrNull;
    final title = preview.title ?? (seed == null ? 'Your Mix' : mixTitle(seed));
    final source = PlaybackSource(SourceKind.mix, artistId, title);
    final songs = mix.valueOrNull ?? const <Song>[];
    if (mix.hasError) {
      return _statePage(ErrorState(error: mix.error!, onRetry: () => ref.invalidate(mixProvider(artistId))));
    }
    return CollectionView(
      coverArt: preview.coverArt ?? seed?.coverArt,
      heroTag: preview.heroTag ?? 'mix-$artistId',
      title: title,
      byline: seed == null ? (preview.subtitle ?? '') : mixSubtitle(seed, songs),
      meta: mix.isLoading
          ? ''
          : [
              'Made for you',
              '${songs.length} songs',
              formatLongDuration(songs.fold(Duration.zero, (t, s) => t + s.duration)),
            ].join(' · '),
      songs: songs,
      source: source,
      placeholderIcon: Icons.auto_awesome_rounded,
      loading: mix.isLoading,
      downloadable: false,
      onMore: songs.isEmpty ? null : () => showCollectionMenu(context, ref, songs),
    );
  }
}

class ArtistScreen extends ConsumerStatefulWidget {
  const ArtistScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends ConsumerState<ArtistScreen> {
  final _titleBar = ValueNotifier(0.0);
  bool _allPopular = false;

  String get id => widget.id;

  @override
  void dispose() {
    _titleBar.dispose();
    super.dispose();
  }

  Future<void> _shuffleAll(WidgetRef ref, Artist artist) async {
    final client = ref.read(clientProvider);
    if (client == null) return;
    final albums = await Future.wait(artist.albums.map((a) => client.getAlbum(a.id)));
    final songs = [for (final a in albums) ...a.songs];
    await ref
        .read(controlsProvider)
        .playSongs(songs, shuffle: true, source: PlaybackSource(SourceKind.artist, artist.id, artist.name));
  }

  @override
  Widget build(BuildContext context) {
    final artist = ref.watch(artistProvider(id));
    final starred = ref.watch(starredProvider).valueOrNull?.contains(id);
    return artist.when(
      loading: () => _statePage(const LoadingState()),
      error: (e, _) => _statePage(ErrorState(error: e, onRetry: () => ref.invalidate(artistProvider(id)))),
      data: (a) {
        final albums = [...a.albums]..sort((x, y) => (y.year ?? 0).compareTo(x.year ?? 0));
        final popular = ref.watch(topSongsProvider(a.name)).valueOrNull ?? const <Song>[];
        final shownPopular = popular.take(_allPopular ? 10 : 5).toList();
        final similar = ref.watch(artistInfoProvider(id)).valueOrNull?.similarArtists ?? const <Artist>[];
        final source = PlaybackSource(SourceKind.artist, a.id, a.name);
        final color = watchCoverColor(ref, a.coverArt);
        final width = MediaQuery.sizeOf(context).width;
        final text = Theme.of(context).textTheme;
        return Scaffold(
          extendBodyBehindAppBar: true,
          appBar: FadingTitleBar(progress: _titleBar, title: a.name, color: barColorFor(color)),
          body: NotificationListener<ScrollNotification>(
            onNotification: FadingTitleBar.tracker(_titleBar, width * 0.85 - 140),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: width * 0.85,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CoverArt(coverArt: a.coverArt, radius: 0, icon: Icons.person_rounded),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, color.withValues(alpha: 0.2), SonarColors.background],
                              stops: const [0.35, 0.7, 1],
                            ),
                          ),
                        ),
                        Positioned(
                          left: SonarSpacing.gutter,
                          right: SonarSpacing.gutter,
                          bottom: 12,
                          child: Text(
                            a.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: text.headlineMedium?.copyWith(fontSize: 38, height: 1.05),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, SonarSpacing.gutter, 0),
                    child: Row(
                      children: [
                        IconButton(
                          icon: Icon(
                            starred == true ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                            color: starred == true ? buttonColorFor(color) : SonarColors.textSecondary,
                          ),
                          onPressed: () async {
                            try {
                              await ref.read(starredProvider.notifier).toggleArtist(a.id);
                            } catch (e) {
                              if (context.mounted) showSnack(context, errorText(e));
                            }
                          },
                        ),
                        IconButton(
                          tooltip: 'Artist radio',
                          icon: const Icon(Icons.radio_rounded, color: SonarColors.textSecondary),
                          onPressed: () => playRadio(
                            ref.read(controlsProvider),
                            ref.read(clientProvider),
                            PlaybackSource(SourceKind.radio, a.id, '${a.name} Radio'),
                            (client) => artistRadio(client, a.id, a.name),
                            (m) => showSnack(context, m),
                          ),
                        ),
                        Text('${albums.length} ${albums.length == 1 ? 'album' : 'albums'}', style: text.bodyMedium),
                        const Spacer(),
                        _ShuffleButton(color: buttonColorFor(color), onPressed: () => _shuffleAll(ref, a)),
                      ],
                    ),
                  ),
                ),
                if (popular.isNotEmpty) ...[
                  const SliverToBoxAdapter(child: SectionHeader('Popular')),
                  SliverList.list(
                    children: [
                      for (var i = 0; i < shownPopular.length; i++)
                        SongTile(
                          song: shownPopular[i],
                          queue: popular,
                          index: i,
                          contextArtist: a.name,
                          source: source,
                        ),
                    ],
                  ),
                  if (popular.length > 5)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            style: TextButton.styleFrom(foregroundColor: SonarColors.textSecondary),
                            onPressed: () => setState(() => _allPopular = !_allPopular),
                            child: Text(_allPopular ? 'Show less' : 'See more'),
                          ),
                        ),
                      ),
                    ),
                ],
                const SliverToBoxAdapter(child: SectionHeader('Albums')),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter),
                  sliver: SliverGrid.builder(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 200,
                      mainAxisSpacing: 20,
                      crossAxisSpacing: 14,
                      childAspectRatio: 0.74,
                    ),
                    itemCount: albums.length,
                    itemBuilder: (_, i) => AlbumCard(
                      album: albums[i],
                      heroPrefix: 'artist-$id',
                      subtitle: albums[i].year != null && albums[i].year! > 0 ? '${albums[i].year}' : 'Album',
                    ),
                  ),
                ),
                if (similar.isNotEmpty) ...[
                  const SliverToBoxAdapter(child: SectionHeader('Fans also like')),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 156,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter),
                        itemCount: similar.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 14),
                        itemBuilder: (_, i) => ArtistCard(artist: similar[i]),
                      ),
                    ),
                  ),
                ],
                const SliverBottomSpacer(),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ShuffleButton extends StatefulWidget {
  const _ShuffleButton({required this.color, required this.onPressed});
  final Color color;
  final Future<void> Function() onPressed;

  @override
  State<_ShuffleButton> createState() => _ShuffleButtonState();
}

class _ShuffleButtonState extends State<_ShuffleButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    style: FilledButton.styleFrom(
      backgroundColor: widget.color,
      foregroundColor: onColor(widget.color),
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 22),
    ),
    onPressed: _busy
        ? null
        : () async {
            setState(() => _busy = true);
            try {
              await widget.onPressed();
            } catch (e) {
              if (context.mounted) showSnack(context, errorText(e));
            } finally {
              if (mounted) setState(() => _busy = false);
            }
          },
    icon: _busy
        ? SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: onColor(widget.color)))
        : const Icon(Icons.shuffle_rounded),
    label: const Text('Shuffle'),
  );
}
