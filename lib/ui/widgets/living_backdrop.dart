import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/theme.dart';

/// Now Playing's background: the cover's colours as soft glows that drift
/// while music plays, slow almost to a stop on pause, and blend across to the
/// next cover's colours when the track changes.
class LivingBackdrop extends StatefulWidget {
  const LivingBackdrop({super.key, required this.colors, required this.playing, required this.child});

  /// Four glow colours (see `glowColors`).
  final List<Color> colors;
  final bool playing;
  final Widget child;

  @override
  State<LivingBackdrop> createState() => _LivingBackdropState();
}

class _LivingBackdropState extends State<LivingBackdrop> with TickerProviderStateMixin {
  /// Drift time in seconds; runs slower while paused.
  final _time = ValueNotifier<double>(0);
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;
  double _speed = 0;

  late final _blend = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  late List<Color> _from = widget.colors;
  late List<Color> _to = widget.colors;

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    // Ease the drift speed toward its target so play / pause never jerks.
    final target = widget.playing ? 1.0 : 0.12;
    _speed += (target - _speed) * min(1, dt * 1.5);
    _time.value += dt * _speed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.disableAnimationsOf(context);
    if (still && _ticker.isActive) _ticker.stop();
    if (!still && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  @override
  void didUpdateWidget(LivingBackdrop old) {
    super.didUpdateWidget(old);
    if (!_sameColors(old.colors, widget.colors)) {
      _from = _lerpColors(_from, _to, _blend.value);
      _to = widget.colors;
      _blend.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _blend.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      RepaintBoundary(
        child: CustomPaint(
          painter: _GlowPainter(
            time: _time,
            colors: () => _lerpColors(_from, _to, Curves.easeInOut.transform(_blend.value)),
            repaint: Listenable.merge([_time, _blend]),
          ),
        ),
      ),
      widget.child,
    ],
  );
}

bool _sameColors(List<Color> a, List<Color> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<Color> _lerpColors(List<Color> a, List<Color> b, double t) => [
  for (var i = 0; i < b.length; i++) Color.lerp(a[i % a.length], b[i], t)!,
];

/// Where each glow wanders: its home (fractions of the screen), how far it
/// strays, how fast (radians per second) and how big it is.
class _Glow {
  const _Glow(this.x, this.y, this.dx, this.dy, this.sx, this.sy, this.phase, this.size);
  final double x, y, dx, dy, sx, sy, phase, size;
}

const _glows = [
  _Glow(0.25, 0.22, 0.30, 0.16, 0.21, 0.17, 0.0, 0.75),
  _Glow(0.80, 0.30, 0.26, 0.20, 0.16, 0.23, 1.9, 0.65),
  _Glow(0.45, 0.55, 0.34, 0.16, 0.13, 0.19, 3.7, 0.70),
  _Glow(0.70, 0.08, 0.22, 0.12, 0.24, 0.12, 5.1, 0.55),
];

class _GlowPainter extends CustomPainter {
  _GlowPainter({required this.time, required this.colors, required super.repaint});

  final ValueNotifier<double> time;
  final List<Color> Function() colors;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final c = colors();
    final t = time.value;
    canvas.drawRect(rect, Paint()..color = Color.lerp(c[0], SonarColors.background, 0.6)!);
    final reach = size.longestSide;
    for (var i = 0; i < _glows.length; i++) {
      final g = _glows[i];
      final center = Offset(
        size.width * (g.x + g.dx * sin(t * g.sx + g.phase)),
        size.height * (g.y + g.dy * cos(t * g.sy + g.phase * 1.3)),
      );
      // Each glow also swells and shrinks a little on its own beat.
      final radius = reach * g.size * (1 + 0.08 * sin(t * 0.4 + g.phase));
      final color = c[i % c.length];
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [color.withValues(alpha: 0.85), color.withValues(alpha: 0.35), color.withValues(alpha: 0)],
            stops: const [0, 0.45, 1],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
    // Settle into the app background behind the controls, for legible text.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            SonarColors.background.withValues(alpha: 0.15),
            SonarColors.background.withValues(alpha: 0.1),
            SonarColors.background.withValues(alpha: 0.6),
            SonarColors.background.withValues(alpha: 0.92),
          ],
          stops: const [0, 0.4, 0.72, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.time != time || old.colors != colors;
}
