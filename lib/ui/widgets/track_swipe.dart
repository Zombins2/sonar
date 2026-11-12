import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';

/// Drag sideways to change track: left for the next one, right for the
/// previous one. The content follows the finger; past the threshold it slides
/// out and the new track slides in from the other side, otherwise it springs back.
class TrackSwipe extends StatefulWidget {
  const TrackSwipe({super.key, required this.onNext, required this.onPrevious, required this.child});
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final Widget child;

  /// Fraction of the width a slow drag has to cover to count.
  static const threshold = 0.3;

  @override
  State<TrackSwipe> createState() => _TrackSwipeState();
}

class _TrackSwipeState extends State<TrackSwipe> with SingleTickerProviderStateMixin {
  late final _offset = AnimationController.unbounded(vsync: this);
  double _width = 300;

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  Future<void> _end(DragEndDetails d) async {
    final x = _offset.value;
    final v = d.primaryVelocity ?? 0;
    final flung = v.abs() > 700 && v.sign == x.sign;
    if (x != 0 && (x.abs() > _width * TrackSwipe.threshold || flung)) {
      final dir = x.sign;
      HapticFeedback.selectionClick();
      dir < 0 ? widget.onNext() : widget.onPrevious();
      await _offset.animateTo(dir * _width, duration: SonarMotion.fast, curve: Curves.easeIn);
      if (!mounted) return;
      _offset.value = -dir * _width * 0.4;
    }
    await _offset.animateTo(0, duration: SonarMotion.normal, curve: SonarMotion.curve);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.hasBoundedWidth && constraints.maxWidth > 0) _width = constraints.maxWidth;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => _offset.stop(),
        onHorizontalDragUpdate: (d) => _offset.value += d.delta.dx,
        onHorizontalDragEnd: _end,
        onHorizontalDragCancel: () => _offset.animateTo(0, duration: SonarMotion.normal, curve: SonarMotion.curve),
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _offset,
            builder: (context, child) => Transform.translate(
              offset: Offset(_offset.value, 0),
              child: Opacity(opacity: (1 - _offset.value.abs() / _width).clamp(0.0, 1.0), child: child),
            ),
            child: widget.child,
          ),
        ),
      );
    },
  );
}
