import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../state/providers.dart';
import '../widgets/cover_art.dart';
import '../widgets/device_picker.dart';
import '../widgets/track_swipe.dart';

const nowPlayingHeroTag = 'now-playing-art';

/// The cover's flight between the mini player and Now Playing: it grows from
/// the small image already on screen into the large one, rounding its
/// corners and lifting its shadow on the way.
Widget nowPlayingFlight(
  BuildContext _,
  Animation<double> animation,
  HeroFlightDirection _,
  BuildContext _,
  BuildContext _,
) => _CoverFlight(animation, key: coverFlightKey);

/// Marks the cover while it's in flight (for tests).
const coverFlightKey = ValueKey('cover-flight');

class _CoverFlight extends ConsumerWidget {
  const _CoverFlight(this.animation, {super.key});
  final Animation<double> animation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coverArt = ref.watch(mediaItemProvider).valueOrNull?.extras?['coverArt'] as String?;
    final client = ref.watch(clientProvider);
    final override = ref.watch(coverImageOverrideProvider);
    ImageProvider? image(int size) => coverArt == null
        ? null
        : override?.call(coverArt) ?? (client == null ? null : coverImageProvider(client, coverArt, size: size));
    final small = image(300);
    final large = image(600);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value;
        final radius = BorderRadius.circular(lerpDouble(8, SonarRadius.art, t)!);
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4 * t),
                blurRadius: 24 * t,
                offset: Offset(0, 10 * t),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: ColoredBox(
              color: SonarColors.surfaceElevated,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // The large image covers the small one once it has loaded.
                  if (small != null) Image(image: small, fit: BoxFit.cover, gaplessPlayback: true),
                  if (large != null && large != small) Image(image: large, fit: BoxFit.cover, gaplessPlayback: true),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Persistent player bar above the bottom nav. Tap or swipe up for Now Playing;
/// swipe the track left / right for next / previous.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(mediaItemProvider).valueOrNull;
    final playing = ref.watch(playingProvider).valueOrNull ?? false;
    final handler = ref.read(controlsProvider);
    final remote = ref.watch(remotePlayerProvider) != null;
    // Each new track's large cover loads in the background, ready for Now Playing.
    ref.listen(
      mediaItemProvider.select((i) => i.valueOrNull?.extras?['coverArt'] as String?),
      (_, coverArt) => precacheLargeCover(context, ref, coverArt),
    );

    return AnimatedSwitcher(
      duration: SonarMotion.normal,
      switchInCurve: SonarMotion.curve,
      transitionBuilder: (child, a) => SizeTransition(sizeFactor: a, axisAlignment: 1, child: child),
      child: item == null
          ? const SizedBox(width: double.infinity)
          : Builder(
              builder: (context) {
                final coverArt = item.extras?['coverArt'] as String?;
                final tint = watchCoverColor(ref, coverArt);
                final bg = barColorFor(tint);
                return Padding(
                  key: const ValueKey('mini'),
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                  child: GestureDetector(
                    onTap: () {
                      precacheLargeCover(context, ref, coverArt);
                      context.openNowPlaying();
                    },
                    onVerticalDragEnd: (d) {
                      if ((d.primaryVelocity ?? 0) >= -200) return;
                      precacheLargeCover(context, ref, coverArt);
                      context.openNowPlaying();
                    },
                    child: AnimatedContainer(
                      duration: SonarMotion.normal,
                      curve: SonarMotion.curve,
                      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(SonarRadius.miniPlayer)),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: TrackSwipe(
                                    onNext: handler.skipToNext,
                                    onPrevious: handler.skipToPreviousTrack,
                                    child: Row(
                                      children: [
                                        CoverArt(
                                          coverArt: coverArt,
                                          size: 42,
                                          radius: 8,
                                          heroTag: nowPlayingHeroTag,
                                          flight: nowPlayingFlight,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                item.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: SonarColors.textPrimary,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 14,
                                                ),
                                              ),
                                              if (remote)
                                                const PlayingOnLine(fontSize: 12)
                                              else
                                                Text(
                                                  item.artist ?? '',
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 13),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const DeviceButton(),
                                IconButton(
                                  iconSize: 32,
                                  tooltip: playing ? 'Pause' : 'Play',
                                  icon: AnimatedSwitcher(
                                    duration: SonarMotion.fast,
                                    transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                                    child: Icon(
                                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                      key: ValueKey(playing),
                                      color: SonarColors.textPrimary,
                                    ),
                                  ),
                                  onPressed: () {
                                    HapticFeedback.lightImpact();
                                    playing ? handler.pause() : handler.play();
                                  },
                                ),
                              ],
                            ),
                          ),
                          const _ProgressLine(),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _ProgressLine extends ConsumerWidget {
  const _ProgressLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fraction = ref.watch(positionProvider).valueOrNull?.fraction ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: fraction,
          minHeight: 2,
          backgroundColor: const Color(0x33FFFFFF),
          color: SonarColors.textPrimary,
        ),
      ),
    );
  }
}
