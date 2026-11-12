import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connect/connect_client.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/subsonic/models.dart';
import '../../state/providers.dart';
import 'common.dart';

/// How a device is named in "Playing on …".
String deviceLabel(ConnectDevice d) => switch (d.kind) {
  'pc' => 'your PC',
  'phone' => 'your phone',
  _ => d.name.isEmpty ? 'another device' : d.name,
};

IconData _deviceIcon(String kind) => kind == 'pc' ? Icons.computer_rounded : Icons.smartphone_rounded;

/// Opens the device list. Hidden when Sonar Connect isn't running.
class DeviceButton extends ConsumerWidget {
  const DeviceButton({super.key, this.size = 22});
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(connectLinkProvider) == null) return const SizedBox.shrink();
    final remote = ref.watch(outputTargetProvider) != null;
    final others = ref.watch(connectDevicesProvider).valueOrNull?.isNotEmpty ?? false;
    return IconButton(
      tooltip: 'Devices',
      iconSize: size,
      icon: Icon(
        others ? Icons.devices_rounded : Icons.devices_outlined,
        color: remote ? SonarColors.accentDefault : null,
      ),
      onPressed: () => showDevicePicker(context),
    );
  }
}

/// "Playing on your PC", while this device shows and controls another one.
class PlayingOnLine extends ConsumerWidget {
  const PlayingOnLine({super.key, this.fontSize = 13, this.onTap});
  final double fontSize;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final device = ref.watch(remotePlayerProvider.select((r) => r?.deviceId));
    final d = device == null ? null : ref.watch(connectDevicesProvider).valueOrNull?[device];
    if (d == null) return const SizedBox.shrink();
    return InkWell(
      onTap: onTap ?? () => showDevicePicker(context),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.speaker_rounded, size: fontSize + 3, color: SonarColors.accentDefault),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Playing on ${deviceLabel(d)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: SonarFonts.family,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w700,
                  color: SonarColors.accentDefault,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showDevicePicker(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  constraints: const BoxConstraints(maxWidth: 520),
  builder: (_) => const _DevicePicker(),
);

class _DevicePicker extends ConsumerStatefulWidget {
  const _DevicePicker();

  @override
  ConsumerState<_DevicePicker> createState() => _DevicePickerState();
}

class _DevicePickerState extends ConsumerState<_DevicePicker> {
  /// The device playback is moving to, while it moves.
  String? _moving;
  bool _movingHere = false;

  Future<void> _choose(String? id, {required String label}) async {
    if (id == ref.read(outputTargetProvider)) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _moving = id;
      _movingHere = id == null;
    });
    final ok = await movePlaybackTo(ref, id);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _moving = null;
        _movingHere = false;
      });
      showSnack(context, 'Couldn\'t start it on $label. Is Sonar open there?');
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(connectDevicesProvider).valueOrNull?.values.toList() ?? const [];
    final target = ref.watch(outputTargetProvider);
    final status = ref.watch(connectStatusProvider).valueOrNull ?? ConnectStatus.off;
    final here = ref.read(audioHandlerProvider).currentSong;
    final pc = isDesktopPlatform;
    final text = Theme.of(context).textTheme;
    final remote = ref.watch(remotePlayerProvider);
    final volume = ref.watch(volumeProvider).valueOrNull;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text('Play on', style: text.titleLarge),
            ),
            _DeviceRow(
              icon: pc ? Icons.computer_rounded : Icons.smartphone_rounded,
              title: pc ? 'This PC' : 'This phone',
              subtitle: target != null
                  ? 'Move playback here'
                  : here == null
                  ? 'Nothing playing'
                  : 'Listening here',
              selected: target == null,
              busy: _movingHere,
              onTap: () => _choose(null, label: 'this device'),
            ),
            for (final d in devices)
              _DeviceRow(
                icon: _deviceIcon(d.kind),
                title: switch (d.kind) {
                  'pc' => 'Your PC',
                  'phone' => 'Your phone',
                  _ => d.name,
                },
                subtitle: _nowOn(d),
                selected: target == d.id,
                busy: _moving == d.id && !_movingHere,
                onTap: () => _choose(d.id, label: deviceLabel(d)),
              ),
            // The PC's player bar has its own slider; on the phone it's here.
            if (remote != null && volume != null && !pc)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    const Icon(Icons.volume_down_rounded, color: SonarColors.textSecondary),
                    Expanded(
                      child: Slider(
                        value: volume,
                        onChanged: remote.setUserVolume,
                        semanticFormatterCallback: (v) => 'Volume ${(v * 100).round()}%',
                      ),
                    ),
                    const Icon(Icons.volume_up_rounded, color: SonarColors.textSecondary),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(switch (status) {
                ConnectStatus.online when devices.isEmpty =>
                  'Open Sonar on your ${pc ? 'phone' : 'PC'} to see it here.',
                ConnectStatus.online => 'Picking a device moves what\'s playing there.',
                ConnectStatus.unavailable => 'Can\'t reach Sonar Connect on your server.',
                _ => 'Connecting…',
              }, style: text.bodySmall),
            ),
          ],
        ),
      ),
    );
  }

  String _nowOn(ConnectDevice d) {
    final song = d.state['song'];
    if (song is! Map<String, Object?>) return 'Nothing playing';
    final s = Song.fromJson(song);
    return '${d.playing ? 'Playing' : 'Paused'} · ${s.title} · ${s.artist}';
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.busy,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? SonarColors.accentDefault : SonarColors.textPrimary;
    return ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      selected: selected,
      selectedTileColor: SonarColors.surfaceElevated,
      leading: Icon(icon, color: color),
      title: Text(
        title,
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
      subtitle: subtitle == null ? null : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: busy
          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : selected
          ? const Icon(Icons.speaker_rounded, color: SonarColors.accentDefault)
          : null,
      onTap: busy ? null : onTap,
    );
  }
}
