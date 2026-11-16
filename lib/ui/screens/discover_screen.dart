import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/discover/discover.dart';
import '../../data/subsonic/models.dart';
import '../../state/providers.dart';
import '../../state/soulbeet_providers.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import '../widgets/now_playing_bars.dart';
import 'settings_screen.dart' show formatBytes;

/// Buttons as wide as their label (the theme makes them full width).
const _inline = ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(0, 48)));

/// How long Remove waits for Undo before the song is deleted on the server.
const discoverUndoFor = Duration(seconds: 5);

/// "12 songs · 410 MB of 2 GB": how full Discover is.
String discoverFullness(Discover d) {
  final s = d.settings;
  final count = d.songs.length == 1 ? '1 song' : '${d.songs.length} songs';
  return '$count of ${s.maxSongs} · ${formatBytes(d.bytes)} of ${s.maxGb} GB';
}

/// What Discover is doing, or why it isn't adding songs.
String? discoverDoing(Discover d) {
  if (d.toppingUp) return 'Finding new songs…';
  if (d.downloading > 0) return d.downloading == 1 ? '1 song downloading' : '${d.downloading} songs downloading';
  return switch (d.note) {
    DiscoverNote.full =>
      d.settings.makeRoom
          ? 'Discover is full, and every song is from the last day. New ones come once some are older.'
          : 'Discover is full: keep or remove some songs to make room for new ones.',
    DiscoverNote.nothingFound =>
      d.lastError == null
          ? 'No new songs found this time. It looks again in a few hours.'
          : 'No new songs this time: ${d.lastError}',
    DiscoverNote.unreachable => 'Can\'t reach Sonar Connect on your server right now.',
    _ => null,
  };
}

/// Discover's undecided songs, each with Keep (into the library) and Remove
/// (deleted from the server, after a few seconds to undo).
class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  /// Songs on their way out (waiting for Undo, or being kept), by id.
  final _leaving = <String>{};

  @override
  void initState() {
    super.initState();
    // Fresh numbers each visit (a song may have arrived meanwhile).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final d = ref.read(discoverProvider);
      if (d != null && !d.toppingUp) d.refresh().catchError((Object _) {});
    });
  }

  void _snack(String text, {SnackBarAction? action}) {
    final m = ScaffoldMessenger.maybeOf(context);
    m?.hideCurrentSnackBar();
    m?.showSnackBar(SnackBar(content: Text(text), action: action, duration: discoverUndoFor));
  }

  Future<void> _keep(Discover d, Song song) async {
    setState(() => _leaving.add(song.id));
    final why = await d.keep(song);
    if (!mounted) return;
    setState(() => _leaving.remove(song.id));
    _snack(why == null ? '"${song.title}" is in your library now' : 'Couldn\'t keep it: $why');
  }

  void _remove(Discover d, Song song) {
    setState(() => _leaving.add(song.id));
    var undone = false;
    final m = ScaffoldMessenger.maybeOf(context);
    m?.hideCurrentSnackBar();
    final bar = m?.showSnackBar(
      SnackBar(
        content: Text('Removed "${song.title}"'),
        duration: discoverUndoFor,
        action: SnackBarAction(label: 'Undo', textColor: SonarColors.accentDefault, onPressed: () => undone = true),
      ),
    );
    Future<void> send() async {
      if (undone) {
        if (mounted) setState(() => _leaving.remove(song.id));
        return;
      }
      final why = await d.remove(song);
      if (!mounted) return;
      setState(() => _leaving.remove(song.id));
      if (why != null) _snack('Couldn\'t remove it: $why');
    }

    // Sent when the bar goes (timed out, swiped, or replaced by the next).
    (bar?.closed ?? Future<void>.delayed(discoverUndoFor)).then((_) => send());
  }

  @override
  Widget build(BuildContext context) {
    final d = ref.watch(discoverProvider);
    final settings = ref.watch(discoverSettingsProvider);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Discover'),
        actions: [
          if (d != null && settings.on && d.available == true)
            IconButton(
              tooltip: 'Look for new songs now',
              onPressed: d.toppingUp ? null : () => d.topUp(),
              icon: const Icon(Icons.refresh_rounded),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: _body(context, d, settings, text),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, Discover? d, DiscoverSettings settings, TextTheme text) {
    if (d == null || d.available == false) {
      return const _Explain(
        icon: Icons.explore_off_rounded,
        text:
            'Discover needs Get music and Sonar Connect on your server, with a Discover folder. Run the server '
            'installer again and choose Get music to add it.',
      );
    }
    final songs = [
      for (final s in d.songs)
        if (!_leaving.contains(s.id)) s,
    ];
    final doing = discoverDoing(d);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, 8, SonarSpacing.gutter, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Songs by artists like the ones you play, to try. Keep the ones you like; they move into your '
                  'library. Remove the rest; they\'re deleted from your server and not suggested again.',
                  style: text.bodyMedium?.copyWith(color: SonarColors.textSecondary),
                ),
                const SizedBox(height: 12),
                if (!settings.on)
                  Row(
                    children: [
                      const Expanded(child: Text('Discover is off, so no new songs are downloaded.')),
                      FilledButton(
                        style: _inline,
                        onPressed: () => ref.read(discoverSettingsProvider.notifier).set(settings.copyWith(on: true)),
                        child: const Text('Turn on'),
                      ),
                    ],
                  )
                else ...[
                  Text(discoverFullness(d), style: text.titleSmall),
                  if (doing != null) ...[
                    const SizedBox(height: 4),
                    Text(doing, style: text.bodySmall?.copyWith(color: SonarColors.textSecondary)),
                  ],
                ],
                if (songs.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        style: _inline,
                        onPressed: () => ref.read(controlsProvider).playSongs(songs),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Play'),
                      ),
                      OutlinedButton.icon(
                        style: _inline,
                        onPressed: () => ref.read(controlsProvider).playSongs(songs, shuffle: true),
                        icon: const Icon(Icons.shuffle_rounded),
                        label: const Text('Shuffle'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        if (songs.isEmpty)
          SliverToBoxAdapter(
            child: _Explain(
              icon: Icons.explore_rounded,
              text: settings.on
                  ? 'Nothing to try yet. New songs show up here as they finish downloading.'
                  : 'Turn Discover on to have new songs downloaded here.',
            ),
          )
        else
          SliverList.builder(
            itemCount: songs.length,
            itemBuilder: (_, i) => DiscoverSongTile(
              song: songs[i],
              queue: songs,
              index: i,
              onKeep: () => _keep(d, songs[i]),
              onRemove: () => _remove(d, songs[i]),
            ),
          ),
        const SliverBottomSpacer(),
      ],
    );
  }
}

class _Explain extends StatelessWidget {
  const _Explain({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(32),
    child: Column(
      children: [
        Icon(icon, size: 40, color: SonarColors.textSecondary),
        const SizedBox(height: 12),
        Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: SonarColors.textSecondary),
        ),
      ],
    ),
  );
}

/// A Discover song: tap to play the list from here, Keep or Remove.
class DiscoverSongTile extends ConsumerWidget {
  const DiscoverSongTile({
    super.key,
    required this.song,
    required this.queue,
    required this.index,
    required this.onKeep,
    required this.onRemove,
  });

  final Song song;
  final List<Song> queue;
  final int index;
  final VoidCallback onKeep;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCurrent = ref.watch(currentSongIdProvider) == song.id;
    final playing = isCurrent && (ref.watch(playingProvider).valueOrNull ?? false);
    return ListTile(
      contentPadding: const EdgeInsets.only(left: SonarSpacing.gutter, right: 4),
      leading: SizedBox.square(
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
      ),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${song.artist} · ${song.album}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: SonarColors.textSecondary),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Keep: add to your library',
            onPressed: onKeep,
            icon: const Icon(Icons.library_add_rounded, color: SonarColors.accentDefault),
          ),
          IconButton(
            tooltip: 'Remove from your server',
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline_rounded, color: SonarColors.textSecondary),
          ),
        ],
      ),
      onTap: () {
        final handler = ref.read(controlsProvider);
        if (isCurrent) {
          playing ? handler.pause() : handler.play();
        } else {
          handler.playSongs(queue, index: index);
        }
      },
    );
  }
}
