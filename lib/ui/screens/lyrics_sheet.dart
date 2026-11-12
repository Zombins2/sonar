import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/subsonic/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';

/// Lyrics for whatever is playing; follows along when the track changes.
Future<void> showLyrics(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  showDragHandle: false, // The sheet draws its own on the cover colour.
  backgroundColor: Colors.transparent,
  builder: (_) => const FractionallySizedBox(heightFactor: 0.9, child: _LyricsSheet()),
);

class _LyricsSheet extends ConsumerWidget {
  const _LyricsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(mediaItemProvider).valueOrNull;
    final tint = watchCoverColor(ref, item?.extras?['coverArt'] as String?);
    final bg = Color.lerp(tint, Colors.black, 0.35)!;

    return AnimatedContainer(
      duration: SonarMotion.normal,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 36,
            height: 4,
            decoration: BoxDecoration(color: const Color(0x66FFFFFF), borderRadius: BorderRadius.circular(2)),
          ),
          const Expanded(child: LyricsPanel()),
        ],
      ),
    );
  }
}

/// The current song's title over its lyrics. Used by the phone's sheet and
/// as a panel on the desktop layout.
class LyricsPanel extends ConsumerWidget {
  const LyricsPanel({super.key, this.showTitle = true, this.lineSize = 24});

  /// Off where the song is already named right next to the lyrics.
  final bool showTitle;

  /// Smaller in the desktop's narrow side panel, so lines don't all wrap.
  final double lineSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(mediaItemProvider).valueOrNull;
    final lyrics = ref.watch(currentLyricsProvider);
    return Column(
      children: [
        if (showTitle)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 24, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item?.title ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: SonarColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        item?.artist ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: switch (lyrics) {
            AsyncData(value: final Lyrics l) => _LyricsView(key: ValueKey(item?.id), lyrics: l, lineSize: lineSize),
            AsyncData() ||
            AsyncError() => const EmptyState(icon: Icons.lyrics_outlined, title: 'No lyrics for this song'),
            _ => const LoadingState(),
          },
        ),
      ],
    );
  }
}

/// Synced lyrics light up and follow the song; tap a line to jump there.
/// Plain lyrics just scroll.
class _LyricsView extends ConsumerStatefulWidget {
  const _LyricsView({super.key, required this.lyrics, required this.lineSize});
  final Lyrics lyrics;
  final double lineSize;

  @override
  ConsumerState<_LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<_LyricsView> {
  final _currentKey = GlobalKey();
  int _lastIndex = -1;

  /// Auto-follow pauses for a moment after the user scrolls by hand.
  DateTime _userScrolledAt = DateTime(2000);

  int _indexFor(Duration position) {
    var idx = -1;
    for (var i = 0; i < widget.lyrics.lines.length; i++) {
      final start = widget.lyrics.lines[i].start;
      if (start != null && start <= position) idx = i;
    }
    return idx;
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = widget.lyrics;
    final lines = lyrics.lines;
    final current = lyrics.synced ? _indexFor(ref.watch(positionProvider).valueOrNull?.position ?? Duration.zero) : -1;
    if (current != _lastIndex) {
      _lastIndex = current;
      if (DateTime.now().difference(_userScrolledAt) > const Duration(seconds: 3)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = _currentKey.currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(ctx, alignment: 0.3, duration: SonarMotion.normal, curve: SonarMotion.curve);
          }
        });
      }
    }

    // A Column (not a lazy list) so the current line always has a context to
    // scroll to, even after a big seek. Lyrics are short enough for that.
    return NotificationListener<UserScrollNotification>(
      onNotification: (n) {
        if (n.direction != ScrollDirection.idle) _userScrolledAt = DateTime.now();
        return false;
      },
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < lines.length; i++) _line(i, current),
            if (lyrics.credit != null)
              Padding(
                padding: const EdgeInsets.only(top: 32),
                child: Text(
                  'Lyrics from ${lyrics.credit}',
                  style: const TextStyle(fontSize: 12, color: Color(0x99FFFFFF)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _line(int i, int current) {
    final line = widget.lyrics.lines[i];
    final synced = widget.lyrics.synced;
    final active = i == current;
    final past = synced && i < current;
    final color = !synced || active
        ? SonarColors.textPrimary
        : past
        ? const Color(0x99FFFFFF)
        : const Color(0x4DFFFFFF);
    return GestureDetector(
      key: active ? _currentKey : null,
      behavior: HitTestBehavior.opaque,
      onTap: line.start == null
          ? null
          : () {
              _userScrolledAt = DateTime(2000); // Follow again straight away.
              ref.read(controlsProvider).seek(line.start!);
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: AnimatedDefaultTextStyle(
          duration: SonarMotion.fast,
          // Built on the theme so it keeps the app's font family.
          style: Theme.of(context).textTheme.headlineSmall!.copyWith(
            fontSize: widget.lineSize,
            height: 1.3,
            fontWeight: FontWeight.w800,
            color: color,
          ),
          // Instrumental gap. An icon, since Figtree has no ♪ glyph.
          child: line.text.isEmpty
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: Icon(Icons.music_note_rounded, size: widget.lineSize + 4, color: color),
                )
              : Text(line.text),
        ),
      ),
    );
  }
}
