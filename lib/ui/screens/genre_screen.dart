import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/subsonic/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import '../widgets/media_tiles.dart';

const _genrePalette = [
  Color(0xFFE13300),
  Color(0xFF1E3264),
  Color(0xFF8D67AB),
  Color(0xFF148A08),
  Color(0xFFBA5D07),
  Color(0xFF0D73EC),
  Color(0xFFE8115B),
  Color(0xFF477D95),
  Color(0xFF8C1932),
  Color(0xFF537AA1),
  Color(0xFF7358FF),
  Color(0xFF27856A),
  Color(0xFFAF2896),
  Color(0xFF503750),
  Color(0xFFD84000),
];

/// Browse-grid colours go by position so neighbours never match; the genre
/// page is handed the same colour. Pages opened any other way hash the name.
Color genreColor(String name, [int? index]) {
  if (index != null) return _genrePalette[index % _genrePalette.length];
  var h = 0;
  for (final c in name.toLowerCase().codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _genrePalette[h % _genrePalette.length];
}

/// Coloured tile for the Browse grid.
class GenreTile extends StatelessWidget {
  const GenreTile({super.key, required this.genre, required this.color, required this.onTap});
  final Genre genre;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            // A tilted slab in the corner, like a record sleeve peeking out.
            Positioned(
              right: -14,
              bottom: -10,
              child: Transform.rotate(
                angle: 0.42,
                child: Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: Color.lerp(color, Colors.black, 0.35),
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 8, offset: Offset(-2, 2))],
                  ),
                  child: const Icon(Icons.album_rounded, color: Color(0x66FFFFFF), size: 34),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                genre.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: SonarColors.textPrimary,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  height: 1.15,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// All albums in one genre, with a shuffle across its songs.
class GenreScreen extends ConsumerStatefulWidget {
  const GenreScreen({super.key, required this.name, this.color});
  final String name;
  final Color? color;

  @override
  ConsumerState<GenreScreen> createState() => _GenreScreenState();
}

class _GenreScreenState extends ConsumerState<GenreScreen> {
  final _titleBar = ValueNotifier(0.0);
  bool _shuffling = false;

  String get name => widget.name; // go_router hands path parameters over decoded.

  @override
  void dispose() {
    _titleBar.dispose();
    super.dispose();
  }

  Future<void> _shuffle() async {
    HapticFeedback.lightImpact();
    setState(() => _shuffling = true);
    try {
      final songs = await requireClientOf(ref).getRandomSongs(genre: name, size: 100);
      if (songs.isEmpty) {
        if (mounted) showSnack(context, 'No songs found in $name');
        return;
      }
      await ref.read(controlsProvider).playSongs(songs);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _shuffling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final albums = ref.watch(genreAlbumsProvider(name));
    final color = widget.color ?? genreColor(name);
    final text = Theme.of(context).textTheme;
    final count = albums.valueOrNull?.length;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: FadingTitleBar(progress: _titleBar, title: name, color: Color.lerp(color, Colors.black, 0.5)!),
      body: NotificationListener<ScrollNotification>(
        onNotification: FadingTitleBar.tracker(_titleBar, 90),
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [color, color.withValues(alpha: 0.3), SonarColors.background],
                    stops: const [0, 0.65, 1],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, 64, SonarSpacing.gutter, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: text.headlineMedium?.copyWith(fontSize: 40, height: 1.05)),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                count == null ? '' : '$count ${count == 1 ? 'album' : 'albums'}',
                                style: text.bodyMedium?.copyWith(color: const Color(0xCCFFFFFF)),
                              ),
                            ),
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: buttonColorFor(color),
                                foregroundColor: onColor(buttonColorFor(color)),
                                minimumSize: const Size(0, 48),
                                padding: const EdgeInsets.symmetric(horizontal: 22),
                              ),
                              onPressed: _shuffling ? null : _shuffle,
                              icon: _shuffling
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.shuffle_rounded),
                              label: const Text('Shuffle'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            ...albums.when(
              loading: () => [
                const SliverToBoxAdapter(
                  child: Padding(padding: EdgeInsets.all(48), child: LoadingState()),
                ),
              ],
              error: (e, _) => [
                SliverToBoxAdapter(
                  child: ErrorState(error: e, onRetry: () => ref.invalidate(genreAlbumsProvider(name))),
                ),
              ],
              data: (list) => [
                if (list.isEmpty)
                  const SliverToBoxAdapter(
                    child: EmptyState(icon: Icons.album_rounded, title: 'No albums in this genre'),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter),
                    sliver: SliverGrid.builder(
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 200,
                        mainAxisSpacing: 20,
                        crossAxisSpacing: 14,
                        childAspectRatio: 0.74,
                      ),
                      itemCount: list.length,
                      itemBuilder: (_, i) => AlbumCard(album: list[i], heroPrefix: 'genre-$name'),
                    ),
                  ),
              ],
            ),
            const SliverBottomSpacer(),
          ],
        ),
      ),
    );
  }
}
