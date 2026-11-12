import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/player_controls.dart';
import '../../core/theme.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import '../widgets/media_tiles.dart';

/// Now playing, then songs queued by hand, then the rest of the album or
/// playlist. Drag to reorder within a section, swipe left to remove.
class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Queue')),
    body: const QueueList(),
  );
}

/// The queue's sections. The phone shows it as a page, desktop as a panel.
class QueueList extends ConsumerWidget {
  const QueueList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(queueProvider).valueOrNull ?? const [];
    final index = ref.watch(playbackStateProvider).valueOrNull?.queueIndex ?? 0;
    final source = ref.watch(playbackSourceProvider).valueOrNull;
    final handler = ref.read(controlsProvider);
    final text = Theme.of(context).textTheme;

    if (queue.isEmpty || index >= queue.length) {
      return const EmptyState(icon: Icons.queue_music_rounded, title: 'Your queue is empty');
    }

    final current = queue[index];
    final accent = buttonColorFor(watchCoverColor(ref, current.extras?['coverArt'] as String?));
    // Hand-queued songs sit in one run straight after the current track.
    var queuedEnd = index + 1;
    while (queuedEnd < queue.length && queue[queuedEnd].extras?['queued'] == true) {
      queuedEnd++;
    }
    final queuedCount = queuedEnd - index - 1;
    final restCount = queue.length - queuedEnd;

    Widget header(String label) => SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, SonarSpacing.section, SonarSpacing.gutter, 8),
        child: Text(label, style: text.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, 8, SonarSpacing.gutter, 8),
            child: Text('Now playing', style: text.titleMedium),
          ),
        ),
        SliverToBoxAdapter(
          child: MediaItemTile(item: current, highlight: accent),
        ),
        if (queuedCount > 0) ...[
          header('Next in queue'),
          _Section(queue: queue, start: index + 1, count: queuedCount, handler: handler),
        ],
        header(
          restCount == 0
              ? (queuedCount == 0 ? 'Nothing up next' : 'Nothing after your queue')
              : source != null
              ? 'Next from: ${source.title}'
              : 'Next up',
        ),
        _Section(queue: queue, start: queuedEnd, count: restCount, handler: handler),
        SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 24)),
      ],
    );
  }
}

/// A reorderable run of queue rows starting at queue index [start].
class _Section extends StatelessWidget {
  const _Section({required this.queue, required this.start, required this.count, required this.handler});
  final List<MediaItem> queue;
  final int start;
  final int count;
  final PlayerControls handler;

  @override
  Widget build(BuildContext context) => SliverReorderableList(
    itemCount: count,
    onReorder: (from, to) {
      // ReorderableList reports `to` as the slot before removal.
      final target = to > from ? to - 1 : to;
      handler.moveQueueItem(start + from, start + target);
    },
    itemBuilder: (context, i) {
      final qi = start + i;
      final item = queue[qi];
      return Dismissible(
        key: ValueKey('${item.id}-$qi-${queue.length}'),
        direction: DismissDirection.endToStart,
        background: Container(
          color: const Color(0xFF8B1E1E),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 24),
          child: const Icon(Icons.delete_outline_rounded),
        ),
        onDismissed: (_) => handler.removeQueueItemAt(qi),
        child: Material(
          color: SonarColors.background,
          child: MediaItemTile(
            item: item,
            onTap: () => handler.skipToQueueItem(qi),
            trailing: ReorderableDragStartListener(
              index: i,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.drag_handle_rounded, color: SonarColors.textSecondary),
              ),
            ),
          ),
        ),
      );
    },
  );
}
