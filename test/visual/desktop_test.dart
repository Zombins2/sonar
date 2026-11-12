// The desktop layout at a laptop window size, saved as build/screens/d*.png.
//
//   flutter test test/visual --dart-define=SCREENSHOTS=true
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/core/theme.dart';
import 'package:sonar/ui/shell/desktop_shell.dart';
import 'package:sonar/ui/shell/mini_player.dart';

import 'harness.dart';

void main() {
  testWidgets('render desktop', skip: !screenshotsEnabled, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final h = await pumpSonar(tester, size: const Size(1440, 900), devicePixelRatio: 1, padding: FakeViewPadding.zero);

    h.router.go('/home');
    await h.shot('d01_home', pixelRatio: 1);
    expect(find.byType(DesktopPlayerBar), findsOneWidget, reason: 'wide windows get the desktop player bar');
    expect(find.byType(MiniPlayer), findsNothing);
    expect(find.text('Downloads'), findsNothing, reason: 'no downloads on desktop');

    await tester.tap(find.text('Low Tide Letters').first);
    await h.shot('d02_album', pixelRatio: 1);

    await tester.tap(find.byTooltip('Queue'));
    await h.shot('d03_queue_panel', pixelRatio: 1);
    await tester.tap(find.byTooltip('Lyrics'));
    await h.shot('d04_lyrics_panel', pixelRatio: 1);
    await tester.tap(find.byTooltip('Close'));
    await h.settle(4);

    h.router.go('/library');
    await h.settle(4);
    await tester.tap(find.text('Albums'));
    await h.shot('d05_library', pixelRatio: 1);

    await tester.tap(find.byTooltip('Now Playing').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(coverFlightKey), findsOneWidget, reason: 'the cover should fly up from the player bar');
    await h.snap('d06a_cover_flight', pixelRatio: 1);
    await h.shot('d06_now_playing', pixelRatio: 1);
    await tester.tap(find.text('Up next'));
    await h.shot('d07_now_playing_queue', pixelRatio: 1);

    h.router.pop(); // Back from Now Playing.
    await h.settle(4);
    await tester.tap(find.text('Settings'));
    await h.shot('d08_settings', pixelRatio: 1);
    expect(find.byType(DesktopPlayerBar), findsOneWidget, reason: 'settings opens inside the window on desktop');
    expect(h.offFont, isEmpty, reason: 'text not in ${SonarFonts.family}');
    await h.close();
    // Reset inside the test: the framework checks debug values before teardown.
    debugDefaultTargetPlatformOverride = null;
  });
}
