import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/state/providers.dart';
import 'package:sonar/ui/shell/mini_player.dart';
import 'package:sonar/ui/widgets/cover_art.dart';
import 'package:sonar/ui/widgets/living_backdrop.dart';

final _cover = MemoryImage(File('test/visual/covers/c1.png').readAsBytesSync());

/// How far the background has drifted (its painter's clock).
double _drift(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.descendant(of: find.byType(LivingBackdrop), matching: find.byType(CustomPaint)),
  );
  // The painter is private to the widget; its clock is a public field.
  return ((paint.painter! as dynamic).time as ValueNotifier<double>).value;
}

Widget _backdrop({required bool playing, bool still = false}) => MediaQuery(
  data: MediaQueryData(disableAnimations: still),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: LivingBackdrop(colors: CoverColors.fallback.glow, playing: playing, child: const SizedBox()),
  ),
);

void main() {
  group('background colours', () {
    test('four tones, dark enough for white text, near-duplicates dropped', () {
      const red = Color(0xFFE53935);
      final glow = glowColors([red, const Color(0xFFE53A36), const Color(0xFF1E88E5), Colors.white], red);
      expect(glow, hasLength(4));
      for (final c in glow) {
        expect(HSLColor.fromColor(c).lightness, lessThanOrEqualTo(0.461), reason: '$c too light for white text');
      }
      for (var i = 0; i < glow.length; i++) {
        for (var j = i + 1; j < glow.length; j++) {
          final a = HSLColor.fromColor(glow[i]), b = HSLColor.fromColor(glow[j]);
          final dh = (a.hue - b.hue).abs();
          final sameHue = (dh < 180 ? dh : 360 - dh) < 14;
          expect(sameHue && (a.lightness - b.lightness).abs() < 0.08, isFalse, reason: '${glow[i]} ≈ ${glow[j]}');
        }
      }
    });

    test('a cover with one colour still gets four related shades', () {
      final glow = glowColors(const [Color(0xFF2E7D32)], const Color(0xFF2E7D32));
      expect(glow.toSet(), hasLength(4));
    });
  });

  group('living background', () {
    testWidgets('drifts while playing and nearly stops when paused', (tester) async {
      await tester.pumpWidget(_backdrop(playing: true));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final playing = _drift(tester);
      expect(playing, greaterThan(0.8), reason: 'two seconds of play');

      await tester.pumpWidget(_backdrop(playing: false));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final before = _drift(tester);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(_drift(tester) - before, lessThan(0.4), reason: 'paused: a slow drift at most');
      expect(_drift(tester) - before, greaterThan(0), reason: 'never frozen while open');
    });

    testWidgets('holds still when the phone asks for less motion', (tester) async {
      await tester.pumpWidget(_backdrop(playing: true, still: true));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(_drift(tester), 0);
    });
  });

  testWidgets('the cover flies from the mini player into Now Playing, growing on the way', (tester) async {
    final key = GlobalKey<NavigatorState>();
    Widget cover(double size) =>
        CoverArt(coverArt: 'c1', size: size, radius: 8, heroTag: nowPlayingHeroTag, flight: nowPlayingFlight);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaItemProvider.overrideWith(
            (_) => Stream.value(const MediaItem(id: 's1', title: 'Song', extras: {'coverArt': 'c1'})),
          ),
          clientProvider.overrideWithValue(null),
          coverImageOverrideProvider.overrideWithValue((_) => _cover),
        ],
        child: MaterialApp(
          navigatorKey: key,
          home: Scaffold(
            body: Align(alignment: Alignment.bottomLeft, child: cover(42)),
          ),
        ),
      ),
    );
    key.currentState!.push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (_, _, _) => Scaffold(body: Center(child: cover(300))),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final flight = find.byKey(coverFlightKey);
    expect(flight, findsOneWidget, reason: 'the cover is in flight');
    final mid = tester.getSize(flight);
    expect(mid.width, inExclusiveRange(42, 300));
    expect(mid.height, closeTo(mid.width, 0.5), reason: 'stays square in flight');

    await tester.pumpAndSettle();
    expect(flight, findsNothing, reason: 'landed');
    expect(tester.getSize(find.byType(Hero).last).width, 300);
  });
}
