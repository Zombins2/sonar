import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../audio/transitions.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/subsonic/subsonic_client.dart';
import '../../state/providers.dart';
import '../desktop_shortcuts.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';

/// Image cache on disk + cached API responses in the DB.
final cacheSizeProvider = FutureProvider.autoDispose<int>((ref) async {
  var bytes = await ref.read(dbProvider).apiCacheBytes();
  final tmp = (await getTemporaryDirectory()).path;
  for (final key in [DefaultCacheManager.key, 'sonarCovers']) {
    final dir = Directory(p.join(tmp, key));
    if (!await dir.exists()) continue;
    await for (final f in dir.list(recursive: true, followLinks: false)) {
      if (f is File) bytes += await f.length();
    }
  }
  return bytes;
});

final _downloadSizeProvider = FutureProvider.autoDispose<int>((ref) => ref.watch(downloadManagerProvider).totalBytes());

String formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final creds = ref.watch(sessionProvider).valueOrNull;
    final stream = ref.watch(settingsProvider);
    final cache = ref.watch(cacheSizeProvider);
    final host = creds == null ? '' : Uri.tryParse(creds.baseUrl)?.host ?? creds.baseUrl;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      // A readable column on a wide desktop window, under the page title.
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: _list(context, ref, creds: creds, host: host, stream: stream, cache: cache),
        ),
      ),
    );
  }

  Widget _list(
    BuildContext context,
    WidgetRef ref, {
    required ServerCredentials? creds,
    required String host,
    required StreamSettings stream,
    required AsyncValue<int> cache,
  }) => ListView(
    padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 24),
    children: [
      const _Header('Account'),
      ListTile(
        leading: const CircleAvatar(
          backgroundColor: SonarColors.surfaceElevated,
          child: Icon(Icons.person_rounded, color: SonarColors.textPrimary),
        ),
        title: Text(creds?.username ?? ''),
        subtitle: Text(host),
      ),
      ListTile(
        leading: const Icon(Icons.logout_rounded),
        title: const Text('Log out'),
        onTap: () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (d) => AlertDialog(
              backgroundColor: SonarColors.surfaceElevated,
              title: const Text('Log out?'),
              content: const Text('This stops playback and clears the queue and cached library data.'),
              actions: [
                TextButton(onPressed: () => Navigator.of(d).pop(false), child: const Text('Cancel')),
                TextButton(onPressed: () => Navigator.of(d).pop(true), child: const Text('Log out')),
              ],
            ),
          );
          if (ok == true) await ref.read(sessionProvider.notifier).logout();
        },
      ),
      const _Header('Streaming quality'),
      _QualityTile(
        icon: Icons.wifi_rounded,
        // A PC is never on mobile data, so it has just the one setting.
        title: isDesktopPlatform ? 'Quality' : 'Wi-Fi',
        value: stream.wifi,
        onChanged: (v) => ref.read(settingsProvider.notifier).set(wifi: v),
      ),
      if (!isDesktopPlatform)
        _QualityTile(
          icon: Icons.signal_cellular_alt_rounded,
          title: 'Cellular',
          value: stream.cellular,
          onChanged: (v) => ref.read(settingsProvider.notifier).set(cellular: v),
        ),
      const Padding(
        padding: EdgeInsets.fromLTRB(SonarSpacing.gutter, 4, SonarSpacing.gutter, 0),
        child: Text(
          'Applies to songs added to the queue from now on.',
          style: TextStyle(color: SonarColors.textSecondary, fontSize: 13),
        ),
      ),
      const _Header('Storage'),
      ListTile(
        leading: const Icon(Icons.sd_storage_outlined),
        title: const Text('Cache'),
        subtitle: Text(cache.when(data: formatBytes, loading: () => 'Calculating…', error: (_, _) => 'Unknown')),
        trailing: TextButton(
          onPressed: () async {
            await DefaultCacheManager().emptyCache();
            await coverCacheManager.emptyCache();
            await ref.read(dbProvider).clearApiCache();
            PaintingBinding.instance.imageCache.clear();
            ref.invalidate(cacheSizeProvider);
            // Re-fetch art for downloads so they still look right offline.
            final client = ref.read(clientProvider);
            if (client != null && ref.read(reachableProvider)) {
              for (final c in ref.read(downloadManagerProvider).collections) {
                if (c.coverArt != null) precacheCoverArt(client, c.coverArt!).catchError((_) {});
              }
            }
            if (context.mounted) showSnack(context, 'Cache cleared');
          },
          child: const Text('Clear'),
        ),
      ),
      const _Header('Playback'),
      SwitchListTile(
        secondary: const Icon(Icons.all_inclusive_rounded),
        title: const Text('Autoplay'),
        subtitle: const Text('When your queue ends, keep playing similar songs from your library'),
        value: stream.autoplay,
        onChanged: (v) => ref.read(settingsProvider.notifier).set(autoplay: v),
      ),
      const _CrossfadeTile(),
      SwitchListTile(
        secondary: const Icon(Icons.equalizer_rounded),
        title: const Text('Even out volume'),
        subtitle: const Text(
          'Uses the songs\' ReplayGain tags. Albums played in order keep their own loud and quiet moments',
        ),
        value: stream.levelVolume,
        onChanged: (v) => ref.read(settingsProvider.notifier).set(levelVolume: v),
      ),
      const _Header('Lyrics'),
      SwitchListTile(
        secondary: const Icon(Icons.lyrics_outlined),
        title: const Text('Find synced lyrics online'),
        subtitle: const Text(
          'When a song only has plain lyrics, look up timed ones on LRCLIB '
          '(sends the song title and artist)',
        ),
        value: stream.onlineLyrics,
        onChanged: (v) => ref.read(settingsProvider.notifier).set(onlineLyrics: v),
      ),
      if (isDesktopPlatform) ...[
        const _Header('Keyboard shortcuts'),
        for (final (keys, does) in playerShortcutHelp)
          ListTile(
            dense: true,
            title: Text(does),
            trailing: Text(
              keys,
              style: const TextStyle(fontWeight: FontWeight.w700, color: SonarColors.textSecondary),
            ),
          ),
      ],
      if (!isDesktopPlatform) ...[
        const _Header('Downloads'),
        SwitchListTile(
          secondary: const Icon(Icons.signal_cellular_alt_rounded),
          title: const Text('Download over mobile data'),
          subtitle: const Text('Off: downloads wait for Wi-Fi'),
          value: stream.downloadOnCellular,
          onChanged: (v) => ref.read(settingsProvider.notifier).set(downloadOnCellular: v),
        ),
        ListTile(
          leading: const Icon(Icons.download_for_offline_outlined),
          title: const Text('Storage used'),
          subtitle: Text(
            '${ref.watch(_downloadSizeProvider).when(data: formatBytes, loading: () => 'Calculating…', error: (_, _) => 'Unknown')}'
            ' · app storage',
          ),
          trailing: TextButton(
            onPressed: ref.watch(downloadManagerProvider).collections.isEmpty
                ? null
                : () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (d) => AlertDialog(
                        backgroundColor: SonarColors.surfaceElevated,
                        title: const Text('Remove all downloads?'),
                        content: const Text('Downloaded music will be deleted from this phone.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.of(d).pop(false), child: const Text('Cancel')),
                          TextButton(onPressed: () => Navigator.of(d).pop(true), child: const Text('Remove all')),
                        ],
                      ),
                    );
                    if (ok == true) await ref.read(downloadManagerProvider).removeAll();
                  },
            child: const Text('Remove all'),
          ),
        ),
      ],
      const _Header('About'),
      const ListTile(
        leading: Icon(Icons.graphic_eq_rounded),
        title: Text('Sonar'),
        subtitle: Text('Navidrome client · Subsonic API 1.16.1'),
      ),
    ],
  );
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(SonarSpacing.gutter, SonarSpacing.section, SonarSpacing.gutter, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: SonarColors.accentDefault)),
  );
}

/// Crossfade length, 0 (off) to [crossfadeMax] seconds.
class _CrossfadeTile extends ConsumerStatefulWidget {
  const _CrossfadeTile();

  @override
  ConsumerState<_CrossfadeTile> createState() => _CrossfadeTileState();
}

class _CrossfadeTileState extends ConsumerState<_CrossfadeTile> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final seconds = (_dragging ?? ref.watch(settingsProvider).crossfade.toDouble()).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const Icon(Icons.swap_horiz_rounded),
          title: const Text('Crossfade'),
          subtitle: const Text(
            'Blend the end of a song into the next. Tracks of an album played in order stay gapless',
          ),
          trailing: SizedBox(
            // As wide as a switch, so the value lines up with the toggles.
            width: 52,
            child: Text(
              seconds == 0 ? 'Off' : '$seconds s',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        Padding(
          // The track starts under the title text and ends under the switches.
          padding: const EdgeInsets.fromLTRB(38, 0, 12, 0),
          child: Slider(
            value: seconds.toDouble(),
            max: crossfadeMax.toDouble(),
            divisions: crossfadeMax,
            onChanged: (v) => setState(() => _dragging = v),
            onChangeEnd: (v) {
              ref.read(settingsProvider.notifier).set(crossfade: v.round());
              setState(() => _dragging = null);
            },
          ),
        ),
      ],
    );
  }
}

class _QualityTile extends StatelessWidget {
  const _QualityTile({required this.icon, required this.title, required this.value, required this.onChanged});
  final IconData icon;
  final String title;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    trailing: DropdownButton<int>(
      value: value,
      underline: const SizedBox(),
      dropdownColor: SonarColors.surfaceElevated,
      borderRadius: BorderRadius.circular(SonarRadius.art),
      items: [for (final b in bitrateOptions) DropdownMenuItem(value: b, child: Text(bitrateLabel(b)))],
      onChanged: (v) => v == null ? null : onChanged(v),
    ),
  );
}
