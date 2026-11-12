import 'dart:async';
import 'dart:ui';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/nav.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import '../widgets/handoff_banner.dart';
import 'desktop_shell.dart';
import 'mini_player.dart';

/// Bottom nav + mini player around the three tabs, with the offline banner on top.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  Timer? _retry;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  StreamSubscription<String>? _playerErrors;

  /// Measured height of the player bar + tabs, for pages to scroll clear of.
  final _chromeHeight = ValueNotifier(0.0);

  /// Back in front: the other device may have been playing meanwhile.
  late final _lifecycle = AppLifecycleListener(onResume: () => ref.invalidate(handoffProvider));

  @override
  void initState() {
    super.initState();
    _lifecycle; // Start listening.
    // Re-check the server whenever the network changes (e.g. a VPN toggled).
    _connectivity = Connectivity().onConnectivityChanged.skip(1).listen((_) => _ping());
    _playerErrors = ref.read(audioHandlerProvider).errors.listen((m) {
      if (mounted) showSnack(context, m);
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _retry?.cancel();
    _connectivity?.cancel();
    _playerErrors?.cancel();
    _chromeHeight.dispose();
    super.dispose();
  }

  Future<void> _ping() async {
    try {
      await ref.read(clientProvider)?.ping();
    } catch (_) {}
  }

  void _syncRetryTimer(bool reachable) {
    _retry?.cancel();
    _retry = reachable ? null : Timer.periodic(const Duration(seconds: 15), (_) => _ping());
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(reachableProvider, (_, ok) => _syncRetryTimer(ok));
    final reachable = ref.watch(reachableProvider);
    currentShellBranch.value = shellBranches[widget.shell.currentIndex];

    if (isWideLayout(context)) {
      return DesktopShell(
        shell: widget.shell,
        banner: AnimatedSize(
          duration: SonarMotion.normal,
          curve: SonarMotion.curve,
          child: reachable ? const SizedBox(width: double.infinity) : _OfflineBanner(onRetry: _ping),
        ),
      );
    }

    return Scaffold(
      extendBody: true,
      body: Column(
        children: [
          AnimatedSize(
            duration: SonarMotion.normal,
            curve: SonarMotion.curve,
            child: reachable ? const SizedBox(width: double.infinity) : _OfflineBanner(onRetry: _ping),
          ),
          Expanded(
            child: BottomChrome(
              height: _chromeHeight,
              child: MediaQuery.removePadding(context: context, removeTop: !reachable, child: widget.shell),
            ),
          ),
        ],
      ),
      bottomNavigationBar: MeasureHeight(
        onHeight: (h) => _chromeHeight.value = h,
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x000E0E0E), Color(0xE60E0E0E), Color(0xFA0E0E0E)],
                  stops: [0, 0.3, 1],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const HandoffBanner(),
                  const MiniPlayer(),
                  NavigationBar(
                    height: 64,
                    backgroundColor: Colors.transparent,
                    indicatorColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                    labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                    selectedIndex: widget.shell.currentIndex,
                    onDestinationSelected: (i) {
                      HapticFeedback.selectionClick();
                      // Tapping the current tab again returns it to its top page.
                      widget.shell.goBranch(i, initialLocation: i == widget.shell.currentIndex);
                    },
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.home_outlined, color: SonarColors.textSecondary),
                        selectedIcon: Icon(Icons.home_rounded, color: SonarColors.textPrimary),
                        label: 'Home',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.search_rounded, color: SonarColors.textSecondary),
                        selectedIcon: Icon(Icons.manage_search_rounded, color: SonarColors.textPrimary),
                        label: 'Search',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.library_music_outlined, color: SonarColors.textSecondary),
                        selectedIcon: Icon(Icons.library_music_rounded, color: SonarColors.textPrimary),
                        label: 'Library',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFF3A2A12),
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            const Icon(Icons.cloud_off_rounded, size: 18, color: Color(0xFFFFC46B)),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Server unreachable — check your connection',
                style: TextStyle(color: Color(0xFFFFE2B8), fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              onPressed: onRetry,
              child: const Text('Retry', style: TextStyle(color: Color(0xFFFFC46B))),
            ),
          ],
        ),
      ),
    ),
  );
}
