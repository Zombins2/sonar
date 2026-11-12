import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/playback_source.dart';
import '../../state/providers.dart';

/// Three equaliser bars: bouncing while audio plays, resting when paused.
class NowPlayingBars extends StatefulWidget {
  const NowPlayingBars({super.key, required this.color, required this.animate, this.size = 16});
  final Color color;
  final bool animate;
  final double size;

  @override
  State<NowPlayingBars> createState() => _NowPlayingBarsState();
}

class _NowPlayingBarsState extends State<NowPlayingBars> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void initState() {
    super.initState();
    if (widget.animate) _controller.repeat();
  }

  @override
  void didUpdateWidget(NowPlayingBars old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.animate && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: _controller,
      builder: (_, _) => CustomPaint(
        size: Size.square(widget.size),
        painter: _BarsPainter(widget.color, _controller.value, widget.animate),
      ),
    ),
  );
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.color, this.t, this.animate);
  final Color color;
  final double t;
  final bool animate;

  // Each bar runs at its own speed and phase so the motion never looks synced.
  static const _speeds = [1.0, 2.0, 1.0];
  static const _phases = [0.0, 0.8, 2.1];
  static const _resting = [0.45, 0.8, 0.3];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final gap = size.width * 0.14;
    final barWidth = (size.width - gap * 2) / 3;
    for (var i = 0; i < 3; i++) {
      final level = animate ? 0.25 + 0.75 * (0.5 + 0.5 * sin(2 * pi * t * _speeds[i] + _phases[i])) : _resting[i];
      final h = size.height * level;
      final x = i * (barWidth + gap);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, size.height - h, barWidth, h), Radius.circular(barWidth / 2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.t != t || old.animate != animate || old.color != color;
}

/// Small pill shown on cover art when that album / playlist is what's playing.
class PlayingBadge extends ConsumerWidget {
  const PlayingBadge.album(this.id, {super.key}) : kind = SourceKind.album;
  const PlayingBadge.playlist(this.id, {super.key}) : kind = SourceKind.playlist;
  const PlayingBadge.mix(this.id, {super.key}) : kind = SourceKind.mix;

  final SourceKind kind;
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(playbackSourceProvider).valueOrNull;
    // An album also counts when its track is playing from somewhere else
    // (search, artist shuffle), since the art is the same.
    final active = switch (kind) {
      SourceKind.album => ref.watch(currentAlbumIdProvider) == id,
      _ => source == PlaybackSource(kind, id, ''),
    };
    final playing = ref.watch(playingProvider).valueOrNull ?? false;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: !active
          ? const SizedBox.shrink()
          : Container(
              key: const ValueKey('badge'),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(8)),
              child: NowPlayingBars(color: Colors.white, animate: playing, size: 14),
            ),
    );
  }
}
