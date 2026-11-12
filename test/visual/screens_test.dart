// Renders every main screen against a fake library and saves PNGs to
// build/screens, for reviewing the look without a phone or server.
//
//   flutter test test/visual --dart-define=SCREENSHOTS=true
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/core/theme.dart';
import 'package:sonar/ui/shell/mini_player.dart';

import 'fake_library.dart';
import 'harness.dart';

void main() {
  testWidgets('render screens', skip: !screenshotsEnabled, (tester) async {
    final h = await pumpSonar(tester);
    final router = h.router;
    final shot = h.shot;
    final settle = h.settle;

    router.go('/home');
    await shot('01_home');

    // Open an album the way a person does, holding its tracks back to see the
    // loading state the preview draws.
    final hold = Completer<void>();
    h.adapter.holdAlbums = hold.future;
    await tester.tap(find.text('Low Tide Letters').first);
    await shot('03a_album_loading');
    hold.complete();
    h.adapter.holdAlbums = null;
    await shot('03_album');
    await tester.drag(find.byType(CustomScrollView).last, const Offset(0, -520));
    await shot('04_album_scrolled');
    await tester.tap(find.byIcon(Icons.more_vert_rounded).at(1));
    await shot('05_song_menu');
    await tester.tapAt(const Offset(200, 80));
    await settle(4);

    // Scrolled to the very end, the last row must clear the floating player bar.
    final barTop = tester.getTopLeft(find.byType(MiniPlayer)).dy;
    await tester.fling(find.byType(CustomScrollView).last, const Offset(0, -4000), 3000);
    await shot('04b_album_end');
    final lastTrack = FakeLibrary.song(0, 8)['title']! as String;
    final lastBottom = tester.getBottomLeft(find.text(lastTrack).last).dy;
    debugPrint('ALBUM END: last row bottom $lastBottom, player bar top $barTop');
    expect(lastBottom, lessThan(barTop), reason: 'last album track hidden behind the player bar');

    router.go('/home');
    await settle(4);
    await tester.fling(find.byType(CustomScrollView).first, const Offset(0, -6000), 3000);
    await shot('02c_home_end');
    // Favorites is the last row; its last card's artist line is the lowest text.
    final homeLast = tester.getBottomLeft(find.text('Sol Marina').last).dy;
    debugPrint('HOME END: last card caption bottom $homeLast, player bar top $barTop');
    expect(homeLast, lessThan(barTop), reason: 'last Home row hidden behind the player bar');
    await tester.fling(find.byType(CustomScrollView).first, const Offset(0, 6000), 3000);
    await settle(4);
    await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -700));
    await shot('02_home_scrolled');
    await tester.longPress(find.text('Static Weather').first);
    await shot('02b_album_quick_actions');
    await tester.tapAt(const Offset(200, 80));
    await settle(4);

    // Discovery rows on Home, from the fake play counts.
    for (final row in ['Made for you', 'Rediscover', 'Not played yet']) {
      expect(find.text(row, skipOffstage: false), findsOneWidget, reason: '$row row missing from Home');
    }
    router.go('/home/mix/ar1');
    await shot('16_mix');
    expect(find.text('Juniper Vale Mix'), findsWidgets);

    router.go('/home/artist/ar1');
    await shot('06_artist');
    await tester.drag(find.byType(CustomScrollView).last, const Offset(0, -900));
    await shot('06b_artist_scrolled');
    expect(find.text('Popular', skipOffstage: false), findsOneWidget);
    expect(find.text('Fans also like', skipOffstage: false), findsOneWidget);
    expect(find.text('Not In Library', skipOffstage: false), findsNothing);

    router.go('/library');
    await shot('07_library_playlists');
    await tester.tap(find.text('Albums'));
    await shot('08_library_albums');
    router.go('/library/playlist/pl0');
    await shot('09_playlist');

    router.go('/search');
    await shot('10_search_empty');
    await tester.tap(find.text('Dream Pop'));
    await shot('10b_genre');
    router.go('/search');
    await settle(4);
    await tester.enterText(find.byType(TextField), 'harbour');
    await tester.pump(const Duration(milliseconds: 400));
    await shot('11_search_results');

    // Open Now Playing from the mini player and catch the cover in flight.
    router.go('/home');
    await settle(4);
    await tester.tap(find.byType(MiniPlayer));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byKey(coverFlightKey), findsOneWidget, reason: 'the cover should fly into Now Playing');
    await h.snap('12a_cover_flight_early');
    await tester.pump(const Duration(milliseconds: 90));
    await h.snap('12b_cover_flight_late');
    await shot('12_now_playing');
    // The glows keep drifting: the same screen a few seconds on.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await h.snap('12c_now_playing_later');
    await tester.tap(find.byTooltip('Lyrics (synced)'));
    await shot('13_lyrics');
    await tester.tapAt(const Offset(200, 60));
    await settle(4);

    router.go('/queue');
    await shot('14_queue');
    router.go('/settings');
    await shot('15_settings');
    expect(h.offFont, isEmpty, reason: 'text not in ${SonarFonts.family}');
    await h.close();
  });
}
