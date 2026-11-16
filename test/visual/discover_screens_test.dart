// Discover's screens, saved as build/screens/d*.png.
//
//   flutter test test/visual --dart-define=SCREENSHOTS=true
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/connect/connect_client.dart';
import 'package:sonar/data/deezer/deezer_client.dart';
import 'package:sonar/data/discover/discover.dart';
import 'package:sonar/data/musicbrainz/musicbrainz_client.dart';
import 'package:sonar/data/soulbeet/soulbeet_client.dart';
import 'package:sonar/data/soulbeet/soulbeet_downloads.dart';
import 'package:sonar/data/subsonic/models.dart';
import 'package:sonar/state/soulbeet_providers.dart';

import 'fake_library.dart';
import 'harness.dart';

const _tracks = [
  ('Country Road', 'Toots & The Maytals', 'Funky Kingston'),
  ('No Weapon', 'Fred Hammond', 'Pages of Life'),
  ('Never Would Have Made It', 'Marvin Sapp', 'Thirsty'),
  ('Police and Thieves', 'Junior Murvin', 'Police and Thieves'),
  ('Satta Massagana', 'The Abyssinians', 'Satta Massagana'),
  ('Marcus Garvey', 'Burning Spear', 'Marcus Garvey'),
];

/// Discover with six songs to try, as the server would list them.
Discover _seeded() {
  final dl = SoulbeetDownloads(
    client: SoulbeetClient(base: Uri.parse('http://127.0.0.1:9'), username: 'me', password: 'x'),
  );
  final d = Discover(
    library: () => throw UnimplementedError(),
    server: () async => throw const ConnectUnavailable('not here'),
    keepSongs: (ids) async => DiscoverResult(ids, const {}),
    removeSongs: (ids) async => DiscoverResult(ids, const {}),
    downloads: dl,
    deezer: DeezerClient(base: 'http://127.0.0.1:9'),
    musicBrainz: MusicBrainzClient(),
    played: () async => const [],
    read: () async => null,
    write: (_) async {},
    onFolders: (_) {},
    hidden: {},
  );
  d
    ..available = true
    ..libraryId = '2'
    ..note = DiscoverNote.added
    ..songs = [
      for (final (i, (title, artist, album)) in _tracks.indexed)
        Song.fromJson({
          ...FakeLibrary.song(i, 0),
          'id': 'd$i',
          'title': title,
          'artist': artist,
          'album': album,
          'size': (28 + i * 3) << 20,
        }),
    ];
  return d;
}

List<Override> _overrides(Discover d) => [
  soulbeetAvailableProvider.overrideWithValue(true),
  discoverProvider.overrideWith((_) => d),
];

void main() {
  testWidgets('render Discover on the phone', skip: !screenshotsEnabled, (tester) async {
    final d = _seeded();
    final h = await pumpSonar(tester, extra: (_) => _overrides(d));
    final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    await container.read(discoverSettingsProvider.notifier).set(const DiscoverSettings(on: true));

    h.router.go('/home');
    await h.settle();
    await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -450));
    await h.shot('d01_home_discover_row');
    expect(find.text('Keep or remove'), findsOneWidget);

    h.router.push('/home/discover');
    await h.shot('d02_discover');
    expect(find.text('Country Road'), findsOneWidget);
    expect(find.byTooltip('Keep: add to your library'), findsNWidgets(_tracks.length));

    await tester.tap(find.byTooltip('Remove from your server').first);
    await h.shot('d03_discover_removed_undo');
    expect(find.text('Undo'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await h.settle();

    h.router.go('/settings');
    await h.settle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -1400));
    await h.shot('d04_settings_discover');
    expect(find.text('Download songs to try'), findsOneWidget);
    await h.close();
  });

  testWidgets('render Discover on the PC', skip: !screenshotsEnabled, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final d = _seeded();
    final h = await pumpSonar(
      tester,
      size: const Size(1440, 900),
      devicePixelRatio: 1,
      padding: FakeViewPadding.zero,
      extra: (_) => _overrides(d),
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    await container.read(discoverSettingsProvider.notifier).set(const DiscoverSettings(on: true));
    h.router.go('/home');
    await h.settle();
    await tester.tap(find.text('Discover').first);
    await h.shot('d05_pc_discover', pixelRatio: 1);
    expect(find.text('Marcus Garvey'), findsWidgets);
    await h.close();
    debugDefaultTargetPlatformOverride = null; // Checked before tear-downs run.
  });
}
