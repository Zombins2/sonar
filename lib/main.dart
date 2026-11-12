import 'dart:ui' show PointerDeviceKind;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'audio/audio_handler.dart';
import 'core/nav.dart';
import 'core/platform.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'data/db/database.dart';
import 'data/subsonic/subsonic_client.dart';
import 'downloads/download_manager.dart';
import 'state/providers.dart';
import 'ui/desktop_shortcuts.dart';
import 'ui/screens/search_screen.dart';
import 'ui/shell/desktop_shell.dart';
import 'ui/widgets/cover_art.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  // The server's saved queue then says which device left it.
  if (isDesktopPlatform) SubsonicClient.clientName = SubsonicClient.desktopClientName;

  final db = AppDatabase();
  final handler = await AudioService.init(
    builder: () => SonarAudioHandler(db),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.sonar.sonar.playback',
      androidNotificationChannelName: 'Playback',
      androidNotificationIcon: 'drawable/ic_stat_sonar',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
  await handler.init();
  final downloads = DownloadManager(db);
  await downloads.init();
  handler
    ..localPath = downloads.localPath
    ..downloads = downloads;

  runApp(
    ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        audioHandlerProvider.overrideWithValue(handler),
        downloadManagerProvider.overrideWith((_) => downloads),
      ],
      child: const SonarApp(),
    ),
  );
}

class SonarApp extends ConsumerStatefulWidget {
  const SonarApp({super.key});

  @override
  ConsumerState<SonarApp> createState() => _SonarAppState();
}

class _SonarAppState extends ConsumerState<SonarApp> {
  @override
  void initState() {
    super.initState();
    final handler = ref.read(audioHandlerProvider);
    final downloads = ref.read(downloadManagerProvider);
    handler.isReachable = () => ref.read(reachableProvider);
    // Keep the player and downloader pointed at the current server and settings.
    ref.listenManual(clientProvider, (_, client) {
      handler.setClient(client);
      downloads.client = client;
      downloads.precacheCover = client == null ? null : (art) => precacheCoverArt(client, art);
    }, fireImmediately: true);
    ref.listenManual(settingsProvider, (_, s) {
      handler.bitrateResolver = () => resolveBitrate(s);
      handler.autoplay = s.autoplay;
      handler.crossfade = s.crossfade;
      handler.levelVolume = s.levelVolume;
      downloads.allowCellular = s.downloadOnCellular;
    }, fireImmediately: true);
    // Sonar Connect runs while logged in, whatever screen is open.
    ref.listenManual(connectLinkProvider, (_, _) {}, fireImmediately: true);
    ref.listenManual(outputTargetProvider, (_, _) {}, fireImmediately: true);
  }

  void _shortcut(PlayerShortcut s) {
    // The keys drive the player shown: this device's, or the one it's controlling.
    final controls = ref.read(controlsProvider);
    final router = ref.read(routerProvider);
    final remote = ref.read(remotePlayerProvider);
    final handler = ref.read(audioHandlerProvider);
    final position = remote?.position ?? handler.player.position;
    final volume = remote?.volume ?? handler.userVolume.value;
    final playing = remote?.playing ?? handler.player.playing;
    switch (s) {
      case PlayerShortcut.playPause:
        if (controls.currentSong != null) playing ? controls.pause() : controls.play();
      case PlayerShortcut.next:
        controls.skipToNext();
      case PlayerShortcut.previous:
        controls.skipToPrevious();
      case PlayerShortcut.seekForward:
        controls.seek(position + const Duration(seconds: 10));
      case PlayerShortcut.seekBack:
        controls.seek(position < const Duration(seconds: 10) ? Duration.zero : position - const Duration(seconds: 10));
      case PlayerShortcut.volumeUp:
        controls.setUserVolume(volume + 0.05);
      case PlayerShortcut.volumeDown:
        controls.setUserVolume(volume - 0.05);
      case PlayerShortcut.shuffle:
        controls.toggleShuffle();
      case PlayerShortcut.repeat:
        controls.cycleRepeat();
      case PlayerShortcut.search:
        if (const {'/now-playing', '/queue', '/settings'}.contains(router.state.matchedLocation)) router.pop();
        router.go('/search');
        WidgetsBinding.instance.addPostFrameCallback((_) => searchFocusRequests.value++);
      case PlayerShortcut.close:
        final at = router.state.matchedLocation;
        if (const {'/now-playing', '/queue'}.contains(at) || isSettingsLocation(at)) {
          router.pop();
        } else {
          ref.read(desktopPanelProvider.notifier).state = null;
        }
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Sonar',
    debugShowCheckedModeBanner: false,
    theme: buildSonarTheme(),
    themeMode: ThemeMode.dark,
    scrollBehavior: const _SonarScrollBehavior(),
    builder: isDesktopPlatform ? (context, child) => DesktopShortcuts(onShortcut: _shortcut, child: child!) : null,
    routerConfig: ref.watch(routerProvider),
  );
}

/// Lets a mouse drag the sideways album rows too, not just a finger.
class _SonarScrollBehavior extends MaterialScrollBehavior {
  const _SonarScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => PointerDeviceKind.values.toSet();
}
