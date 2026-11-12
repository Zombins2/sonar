import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/nav.dart';
import '../../core/theme.dart';
import '../../state/providers.dart';
import '../../state/soulbeet_providers.dart';
import '../screens/lyrics_sheet.dart';
import '../screens/queue_screen.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import '../widgets/device_picker.dart';
import '../widgets/handoff_banner.dart';
import '../widgets/song_menu.dart';
import 'mini_player.dart';

enum DesktopPanel { queue, lyrics }

/// The side panel open next to the page on the desktop layout, if any.
final desktopPanelProvider = StateProvider<DesktopPanel?>((_) => null);

/// The desktop layout: sidebar, the page, an optional queue or lyrics panel,
/// and the full player bar along the bottom.
class DesktopShell extends ConsumerWidget {
  const DesktopShell({super.key, required this.shell, required this.banner});
  final StatefulNavigationShell shell;

  /// The offline banner, shown over the page while the server is unreachable.
  final Widget banner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panel = ref.watch(desktopPanelProvider);
    Widget card(Widget child) => ClipRRect(
      borderRadius: BorderRadius.circular(SonarRadius.art),
      child: ColoredBox(color: SonarColors.background, child: child),
    );
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 248, child: card(_Sidebar(shell: shell))),
                  const SizedBox(width: 8),
                  Expanded(
                    child: card(
                      Column(
                        children: [
                          banner,
                          Expanded(
                            child: MediaQuery.removePadding(context: context, removeTop: true, child: shell),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (panel != null) ...[
                    const SizedBox(width: 8),
                    SizedBox(width: 360, child: card(_SidePanel(panel: panel))),
                  ],
                ],
              ),
            ),
          ),
          const HandoffBanner(padding: EdgeInsets.fromLTRB(8, 8, 8, 0)),
          const DesktopPlayerBar(),
        ],
      ),
    );
  }
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider).valueOrNull ?? const [];
    final text = Theme.of(context).textTheme;
    final location = GoRouter.of(context).state.matchedLocation;
    final inSettings = isSettingsLocation(location);
    final inGetMusic = isGetMusicLocation(location);
    final getMusic = ref.watch(soulbeetAvailableProvider);
    final downloading = ref.watch(soulbeetDownloadsProvider)?.activeCount ?? 0;
    Widget nav(int i, IconData icon, IconData selected, String label) {
      final current = shell.currentIndex == i;
      final on = current && !inSettings && !inGetMusic;
      return _SideItem(
        icon: on ? selected : icon,
        label: label,
        selected: on,
        // Clicking the open section again returns it to its first page.
        onTap: () => shell.goBranch(i, initialLocation: current),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Row(
            children: [
              const Icon(Icons.graphic_eq_rounded, color: SonarColors.accentDefault, size: 28),
              const SizedBox(width: 10),
              Text('Sonar', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
            ],
          ),
        ),
        nav(0, Icons.home_outlined, Icons.home_rounded, 'Home'),
        nav(1, Icons.search_rounded, Icons.manage_search_rounded, 'Search'),
        nav(2, Icons.library_music_outlined, Icons.library_music_rounded, 'Library'),
        if (getMusic)
          _SideItem(
            leading: Badge(
              isLabelVisible: downloading > 0,
              label: Text('$downloading'),
              backgroundColor: SonarColors.accentDefault,
              textColor: Colors.black,
              child: Icon(
                inGetMusic ? Icons.travel_explore_rounded : Icons.travel_explore_outlined,
                color: inGetMusic ? SonarColors.textPrimary : SonarColors.textSecondary,
              ),
            ),
            label: 'Get music',
            selected: inGetMusic,
            onTap: () {
              if (!inGetMusic) context.openGetMusic();
            },
          ),
        const Padding(padding: EdgeInsets.fromLTRB(20, 20, 20, 8), child: Divider(height: 1)),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text('Playlists', style: text.titleSmall?.copyWith(color: SonarColors.textSecondary)),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: playlists.length,
            itemBuilder: (context, i) {
              final p = playlists[i];
              return _SideItem(
                leading: CoverArt(coverArt: p.coverArt, size: 32, radius: 4, icon: Icons.queue_music_rounded),
                label: p.name,
                dense: true,
                onTap: () => context.openPlaylist(p.id, preview: p),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _SideItem(
            icon: inSettings ? Icons.settings_rounded : Icons.settings_outlined,
            label: 'Settings',
            selected: inSettings,
            onTap: context.openSettings,
          ),
        ),
      ],
    );
  }
}

class _SideItem extends StatelessWidget {
  const _SideItem({
    this.icon,
    this.leading,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.dense = false,
  });
  final IconData? icon;
  final Widget? leading;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool dense;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(horizontal: dense ? 0 : 8, vertical: 1),
    child: Material(
      color: selected ? SonarColors.surfaceElevated : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: dense ? 6 : 10),
          child: Row(
            children: [
              leading ?? Icon(icon, color: selected ? SonarColors.textPrimary : SonarColors.textSecondary),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: SonarFonts.family,
                    fontSize: dense ? 14 : 15,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    color: selected || dense ? SonarColors.textPrimary : SonarColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SidePanel extends ConsumerWidget {
  const _SidePanel({required this.panel});
  final DesktopPanel panel;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                panel == DesktopPanel.queue ? 'Queue' : 'Lyrics',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close_rounded),
              onPressed: () => ref.read(desktopPanelProvider.notifier).state = null,
            ),
          ],
        ),
      ),
      Expanded(child: panel == DesktopPanel.queue ? const QueueList() : const LyricsPanel(lineSize: 19)),
    ],
  );
}

/// Desktop's player: what's playing on the left, the transport and seek bar
/// in the middle, panels and volume on the right.
class DesktopPlayerBar extends ConsumerWidget {
  const DesktopPlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(mediaItemProvider).valueOrNull;
    // The large cover loads ahead, ready for Now Playing.
    ref.listen(
      mediaItemProvider.select((i) => i.valueOrNull?.extras?['coverArt'] as String?),
      (_, coverArt) => precacheLargeCover(context, ref, coverArt),
    );
    return SizedBox(
      height: 88,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(flex: 3, child: item == null ? const SizedBox() : _NowPlayingInfo(item: item)),
            Expanded(flex: 4, child: item == null ? const SizedBox() : const _Transport()),
            Expanded(flex: 3, child: _BarActions(enabled: item != null)),
          ],
        ),
      ),
    );
  }
}

class _NowPlayingInfo extends ConsumerWidget {
  const _NowPlayingInfo({required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coverArt = item.extras?['coverArt'] as String?;
    final artistId = item.extras?['artistId'] as String?;
    final albumId = item.extras?['albumId'] as String?;
    final starred = ref.watch(starredProvider).valueOrNull?.contains(item.id) ?? false;
    final router = GoRouter.of(context);
    return Row(
      children: [
        Tooltip(
          message: 'Now Playing',
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () {
              precacheLargeCover(context, ref, coverArt);
              context.openNowPlaying();
            },
            child: CoverArt(
              coverArt: coverArt,
              size: 56,
              radius: 6,
              heroTag: nowPlayingHeroTag,
              flight: nowPlayingFlight,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Link(
                text: item.title,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: SonarColors.textPrimary),
                onTap: albumId == null ? null : () => openInShell(router, (b) => '/$b/album/$albumId'),
              ),
              const SizedBox(height: 2),
              if (ref.watch(remotePlayerProvider) != null)
                const PlayingOnLine(fontSize: 12)
              else
                _Link(
                  text: item.artist ?? '',
                  style: const TextStyle(fontSize: 13, color: SonarColors.textSecondary),
                  onTap: artistId == null ? null : () => openInShell(router, (b) => '/$b/artist/$artistId'),
                ),
            ],
          ),
        ),
        IconButton(
          tooltip: starred ? 'Remove from favorites' : 'Favorite',
          icon: Icon(
            starred ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            color: starred ? SonarColors.accentDefault : SonarColors.textSecondary,
            size: 20,
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

/// Text that underlines on hover, like a link, when it goes somewhere.
class _Link extends StatefulWidget {
  const _Link({required this.text, required this.style, this.onTap});
  final String text;
  final TextStyle style;
  final VoidCallback? onTap;

  @override
  State<_Link> createState() => _LinkState();
}

class _LinkState extends State<_Link> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      onTap: widget.onTap,
      child: Text(
        widget.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: widget.style.copyWith(
          fontFamily: SonarFonts.family,
          decoration: _hover && widget.onTap != null ? TextDecoration.underline : null,
        ),
      ),
    ),
  );
}

class _Transport extends ConsumerStatefulWidget {
  const _Transport();

  @override
  ConsumerState<_Transport> createState() => _TransportState();
}

class _TransportState extends ConsumerState<_Transport> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final handler = ref.read(controlsProvider);
    final playing = ref.watch(playingProvider).valueOrNull ?? false;
    final state = ref.watch(playbackStateProvider).valueOrNull;
    final shuffled = state?.shuffleMode == AudioServiceShuffleMode.all;
    final loop = ref.watch(loopModeProvider).valueOrNull ?? LoopMode.off;
    final data = ref.watch(positionProvider).valueOrNull ?? const PositionData(Duration.zero, Duration.zero);
    final total = data.duration.inMilliseconds.toDouble();
    final value = (_dragging ?? data.position.inMilliseconds.toDouble()).clamp(0.0, total <= 0 ? 1.0 : total);
    const time = TextStyle(
      fontFamily: SonarFonts.family,
      fontSize: 11,
      color: SonarColors.textSecondary,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    Color toggle(bool on) => on ? SonarColors.accentDefault : SonarColors.textSecondary;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: 'Shuffle (Ctrl+S)',
              iconSize: 20,
              icon: Icon(Icons.shuffle_rounded, color: toggle(shuffled)),
              onPressed: handler.toggleShuffle,
            ),
            IconButton(
              tooltip: 'Previous (Ctrl+Left)',
              icon: const Icon(Icons.skip_previous_rounded),
              onPressed: handler.skipToPrevious,
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: playing ? 'Pause (Space)' : 'Play (Space)',
              child: SizedBox.square(
                dimension: 40,
                child: Material(
                  color: SonarColors.textPrimary,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: playing ? handler.pause : handler.play,
                    child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.black),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Next (Ctrl+Right)',
              icon: const Icon(Icons.skip_next_rounded),
              onPressed: handler.skipToNext,
            ),
            IconButton(
              tooltip: 'Repeat (Ctrl+R)',
              iconSize: 20,
              icon: Icon(
                loop == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                color: toggle(loop != LoopMode.off),
              ),
              onPressed: handler.cycleRepeat,
            ),
          ],
        ),
        Row(
          children: [
            SizedBox(
              width: 44,
              child: Text(
                formatDuration(Duration(milliseconds: value.round())),
                style: time,
                textAlign: TextAlign.right,
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                  activeTrackColor: SonarColors.textPrimary,
                  inactiveTrackColor: const Color(0x33FFFFFF),
                  thumbColor: SonarColors.textPrimary,
                ),
                child: Slider(
                  value: value,
                  max: total <= 0 ? 1 : total,
                  onChanged: total <= 0 ? null : (v) => setState(() => _dragging = v),
                  onChangeEnd: (v) {
                    handler.seek(Duration(milliseconds: v.round()));
                    setState(() => _dragging = null);
                  },
                ),
              ),
            ),
            SizedBox(width: 44, child: Text(formatDuration(data.duration), style: time)),
          ],
        ),
      ],
    );
  }
}

class _BarActions extends ConsumerWidget {
  const _BarActions({required this.enabled});
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panel = ref.watch(desktopPanelProvider);
    final hasLyrics = ref.watch(currentLyricsProvider).valueOrNull != null;
    void toggle(DesktopPanel p) => ref.read(desktopPanelProvider.notifier).state = panel == p ? null : p;
    Color tint(bool on) => on ? SonarColors.accentDefault : SonarColors.textSecondary;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        const DeviceButton(size: 20),
        IconButton(
          tooltip: 'Lyrics',
          iconSize: 20,
          icon: Icon(Icons.lyrics_outlined, color: tint(panel == DesktopPanel.lyrics)),
          onPressed: enabled && hasLyrics ? () => toggle(DesktopPanel.lyrics) : null,
        ),
        IconButton(
          tooltip: 'Queue',
          iconSize: 20,
          icon: Icon(Icons.queue_music_rounded, color: tint(panel == DesktopPanel.queue)),
          onPressed: () => toggle(DesktopPanel.queue),
        ),
        const _Volume(),
        IconButton(
          tooltip: 'Now Playing',
          iconSize: 20,
          icon: const Icon(Icons.open_in_full_rounded, color: SonarColors.textSecondary),
          onPressed: enabled ? context.openNowPlaying : null,
        ),
      ],
    );
  }
}

class _Volume extends ConsumerStatefulWidget {
  const _Volume();

  @override
  ConsumerState<_Volume> createState() => _VolumeState();
}

class _VolumeState extends ConsumerState<_Volume> {
  /// Where to come back to when unmuting.
  double _beforeMute = 0.8;

  @override
  Widget build(BuildContext context) {
    final handler = ref.read(controlsProvider);
    // This PC's volume, or the other device's while controlling it.
    final v = ref.watch(volumeProvider).valueOrNull ?? 1;
    return Builder(
      builder: (context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: v == 0 ? 'Unmute' : 'Mute',
            iconSize: 20,
            icon: Icon(
              v == 0
                  ? Icons.volume_off_rounded
                  : v < 0.5
                  ? Icons.volume_down_rounded
                  : Icons.volume_up_rounded,
              color: SonarColors.textSecondary,
            ),
            onPressed: () {
              if (v > 0) _beforeMute = v;
              handler.setUserVolume(v == 0 ? _beforeMute : 0);
            },
          ),
          SizedBox(
            width: 110,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: SonarColors.textPrimary,
                inactiveTrackColor: const Color(0x33FFFFFF),
                thumbColor: SonarColors.textPrimary,
              ),
              child: Slider(
                value: v,
                onChanged: handler.setUserVolume,
                semanticFormatterCallback: (v) => 'Volume ${(v * 100).round()}%',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
