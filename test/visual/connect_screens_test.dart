// Sonar Connect screens, with the "PC" (or the "phone") stood in by a fake
// device on an unstarted client, saved as build/screens/c*.png.
//
//   flutter test test/visual --dart-define=SCREENSHOTS=true
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/connect/connect_client.dart';
import 'package:sonar/connect/connect_link.dart';
import 'package:sonar/data/subsonic/models.dart';
import 'package:sonar/state/providers.dart';
import 'package:sonar/ui/widgets/device_picker.dart';

import 'fake_library.dart';
import 'harness.dart';

/// A client with [kind] listed as playing a song from "Harbour Lights".
ConnectClient _clientWith(String kind) {
  final song = Song.fromJson(FakeLibrary.song(1, 2));
  final queue = [for (var t = 0; t < 6; t++) Song.fromJson(FakeLibrary.song(1, t))];
  final client = ConnectClient(
    base: Uri.parse('http://127.0.0.1:9'),
    me: ConnectDeviceInfo(id: 'me', name: 'me', kind: kind == 'pc' ? 'phone' : 'pc'),
    loginProof: () => const {},
  );
  client.status.value = ConnectStatus.online;
  client.devices.value = {
    'other': ConnectDevice(
      id: 'other',
      name: kind,
      kind: kind,
      state: {
        'song': song.toJson(),
        'index': 2,
        'durationMs': song.duration.inMilliseconds,
        'playing': true,
        'positionMs': 61000,
        'queueRev': 1,
        'queueStart': 0,
        'queue': [for (final s in queue) s.toJson()],
        'queued': const <int>[],
        'source': {'kind': 'album', 'id': 'al2', 'title': 'Harbour Lights'},
        'volume': 0.6,
      },
      positionAt: DateTime.now(),
    ),
  };
  return client;
}

void main() {
  testWidgets('render connect on the phone', skip: !screenshotsEnabled, (tester) async {
    final client = _clientWith('pc');
    final h = await pumpSonar(
      tester,
      extra: (handler) => [connectLinkProvider.overrideWithValue(ConnectLink(handler: handler, client: client))],
    );
    h.router.go('/home');
    await h.shot('c01_phone_mini_player');
    expect(find.text('Playing on your PC'), findsOneWidget, reason: 'an idle phone follows the playing PC');

    h.router.push('/now-playing');
    await h.shot('c02_phone_now_playing');
    await tester.tap(find.byTooltip('Devices').first);
    await h.shot('c03_phone_devices');
    expect(find.text('Your PC'), findsOneWidget);
    expect(find.text('This phone'), findsOneWidget);
    await h.close();
  });

  testWidgets('render connect on the PC', skip: !screenshotsEnabled, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final client = _clientWith('phone');
    final h = await pumpSonar(
      tester,
      size: const Size(1440, 900),
      devicePixelRatio: 1,
      padding: FakeViewPadding.zero,
      extra: (handler) => [connectLinkProvider.overrideWithValue(ConnectLink(handler: handler, client: client))],
    );
    h.router.go('/home');
    await h.shot('c04_pc_playing_on_phone', pixelRatio: 1);
    expect(find.text('Playing on your phone'), findsOneWidget);
    await tester.tap(find.byType(DeviceButton).first);
    await h.shot('c05_pc_devices', pixelRatio: 1);
    await h.close();
    debugDefaultTargetPlatformOverride = null;
  });
}
