// Shared setup for the screenshot renders: the real app on a fake library,
// with a queue playing, and helpers to settle and save frames.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';
import 'package:sonar/audio/audio_handler.dart';
import 'package:sonar/audio/playback_source.dart';
import 'package:sonar/core/router.dart';
import 'package:sonar/core/theme.dart';
import 'package:sonar/data/db/database.dart';
import 'package:sonar/data/lyrics/lrclib_client.dart';
import 'package:sonar/data/subsonic/subsonic_client.dart';
import 'package:sonar/downloads/download_manager.dart';
import 'package:sonar/state/providers.dart';
import 'package:sonar/state/soulbeet_providers.dart';
import 'package:sonar/ui/widgets/cover_art.dart';

import 'fake_library.dart';

const screenshotsEnabled = bool.fromEnvironment('SCREENSHOTS');
const _creds = ServerCredentials(baseUrl: 'https://music.example.ts.net', username: 'alice', password: 'x');
final _out = Directory('build/screens');

class _FakeSession extends SessionNotifier {
  @override
  Future<ServerCredentials?> build() async => _creds;
}

class _NoLrclib extends LrclibClient {
  @override
  Future<String?> findLrc({required String title, required String artist, required Duration duration}) async => null;
}

Future<void> _loadFonts() async {
  final root =
      Platform.environment['FLUTTER_ROOT'] ?? (throw StateError('Run through flutter test (FLUTTER_ROOT is unset)'));
  final dir = '$root/bin/cache/artifacts/material_fonts';
  // Named Roboto-Thin.ttf on Linux and roboto-thin.ttf on Windows: matched
  // ignoring case, as Linux won't.
  final files = {for (final f in Directory(dir).listSync().whereType<File>()) f.uri.pathSegments.last.toLowerCase(): f};
  ByteData font(String name) =>
      ByteData.sublistView((files[name] ?? (throw StateError('No $name in $dir'))).readAsBytesSync());
  // Also under the test engine's fallback family, which a phone replaces with
  // its system font (Roboto) for styles that name no family.
  for (final family in ['Roboto', 'FlutterTest']) {
    final roboto = FontLoader(family);
    for (final w in ['thin', 'light', 'regular', 'medium', 'bold', 'black']) {
      roboto.addFont(Future.value(font('roboto-$w.ttf')));
    }
    await roboto.load();
  }
  final figtree = FontLoader(SonarFonts.family);
  for (final f in Directory('assets/fonts').listSync().whereType<File>().where((f) => f.path.endsWith('.ttf'))) {
    figtree.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  }
  await figtree.load();
  final icons = FontLoader('MaterialIcons')..addFont(Future.value(font('materialicons-regular.otf')));
  await icons.load();
}

MediaItem _item(Map<String, Object?> s, {bool queued = false}) => MediaItem(
  id: s['id']! as String,
  title: s['title']! as String,
  artist: s['artist'] as String?,
  album: s['album'] as String?,
  duration: Duration(seconds: s['duration']! as int),
  extras: {
    'coverArt': s['coverArt'],
    'albumId': s['albumId'],
    'artistId': s['artistId'],
    'suffix': s['suffix'],
    'bitRate': s['bitRate'],
    if (queued) 'queued': true,
  },
);

class Harness {
  Harness._(this.tester, this.router, this.adapter, this.handler, this._db, this._key);
  final WidgetTester tester;
  final GoRouter router;
  final FakeLibraryAdapter adapter;
  final SonarAudioHandler handler;
  final AppDatabase _db;
  final GlobalKey _key;

  /// Text drawn in anything but Figtree (a style that replaces the inherited
  /// one without naming the family falls back to the system font).
  final offFont = <String>{};

  /// Lets real async work (image decoding, palette extraction) finish.
  Future<void> settle([int rounds = 12]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(seconds: 1));
  }

  void _checkFonts(String screen) {
    void visit(RenderObject o) {
      if (o is RenderParagraph) {
        final family = o.text.style?.fontFamily;
        if (family != SonarFonts.family && family != 'MaterialIcons') {
          offFont.add('$screen: "${o.text.toPlainText()}" in $family');
        }
      }
      o.visitChildren(visit);
    }

    visit(_key.currentContext!.findRenderObject()!);
  }

  /// Captures the frame as it is, mid-animation.
  Future<void> snap(String name, {double pixelRatio = 1.5}) async {
    final boundary = _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${_out.path}/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  Future<void> shot(String name, {double pixelRatio = 1.5}) async {
    await settle();
    _checkFonts(name);
    await snap(name, pixelRatio: pixelRatio);
  }

  /// Dispose the tree so periodic timers (sleep countdown etc.) stop.
  Future<void> close() async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(_db.close);
  }
}

/// Pumps the app at [size] physical pixels. Playing track 3 of "Low Tide
/// Letters", with two songs queued by hand.
Future<Harness> pumpSonar(
  WidgetTester tester, {
  Size size = const Size(1080, 2400),
  double devicePixelRatio = 2.625,
  FakeViewPadding padding = const FakeViewPadding(top: 63, bottom: 42),
  List<Override> Function(SonarAudioHandler handler)? extra,
}) async {
  await _loadFonts();
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = devicePixelRatio
    ..padding = padding
    ..viewPadding = padding;
  addTearDown(tester.view.reset);
  // connectivity_plus has no plugin under test; answer its channel quietly.
  tester.binding.defaultBinaryMessenger
    ..setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity_status'), (_) async => null)
    ..setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity'), (_) async => ['wifi']);
  _out.createSync(recursive: true);

  final covers = {
    for (var i = 1; i <= 8; i++) 'c$i': MemoryImage(File('test/visual/covers/c$i.png').readAsBytesSync()),
  };
  final db = AppDatabase(NativeDatabase.memory());
  final handler = SonarAudioHandler(db);
  final downloads = DownloadManager(db);
  final adapter = FakeLibraryAdapter();
  final client = SubsonicClient(_creds, dio: Dio()..httpClientAdapter = adapter);

  final album = [for (var t = 0; t < 9; t++) FakeLibrary.song(0, t)];
  final queue = [
    for (final s in album.take(3)) _item(s),
    _item(FakeLibrary.song(4, 1), queued: true),
    _item(FakeLibrary.song(2, 3), queued: true),
    for (final s in album.skip(3)) _item(s),
  ];
  handler.queue.add(queue);
  handler.mediaItem.add(queue[2]);
  handler.playbackState.add(PlaybackState(queueIndex: 2, playing: true, processingState: AudioProcessingState.ready));
  handler.customState.add(const PlaybackSource(SourceKind.album, 'al1', 'Low Tide Letters'));

  final key = GlobalKey();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dbProvider.overrideWithValue(db),
        audioHandlerProvider.overrideWithValue(handler),
        downloadManagerProvider.overrideWith((_) => downloads),
        sessionProvider.overrideWith(_FakeSession.new),
        clientProvider.overrideWithValue(client),
        lrclibProvider.overrideWithValue(_NoLrclib()),
        connectEnabledProvider.overrideWithValue(false), // No relay here.
        soulbeetEnabledProvider.overrideWithValue(false), // Nor Soulbeet, unless a test adds one.
        coverImageOverrideProvider.overrideWithValue((id) => covers[id] ?? covers['c1']!),
        playingProvider.overrideWith((_) => Stream.value(true)),
        loopModeProvider.overrideWith((_) => Stream.value(LoopMode.off)),
        positionProvider.overrideWith(
          (_) => Stream.value(const PositionData(Duration(seconds: 14), Duration(seconds: 214))),
        ),
        ...?extra?.call(handler),
      ],
      child: Consumer(
        builder: (context, ref, _) => RepaintBoundary(
          key: key,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: buildSonarTheme(),
            routerConfig: ref.watch(routerProvider),
          ),
        ),
      ),
    ),
  );

  final container = ProviderScope.containerOf(tester.element(find.byKey(key)));
  await tester.runAsync(() async {
    for (final c in covers.values) {
      await precacheImage(c, tester.element(find.byKey(key)));
    }
  });
  return Harness._(tester, container.read(routerProvider), adapter, handler, db, key);
}
