import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/providers.dart';
import '../ui/screens/detail_screens.dart';
import '../ui/screens/genre_screen.dart';
import '../ui/screens/get_music_screen.dart';
import '../ui/screens/home_screen.dart';
import '../ui/screens/library_screen.dart';
import '../ui/screens/login_screen.dart';
import '../ui/screens/now_playing_screen.dart';
import '../ui/screens/queue_screen.dart';
import '../ui/screens/search_screen.dart';
import '../ui/screens/settings_screen.dart';
import '../ui/shell/app_shell.dart';
import 'nav.dart';
import 'theme.dart';

final _rootKey = GlobalKey<NavigatorState>();

/// Album / artist / playlist pages, nested under each tab.
List<RouteBase> _detailRoutes() => [
  GoRoute(
    path: 'album/:id',
    builder: (_, s) => AlbumScreen(id: s.pathParameters['id']!, preview: DetailPreview.of(s.extra)),
  ),
  GoRoute(
    path: 'artist/:id',
    builder: (_, s) => ArtistScreen(id: s.pathParameters['id']!),
  ),
  GoRoute(
    path: 'playlist/:id',
    builder: (_, s) => PlaylistScreen(id: s.pathParameters['id']!, preview: DetailPreview.of(s.extra)),
  ),
  GoRoute(
    path: 'mix/:id',
    builder: (_, s) => MixScreen(artistId: s.pathParameters['id']!, preview: DetailPreview.of(s.extra)),
  ),
  GoRoute(
    path: 'genre/:name',
    builder: (_, s) => GenreScreen(name: s.pathParameters['name']!, color: s.extra is Color ? s.extra! as Color : null),
  ),
  // Get music (Soulbeet): search, then the albums on their way.
  GoRoute(
    path: 'get-music',
    builder: (_, s) => GetMusicScreen(initialQuery: s.extra is String ? s.extra! as String : null),
    routes: [GoRoute(path: 'downloads', builder: (_, _) => const MusicDownloadsScreen())],
  ),
  // Wide windows open settings inside the page area, keeping the sidebar and player bar.
  GoRoute(path: 'settings', builder: (_, _) => const SettingsScreen()),
];

/// Slides up from the bottom, like opening a sheet.
Page<void> _slideUp(GoRouterState state, Widget child) => CustomTransitionPage<void>(
  key: state.pageKey,
  child: child,
  transitionDuration: SonarMotion.normal,
  reverseTransitionDuration: SonarMotion.fast,
  transitionsBuilder: (_, animation, _, child) => SlideTransition(
    position: Tween(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: SonarMotion.curve)),
    child: child,
  ),
);

final routerProvider = Provider<GoRouter>((ref) {
  // Bridge the session into go_router's refresh mechanism.
  final refresh = ValueNotifier(0);
  ref.listen(sessionProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/home',
    refreshListenable: refresh,
    redirect: (_, state) {
      final session = ref.read(sessionProvider);
      if (session.isLoading) return state.matchedLocation == '/splash' ? null : '/splash';
      final loggedIn = session.valueOrNull != null;
      final at = state.matchedLocation;
      if (!loggedIn) return at == '/login' ? null : '/login';
      if (at == '/login' || at == '/splash') return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const Scaffold()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [GoRoute(path: '/home', builder: (_, _) => const HomeScreen(), routes: _detailRoutes())],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: '/search', builder: (_, _) => const SearchScreen(), routes: _detailRoutes())],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: '/library', builder: (_, _) => const LibraryScreen(), routes: _detailRoutes())],
          ),
        ],
      ),
      GoRoute(
        path: '/now-playing',
        parentNavigatorKey: _rootKey,
        pageBuilder: (_, s) => _slideUp(s, const NowPlayingScreen()),
      ),
      GoRoute(path: '/queue', parentNavigatorKey: _rootKey, builder: (_, _) => const QueueScreen()),
      GoRoute(path: '/settings', parentNavigatorKey: _rootKey, builder: (_, _) => const SettingsScreen()),
    ],
  );
});
