import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../data/subsonic/subsonic_client.dart';

String formatDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes.remainder(60), s = d.inSeconds.remainder(60);
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

String formatLongDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes.remainder(60);
  if (h > 0) return '$h hr $m min';
  return '${d.inMinutes} min';
}

String errorText(Object e) => e is SubsonicException ? e.message : 'Something went wrong.';

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, SonarSpacing.section, SonarSpacing.gutter, 12),
    child: Row(
      children: [
        Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
        ?trailing,
      ],
    ),
  );
}

/// Height of the mini player + nav bar floating over the tab pages, measured
/// by the app shell. Pages outside the shell (Settings, Queue) see none.
class BottomChrome extends InheritedNotifier<ValueNotifier<double>> {
  const BottomChrome({super.key, required ValueNotifier<double> height, required super.child})
    : super(notifier: height);

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BottomChrome>()?.notifier?.value ?? 0;
}

/// Space a scrolling page needs at its end so the last item clears whatever
/// floats over the bottom: the player bar and tabs, or just the gesture bar.
double bottomInset(BuildContext context) {
  final chrome = BottomChrome.of(context);
  final system = MediaQuery.paddingOf(context).bottom;
  return (chrome > system ? chrome : system) + 24;
}

/// Clears the mini player + nav bar that float over scroll content.
class SliverBottomSpacer extends StatelessWidget {
  const SliverBottomSpacer({super.key});

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(child: SizedBox(height: bottomInset(context)));
}

/// Reports its child's height after each layout that changes it.
class MeasureHeight extends SingleChildRenderObjectWidget {
  const MeasureHeight({super.key, required this.onHeight, required super.child});
  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMeasureHeight(onHeight);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderMeasureHeight).onHeight = onHeight;
}

class _RenderMeasureHeight extends RenderProxyBox {
  _RenderMeasureHeight(this.onHeight);
  ValueChanged<double> onHeight;
  double? _last;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (h == _last) return;
    _last = h;
    // Listeners rebuild, which can't happen mid-layout.
    WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(h));
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: SonarColors.textSecondary),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(message!, style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
          ],
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    ),
  );
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: Icons.cloud_off_rounded,
    title: errorText(error),
    action: OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
  );
}

class LoadingState extends StatelessWidget {
  const LoadingState({super.key});

  @override
  Widget build(BuildContext context) =>
      const Center(child: SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.5)));
}

/// Large round play button in the current accent colour.
class PlayButton extends StatelessWidget {
  const PlayButton({super.key, required this.color, required this.onPressed, this.size = 56, this.playing = false});
  final Color color;
  final VoidCallback? onPressed;
  final double size;
  final bool playing;

  @override
  Widget build(BuildContext context) {
    final fg = ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : Colors.black;
    return Material(
      color: color,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed == null
            ? null
            : () {
                HapticFeedback.lightImpact();
                onPressed!();
              },
        child: SizedBox.square(
          dimension: size,
          child: AnimatedSwitcher(
            duration: SonarMotion.fast,
            transitionBuilder: (c, a) => ScaleTransition(
              scale: a,
              child: FadeTransition(opacity: a, child: c),
            ),
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              key: ValueKey(playing),
              color: fg,
              size: size * 0.55,
            ),
          ),
        ),
      ),
    );
  }
}

/// App bar for pages with a big header: see-through over the header, then
/// fades to a solid [color] bar carrying [title] once the header scrolls away.
class FadingTitleBar extends StatelessWidget implements PreferredSizeWidget {
  const FadingTitleBar({super.key, required this.progress, required this.title, required this.color, this.actions});
  final ValueListenable<double> progress;
  final String title;
  final Color color;
  final List<Widget>? actions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  /// Feeds [progress] from a scroll view: 0 until [start] px, 1 after [span] more.
  static bool Function(ScrollNotification) tracker(ValueNotifier<double> progress, double start, {double span = 48}) =>
      (n) {
        if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
          progress.value = ((n.metrics.pixels - start) / span).clamp(0.0, 1.0);
        }
        return false;
      };

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: progress,
    builder: (context, t, _) => AppBar(
      backgroundColor: color.withValues(alpha: t),
      title: Opacity(
        opacity: t,
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      actions: actions,
    ),
  );
}

/// Grey placeholder rows shown while a track list loads.
class SkeletonRows extends StatelessWidget {
  const SkeletonRows({super.key, this.count = 8, this.art = false});
  final int count;
  final bool art;

  @override
  Widget build(BuildContext context) {
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(color: SonarColors.surfaceElevated, borderRadius: BorderRadius.circular(4)),
    );
    return Column(
      children: [
        for (var i = 0; i < count; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: SonarSpacing.gutter, vertical: 12),
            child: Row(
              children: [
                if (art) ...[
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: SonarColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      bar(120.0 + (i * 37) % 90, 12),
                      const SizedBox(height: 8),
                      bar(70.0 + (i * 23) % 50, 10),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
}
