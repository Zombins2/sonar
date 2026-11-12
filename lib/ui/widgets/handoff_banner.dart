import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/handoff.dart';
import '../../state/providers.dart';
import 'common.dart';
import 'cover_art.dart';

/// "Continue from your phone": offers the queue another device left on the
/// server, at the song and second it stopped.
class HandoffBanner extends ConsumerWidget {
  const HandoffBanner({super.key, this.padding = const EdgeInsets.fromLTRB(8, 0, 8, 6)});
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offer = ref.watch(handoffProvider).valueOrNull;
    final playing = ref.watch(playingProvider).valueOrNull ?? false;
    // A device that's online is shown live (Sonar Connect) instead: this
    // card is for picking up where an offline one left off.
    final live = ref.watch(connectDevicesProvider).valueOrNull?.values.any((d) => d.hasSong) ?? false;
    final song = offer?.current;
    return AnimatedSize(
      duration: SonarMotion.normal,
      curve: SonarMotion.curve,
      child: offer == null || song == null || playing || live
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: padding,
              child: Material(
                color: SonarColors.surfaceElevated,
                borderRadius: BorderRadius.circular(SonarRadius.miniPlayer),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.devices_rounded, color: SonarColors.accentDefault, size: 20),
                      const SizedBox(width: 10),
                      CoverArt(coverArt: song.coverArt, size: 40, radius: 6),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Continue from ${deviceName(offer.changedBy)}',
                              style: const TextStyle(
                                fontFamily: SonarFonts.family,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: SonarColors.accentDefault,
                              ),
                            ),
                            Text(
                              '${song.title} · ${song.artist}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: SonarFonts.family,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: SonarColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          await ref
                              .read(audioHandlerProvider)
                              .playSongs(offer.songs, index: offer.currentIndex, position: offer.position);
                          await dismissHandoff(ref, offer);
                        },
                        child: Text('Play here · ${formatDuration(offer.position)}'),
                      ),
                      IconButton(
                        tooltip: 'Not now',
                        icon: const Icon(Icons.close_rounded, size: 20, color: SonarColors.textSecondary),
                        onPressed: () => dismissHandoff(ref, offer),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
