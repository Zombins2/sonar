import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../../audio/audio_handler.dart';
import '../../core/nav.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../state/providers.dart';
import '../shell/mini_player.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import '../widgets/device_picker.dart';
import '../widgets/living_backdrop.dart';
import '../widgets/song_menu.dart';
import '../widgets/track_swipe.dart';
import 'lyrics_sheet.dart';
import 'queue_screen.dart';

/// Short format note for the player, e.g. "FLAC", "MP3 · 320 kbps", or the
/// transcoded rate when a quality cap is in force. Null when nothing is known.
String? qualityLabel({String? suffix, int? bitRate, int streamKbps = 0}) {
  if (streamKbps > 0) return 'MP3 · $streamKbps kbps';
  if (suffix == null || suffix.isEmpty) return null;
  final format = suffix.toUpperCase();
  const lossless = {'flac', 'alac', 'wav', 'aif', 'aiff', 'ape', 'wv', 'dsf'};
  if (lossless.contains(suffix.toLowerCase())) return '$format · Lossless';
  return bitRate == null || bitRate <= 0 ? format : '$format · $bitRate kbps';
}

class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  double _drag = 0;

  void _onDragEnd(DragEndDetails d) {
    if (_drag > 140 || (d.primaryVelocity ?? 0) > 700) {
      context.pop();
    } else {
      setState(() => _drag = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = ref.watch(mediaItemProvider).valueOrNull;
    if (item == null) {
      // Queue was cleared while open (e.g. logout).
      return Scaffold(
        appBar: AppBar(leading: const CloseButton()),
        body: const EmptyState(icon: Icons.music_off_rounded, title: 'Nothing playing'),
      );
    }

    final coverArt = item.extras?['coverArt'] as String?;
    final glow = coverArt == null
        ? CoverColors.fallback.glow
        : (ref.watch(coverColorsProvider(coverArt)).valueOrNull ?? CoverColors.fallback).glow;
    final handler = ref.read(controlsProvider);
    final playing = ref.watch(playingProvider).valueOrNull ?? false;
    final size = MediaQuery.sizeOf(context);
    final artSize = (size.width - 48).clamp(200.0, size.height * 0.42);

    if (isWideLayout(context)) {
      return Scaffold(
        backgroundColor: SonarColors.background,
        body: LivingBackdrop(
          colors: glow,
          playing: playing,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 12, 32, 24),
              child: Column(
                children: [
                  _TopBar(item: item),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          flex: 5,
                          child: _WideCoverAndControls(item: item, coverArt: coverArt, playing: playing),
                        ),
                        const SizedBox(width: 40),
                        const Expanded(flex: 4, child: _WideSide()),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onVerticalDragUpdate: (d) => setState(() => _drag = (_drag + d.delta.dy).clamp(0, double.infinity)),
      onVerticalDragEnd: _onDragEnd,
      child: AnimatedContainer(
        duration: _drag == 0 ? SonarMotion.fast : Duration.zero,
        curve: SonarMotion.curve,
        transform: Matrix4.translationValues(0, _drag, 0),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: LivingBackdrop(
            colors: glow,
            playing: playing,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    _TopBar(item: item),
                    const Spacer(),
                    // Swipe the art to change track; it eases back a little while paused.
                    TrackSwipe(
                      onNext: handler.skipToNext,
                      onPrevious: handler.skipToPreviousTrack,
                      child: Center(
                        child: AnimatedScale(
                          scale: playing ? 1 : 0.86,
                          duration: const Duration(milliseconds: 450),
                          curve: playing ? Curves.easeOutBack : Curves.easeOutCubic,
                          child: CoverArt(
                            coverArt: coverArt,
                            size: artSize,
                            heroTag: nowPlayingHeroTag,
                            flight: nowPlayingFlight,
                            shadow: true,
                          ),
                        ),
                      ),
                    ),
                    const Spacer(),
                    _TitleRow(item: item),
                    const SizedBox(height: 12),
                    const _Scrubber(),
                    const SizedBox(height: 4),
                    const _Controls(),
                    const Center(child: PlayingOnLine()),
                    const SizedBox(height: 12),
                    _BottomRow(songId: item.id),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Wide windows: the cover as large as fits, the controls under it.
class _WideCoverAndControls extends StatelessWidget {
  const _WideCoverAndControls({required this.item, required this.coverArt, required this.playing});
  final MediaItem item;
  final String? coverArt;
  final bool playing;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      // Room for the title, seek bar and buttons (about 220 px) under the art.
      // The sleep timer sits in the top bar here.
      final art = (c.maxHeight - 230).clamp(200.0, (c.maxWidth * 0.9).clamp(200.0, 620.0));
      return Center(
        child: SizedBox(
          width: art,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                scale: playing ? 1 : 0.92,
                duration: const Duration(milliseconds: 450),
                curve: playing ? Curves.easeOutBack : Curves.easeOutCubic,
                child: CoverArt(
                  coverArt: coverArt,
                  size: art,
                  heroTag: nowPlayingHeroTag,
                  flight: nowPlayingFlight,
                  shadow: true,
                ),
              ),
              const SizedBox(height: 28),
              _TitleRow(item: item),
              const SizedBox(height: 12),
              const _Scrubber(),
              const SizedBox(height: 4),
              const _Controls(),
              const SizedBox(height: 8),
              const PlayingOnLine(),
            ],
          ),
        ),
      );
    },
  );
}

/// Wide windows: lyrics (when the song has them) or what's up next, beside the cover.
class _WideSide extends ConsumerStatefulWidget {
  const _WideSide();

  @override
  ConsumerState<_WideSide> createState() => _WideSideState();
}

class _WideSideState extends ConsumerState<_WideSide> {
  /// Null follows the song: lyrics if it has any, otherwise the queue.
  bool? _showLyrics;

  @override
  Widget build(BuildContext context) {
    final hasLyrics = ref.watch(currentLyricsProvider).valueOrNull != null;
    final lyrics = (_showLyrics ?? hasLyrics) && hasLyrics;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: true, label: const Text('Lyrics'), enabled: hasLyrics),
              const ButtonSegment(value: false, label: Text('Up next')),
            ],
            selected: {lyrics},
            onSelectionChanged: (s) => setState(() => _showLyrics = s.first),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(SonarRadius.card),
              child: ColoredBox(
                color: const Color(0x33000000),
                child: lyrics ? const LyricsPanel(showTitle: false) : const QueueList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final song = ref.read(controlsProvider).currentSong;
    final source = ref.watch(playbackSourceProvider).valueOrNull;
    final albumId = item.extras?['albumId'] as String?;
    // Queues started from search or the song list have no source: fall back to the track's album.
    final label = source?.label ?? 'PLAYING FROM ALBUM';
    final name = source?.title ?? item.album ?? '';
    final path = source?.path ?? (albumId == null ? null : 'album/$albumId');
    final router = GoRouter.of(context);
    // Wide: the title stays centred whichever buttons are on the right
    // (devices, sleep timer, menu); the left holds the close arrow.
    final remote = ref.watch(remotePlayerProvider) != null;
    final rightButtons = 1 + (ref.watch(connectLinkProvider) != null ? 1 : 0) + (remote ? 0 : 1);
    return Row(
      children: [
        IconButton(icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32), onPressed: () => context.pop()),
        if (isWideLayout(context)) SizedBox(width: 48.0 * (rightButtons - 1)),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: path == null ? null : () => openInShell(router, (b) => '/$b/$path'),
            child: Column(
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.2,
                    color: Color(0xCCFFFFFF),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: SonarColors.textPrimary, fontWeight: FontWeight.w700, fontSize: 14),
                ),
              ],
            ),
          ),
        ),
        if (isWideLayout(context)) ...[const DeviceButton(), const _SleepButton()],
        IconButton(
          icon: const Icon(Icons.more_vert_rounded),
          onPressed: song == null ? null : () => showSongMenu(context, song),
        ),
      ],
    );
  }
}

class _TitleRow extends ConsumerWidget {
  const _TitleRow({required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final starred = ref.watch(starredProvider).valueOrNull?.contains(item.id) ?? false;
    final artistId = item.extras?['artistId'] as String?;
    final router = GoRouter.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 22),
              ),
              const SizedBox(height: 2),
              GestureDetector(
                onTap: artistId == null ? null : () => openInShell(router, (b) => '/$b/artist/$artistId'),
                child: Text(
                  item.artist ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, color: Color(0xCCFFFFFF)),
                ),
              ),
            ],
          ),
        ),
        IconButton(
          iconSize: 28,
          icon: AnimatedSwitcher(
            duration: SonarMotion.fast,
            transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
            child: Icon(
              starred ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              key: ValueKey(starred),
              color: starred ? SonarColors.accentDefault : SonarColors.textPrimary,
            ),
          ),
          onPressed: () async {
            try {
              await ref.read(starredProvider.notifier).toggleSong(item.id);
            } catch (e) {
              if (context.mounted) showSnack(context, errorText(e));
            }
          },
        ),
      ],
    );
  }
}

class _Scrubber extends ConsumerStatefulWidget {
  const _Scrubber();

  @override
  ConsumerState<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends ConsumerState<_Scrubber> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(positionProvider).valueOrNull ?? const PositionData(Duration.zero, Duration.zero);
    final total = data.duration.inMilliseconds.toDouble();
    final value = (_dragValue ?? data.position.inMilliseconds.toDouble()).clamp(0.0, total <= 0 ? 1.0 : total);
    final shown = Duration(milliseconds: value.round());
    final remaining = data.duration - shown;
    const style = TextStyle(fontSize: 12, color: Color(0xB3FFFFFF), fontFeatures: [FontFeature.tabularFigures()]);

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(
            context,
          ).copyWith(trackShape: const RoundedRectSliderTrackShape(), padding: EdgeInsets.zero),
          child: Slider(
            value: value,
            max: total <= 0 ? 1 : total,
            onChanged: total <= 0 ? null : (v) => setState(() => _dragValue = v),
            onChangeEnd: (v) {
              ref.read(controlsProvider).seek(Duration(milliseconds: v.round()));
              setState(() => _dragValue = null);
            },
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(formatDuration(shown), style: style),
            const Expanded(child: Center(child: _QualityBadge())),
            Text('-${formatDuration(remaining.isNegative ? Duration.zero : remaining)}', style: style),
          ],
        ),
      ],
    );
  }
}

/// Small pill with the track's format; a tick when it plays from the phone.
class _QualityBadge extends ConsumerWidget {
  const _QualityBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(mediaItemProvider).valueOrNull;
    final extras = item?.extras ?? const {};
    final label = qualityLabel(
      suffix: extras['suffix'] as String?,
      bitRate: extras['bitRate'] as int?,
      streamKbps: (extras['streamKbps'] as int?) ?? 0,
    );
    final downloaded = item != null && ref.watch(downloadManagerProvider.select((m) => m.isDownloaded(item.id)));
    if (label == null) return const SizedBox.shrink();
    return AnimatedSwitcher(
      duration: SonarMotion.fast,
      child: Container(
        key: ValueKey('$label$downloaded'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0x55FFFFFF)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (downloaded) ...[
              const Icon(Icons.download_done_rounded, size: 12, color: Color(0xCCFFFFFF)),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: const TextStyle(
                fontSize: 10.5,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w700,
                color: Color(0xCCFFFFFF),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Controls extends ConsumerWidget {
  const _Controls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.read(controlsProvider);
    final playing = ref.watch(playingProvider).valueOrNull ?? false;
    final state = ref.watch(playbackStateProvider).valueOrNull;
    final shuffled = state?.shuffleMode == AudioServiceShuffleMode.all;
    final loop = ref.watch(loopModeProvider).valueOrNull ?? LoopMode.off;
    final buffering =
        state?.processingState == AudioProcessingState.loading ||
        state?.processingState == AudioProcessingState.buffering;

    Color toggle(bool on) => on ? SonarColors.accentDefault : SonarColors.textPrimary;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          tooltip: 'Shuffle',
          icon: Icon(Icons.shuffle_rounded, color: toggle(shuffled)),
          onPressed: handler.toggleShuffle,
        ),
        IconButton(iconSize: 40, icon: const Icon(Icons.skip_previous_rounded), onPressed: handler.skipToPrevious),
        SizedBox.square(
          dimension: 72,
          child: Stack(
            alignment: Alignment.center,
            children: [
              PlayButton(
                color: SonarColors.textPrimary,
                size: 68,
                playing: playing,
                onPressed: playing ? handler.pause : handler.play,
              ),
              if (buffering && playing)
                const SizedBox.square(
                  dimension: 72,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0x88FFFFFF)),
                ),
            ],
          ),
        ),
        IconButton(iconSize: 40, icon: const Icon(Icons.skip_next_rounded), onPressed: handler.skipToNext),
        IconButton(
          tooltip: switch (loop) {
            LoopMode.off => 'Repeat off',
            LoopMode.all => 'Repeat all',
            LoopMode.one => 'Repeat one',
          },
          icon: Icon(
            loop == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
            color: toggle(loop != LoopMode.off),
          ),
          onPressed: handler.cycleRepeat,
        ),
      ],
    );
  }
}

class _BottomRow extends ConsumerWidget {
  const _BottomRow({required this.songId});
  final String songId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyrics = ref.watch(currentLyricsProvider).valueOrNull;
    return Row(
      children: [
        AnimatedOpacity(
          opacity: lyrics == null ? 0 : 1,
          duration: SonarMotion.fast,
          child: IconButton(
            tooltip: lyrics?.synced == true ? 'Lyrics (synced)' : 'Lyrics',
            icon: Icon(lyrics?.synced == true ? Icons.lyrics_rounded : Icons.lyrics_outlined),
            onPressed: lyrics == null ? null : () => showLyrics(context),
          ),
        ),
        const Spacer(),
        const _SleepButton(),
        const Spacer(),
        const DeviceButton(size: 24),
        IconButton(tooltip: 'Queue', icon: const Icon(Icons.queue_music_rounded), onPressed: context.openQueue),
      ],
    );
  }
}

/// Moon button: shows the time left once a sleep timer is set.
class _SleepButton extends ConsumerStatefulWidget {
  const _SleepButton();

  @override
  ConsumerState<_SleepButton> createState() => _SleepButtonState();
}

class _SleepButtonState extends ConsumerState<_SleepButton> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (ref.read(audioHandlerProvider).sleep.value?.endsAt != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // It would stop this device, not the one being controlled.
    if (ref.watch(remotePlayerProvider) != null) return const SizedBox.shrink();
    final handler = ref.read(audioHandlerProvider);
    return ValueListenableBuilder<SleepTimer?>(
      valueListenable: handler.sleep,
      builder: (context, timer, _) {
        final String? label;
        if (timer == null) {
          label = null;
        } else if (timer.endOfTrack) {
          label = 'End of track';
        } else {
          final left = timer.endsAt!.difference(DateTime.now());
          label = formatDuration(left.isNegative ? Duration.zero : left);
        }
        final active = timer != null;
        return TextButton.icon(
          onPressed: () => _showSleepSheet(context, handler),
          style: TextButton.styleFrom(foregroundColor: active ? SonarColors.accentDefault : SonarColors.textPrimary),
          icon: Icon(active ? Icons.bedtime_rounded : Icons.bedtime_outlined, size: 22),
          label: Text(label ?? '', style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
        );
      },
    );
  }
}

Future<void> _showSleepSheet(BuildContext context, SonarAudioHandler handler) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  builder: (sheet) {
    void pick(VoidCallback action, String message) {
      action();
      Navigator.of(sheet).pop();
      showSnack(context, message);
    }

    Widget option(String label, Duration d) => ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      title: Text(label),
      onTap: () => pick(() => handler.setSleepTimer(d), 'Sleep timer set for $label'),
    );

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('Sleep timer', style: Theme.of(sheet).textTheme.titleLarge),
            ),
            option('5 minutes', const Duration(minutes: 5)),
            option('15 minutes', const Duration(minutes: 15)),
            option('30 minutes', const Duration(minutes: 30)),
            option('45 minutes', const Duration(minutes: 45)),
            option('1 hour', const Duration(hours: 1)),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              title: const Text('End of current track'),
              onTap: () => pick(handler.sleepAtEndOfTrack, 'Stopping after this track'),
            ),
            if (handler.sleep.value != null)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: const Icon(Icons.close_rounded),
                title: const Text('Turn off timer'),
                onTap: () => pick(() => handler.setSleepTimer(null), 'Sleep timer off'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  },
);
