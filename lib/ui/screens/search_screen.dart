import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../data/subsonic/models.dart';
import '../../state/providers.dart';
import '../../state/soulbeet_providers.dart';
import '../widgets/common.dart';
import '../widgets/media_tiles.dart';
import 'genre_screen.dart';
import 'get_music_screen.dart' show DownloadsButton;

/// Bumped to put the cursor in the search box (Ctrl+F on desktop).
final searchFocusRequests = ValueNotifier<int>(0);

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  String _query = '';
  int _generation = 0;
  SearchResult? _result;
  Object? _error;
  bool _loading = false;

  void _focusRequested() {
    _focus.requestFocus();
    _controller.selection = TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
  }

  @override
  void initState() {
    super.initState();
    searchFocusRequests.addListener(_focusRequested);
  }

  @override
  void dispose() {
    searchFocusRequests.removeListener(_focusRequested);
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(value));
    setState(() {});
  }

  Future<void> _search(String raw) async {
    final q = raw.trim();
    final gen = ++_generation;
    if (q.isEmpty) {
      setState(() {
        _query = '';
        _result = null;
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() {
      _query = q;
      _loading = true;
      _error = null;
    });
    try {
      final r = await ref.read(clientProvider)!.search3(q, artistCount: 8, albumCount: 12, songCount: 30);
      if (gen != _generation || !mounted) return; // A newer query already started.
      setState(() => _result = r);
    } catch (e) {
      if (gen == _generation && mounted) setState(() => _error = e);
    } finally {
      if (gen == _generation && mounted) setState(() => _loading = false);
    }
  }

  void _remember() => ref.read(recentSearchesProvider.notifier).add(_query);

  void _useRecent(String q) {
    _controller.text = q;
    _controller.selection = TextSelection.collapsed(offset: q.length);
    _search(q);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, 20, SonarSpacing.gutter, 4),
              child: Row(
                children: [
                  Expanded(child: Text('Search', style: Theme.of(context).textTheme.headlineMedium)),
                  if (ref.watch(soulbeetAvailableProvider)) ...[
                    const DownloadsButton(),
                    TextButton.icon(
                      onPressed: () => context.openGetMusic(query: _query.isEmpty ? null : _query),
                      icon: const Icon(Icons.travel_explore_rounded),
                      label: const Text('Get music'),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, 12, SonarSpacing.gutter, 8),
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                onChanged: _onChanged,
                onSubmitted: (v) {
                  _debounce?.cancel();
                  _search(v).then((_) => _remember());
                },
                textInputAction: TextInputAction.search,
                style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w500),
                cursorColor: Colors.black,
                decoration: InputDecoration(
                  fillColor: Colors.white,
                  hintText: 'Artists, albums, songs',
                  hintStyle: const TextStyle(color: Color(0xFF555555)),
                  prefixIcon: const Icon(Icons.search_rounded, color: Colors.black87),
                  suffixIcon: _controller.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded, color: Colors.black87),
                          onPressed: () {
                            _controller.clear();
                            _search('');
                          },
                        ),
                ),
              ),
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_query.isEmpty) return _RecentSearches(onPick: _useRecent);
    if (_error != null && _result == null) return ErrorState(error: _error!, onRetry: () => _search(_query));
    if (_result == null) return const LoadingState();
    final r = _result!;
    final getMusic = ref.watch(soulbeetAvailableProvider);
    if (r.isEmpty && !_loading) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: 'No results for "$_query"',
        message: getMusic ? 'It isn\'t in your library yet.' : null,
        action: getMusic
            ? FilledButton.icon(
                onPressed: () => context.openGetMusic(query: _query),
                icon: const Icon(Icons.travel_explore_rounded),
                label: Text('Get "$_query"'),
              )
            : null,
      );
    }

    final bottom = bottomInset(context);
    return NotificationListener<ScrollStartNotification>(
      onNotification: (_) {
        _focus.unfocus();
        return false;
      },
      // Tapping a result counts as a search worth remembering.
      child: Listener(
        onPointerUp: (_) => _remember(),
        child: CustomScrollView(
          slivers: [
            if (_loading) const SliverToBoxAdapter(child: LinearProgressIndicator(minHeight: 2)),
            if (r.artists.isNotEmpty) ...[
              const SliverToBoxAdapter(child: SectionHeader('Artists')),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 160,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter),
                    itemCount: r.artists.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 14),
                    itemBuilder: (_, i) => ArtistCard(artist: r.artists[i]),
                  ),
                ),
              ),
            ],
            if (r.albums.isNotEmpty) ...[
              const SliverToBoxAdapter(child: SectionHeader('Albums')),
              SliverToBoxAdapter(
                child: AlbumCarousel(albums: r.albums, heroPrefix: 'search'),
              ),
            ],
            if (r.songs.isNotEmpty) ...[
              const SliverToBoxAdapter(child: SectionHeader('Songs')),
              SliverList.builder(
                itemCount: r.songs.length,
                itemBuilder: (_, i) => SongTile(song: r.songs[i], queue: r.songs, index: i),
              ),
            ],
            if (getMusic)
              SliverToBoxAdapter(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter),
                  leading: const Icon(Icons.travel_explore_rounded),
                  title: Text('Not what you wanted? Get "$_query"'),
                  subtitle: const Text('Find it on MusicBrainz and download it'),
                  onTap: () => context.openGetMusic(query: _query),
                ),
              ),
            SliverToBoxAdapter(child: SizedBox(height: bottom)),
          ],
        ),
      ),
    );
  }
}

/// Before typing: recent searches (as quick chips) and a Browse-by-genre grid.
class _RecentSearches extends ConsumerWidget {
  const _RecentSearches({required this.onPick});
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recents = ref.watch(recentSearchesProvider);
    final genres = ref.watch(genresProvider).valueOrNull ?? const <Genre>[];
    if (recents.isEmpty && genres.isEmpty) {
      return const EmptyState(
        icon: Icons.manage_search_rounded,
        title: 'Find your music',
        message: 'Search across artists, albums and songs on your server.',
      );
    }
    return CustomScrollView(
      slivers: [
        if (recents.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: SectionHeader(
              'Recent searches',
              trailing: TextButton(
                onPressed: ref.read(recentSearchesProvider.notifier).clear,
                child: const Text('Clear', style: TextStyle(color: SonarColors.textSecondary)),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final q in recents.take(8))
                    InputChip(
                      label: Text(q),
                      avatar: const Icon(Icons.history_rounded, size: 18, color: SonarColors.textSecondary),
                      backgroundColor: SonarColors.surfaceElevated,
                      side: BorderSide.none,
                      shape: const StadiumBorder(),
                      onPressed: () => onPick(q),
                      onDeleted: () => ref.read(recentSearchesProvider.notifier).remove(q),
                      deleteIconColor: SonarColors.textSecondary,
                    ),
                ],
              ),
            ),
          ),
        ],
        if (genres.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SectionHeader('Browse genres')),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                mainAxisExtent: 96,
              ),
              itemCount: genres.length,
              itemBuilder: (context, i) {
                final color = genreColor(genres[i].name, i);
                return GenreTile(
                  genre: genres[i],
                  color: color,
                  onTap: () => context.openGenre(genres[i].name, color: color),
                );
              },
            ),
          ),
        ],
        const SliverBottomSpacer(),
      ],
    );
  }
}
