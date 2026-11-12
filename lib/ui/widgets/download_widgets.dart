import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/subsonic/models.dart';
import '../../downloads/download_manager.dart';
import '../../state/providers.dart';
import 'common.dart';

/// Download / progress / downloaded toggle for an album, playlist or song.
class DownloadButton extends ConsumerWidget {
  const DownloadButton({
    super.key,
    required this.kind,
    required this.sourceId,
    required this.title,
    required this.subtitle,
    required this.coverArt,
    required this.songs,
    required this.accent,
  });

  final String kind;
  final String sourceId;
  final String title;
  final String subtitle;
  final String? coverArt;
  final List<Song> songs;
  final Color accent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dm = ref.watch(downloadManagerProvider);
    final saved = dm.collection(kind, sourceId) != null;
    final (:done, :active) = dm.progressOf(songs);
    final complete = saved && done >= 1;
    final failed = saved && !active && !complete;

    final Widget icon;
    final String tooltip;
    if (!saved) {
      icon = const Icon(Icons.download_for_offline_outlined, color: SonarColors.textSecondary);
      tooltip = 'Download';
    } else if (complete) {
      icon = Icon(Icons.download_for_offline_rounded, color: accent);
      tooltip = 'Downloaded';
    } else if (failed) {
      icon = const Icon(Icons.sync_problem_rounded, color: Color(0xFFFFB35C));
      tooltip = 'Some downloads failed — tap to retry';
    } else {
      icon = SizedBox.square(
        dimension: 22,
        child: CircularProgressIndicator(
          value: done.clamp(0.04, 1.0),
          strokeWidth: 2.5,
          color: accent,
          backgroundColor: const Color(0x33FFFFFF),
        ),
      );
      tooltip = 'Downloading ${(done * 100).round()}%';
    }

    return IconButton(
      tooltip: tooltip,
      icon: AnimatedSwitcher(
        duration: SonarMotion.fast,
        child: KeyedSubtree(key: ValueKey(tooltip), child: icon),
      ),
      onPressed: () async {
        if (!saved) {
          final client = ref.read(clientProvider);
          if (client == null) return;
          if (!ref.read(reachableProvider)) {
            showSnack(context, 'Server unreachable. Reconnect to download.');
            return;
          }
          await dm.downloadCollection(
            kind: kind,
            sourceId: sourceId,
            title: title,
            subtitle: subtitle,
            coverArt: coverArt,
            songs: songs,
          );
          if (context.mounted) {
            final cellular = ref.read(settingsProvider).downloadOnCellular;
            showSnack(context, cellular ? 'Downloading…' : 'Downloading on Wi-Fi…');
          }
        } else if (failed) {
          await dm.retry(songs);
        } else if (await _confirmRemove(context, title, active)) {
          await dm.removeCollection(kind, sourceId);
        }
      },
    );
  }
}

Future<bool> _confirmRemove(BuildContext context, String title, bool inProgress) async =>
    await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: SonarColors.surfaceElevated,
        title: Text(inProgress ? 'Cancel download?' : 'Remove download?'),
        content: Text('"$title" will no longer be available offline.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(d).pop(false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.of(d).pop(true), child: const Text('Remove')),
        ],
      ),
    ) ??
    false;

/// Tiny status mark next to a track's duration.
class SongDownloadMark extends ConsumerWidget {
  const SongDownloadMark(this.songId, {super.key});
  final String songId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(downloadManagerProvider.select((m) => m.statusOf(songId)));
    return switch (d?.status) {
      DownloadStatus.done => const Padding(
        padding: EdgeInsets.only(right: 6),
        child: Icon(Icons.arrow_circle_down_rounded, size: 15, color: SonarColors.accentDefault),
      ),
      DownloadStatus.queued => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: SizedBox.square(
          dimension: 12,
          child: CircularProgressIndicator(
            value: d!.progress > 0 ? d.progress : null,
            strokeWidth: 1.8,
            color: SonarColors.textSecondary,
          ),
        ),
      ),
      DownloadStatus.failed => const Padding(
        padding: EdgeInsets.only(right: 6),
        child: Icon(Icons.error_outline_rounded, size: 15, color: Color(0xFFFFB35C)),
      ),
      null => const SizedBox.shrink(),
    };
  }
}
