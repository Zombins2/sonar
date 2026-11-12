// Draws Sonar's icon, the equaliser mark on the accent green:
// - Windows: windows/runner/resources/app_icon.ico, at each size it asks for.
// - Android: an adaptive icon (green background + mark foreground, which the
//   phone cuts to its own shape; the mark doubles as the themed-icon layer)
//   and the same rounded square as Windows for phones before Android 8.
// - iPhone: every size in ios/Runner/Assets.xcassets/AppIcon.appiconset.
//
//   flutter test tool/make_icon.dart
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar/core/theme.dart';

const _sizes = [16, 24, 32, 48, 64, 128, 256];

/// Android densities: folder suffix and scale from mdpi.
const _densities = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0};

/// The mark's size as a share of an adaptive layer (108 dp, of which the
/// middle 72 dp shows and the middle 66 dp is never cut): the same share of
/// the visible icon as on Windows.
const _adaptiveMark = 0.7 * 72 / 108;

/// [square]: the green rounded square under the mark (Windows, older
/// Android). Without it, just the mark on transparent (adaptive foreground).
/// [fullBleed]: green to every edge (iPhone, which rounds the corners itself).
Future<Uint8List> _render(int size, {bool square = true, double mark = 0.7, bool fullBleed = false}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final s = size.toDouble();
  if (fullBleed) {
    canvas.drawRect(Rect.fromLTWH(0, 0, s, s), Paint()..color = SonarColors.accentDefault);
  } else if (square) {
    // A rounded square, a touch inset so small sizes keep a crisp edge.
    final inset = s * 0.04;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(inset, inset, s - inset * 2, s - inset * 2), Radius.circular(s * 0.22)),
      Paint()..color = SonarColors.accentDefault,
    );
  }
  final icon = Icons.graphic_eq_rounded;
  final glyph = TextPainter(
    textDirection: TextDirection.ltr,
    text: TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(fontFamily: icon.fontFamily, fontSize: s * mark, color: const Color(0xFF0E0E0E)),
    ),
  )..layout();
  glyph.paint(canvas, Offset((s - glyph.width) / 2, (s - glyph.height) / 2));
  final image = await recorder.endRecording().toImage(size, size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  return png!.buffer.asUint8List();
}

/// An .ico holding PNG images (fine for every Windows since Vista).
Uint8List _ico(List<(int, Uint8List)> images) {
  final header = BytesBuilder();
  final data = BytesBuilder();
  var offset = 6 + 16 * images.length;
  final h = ByteData(6)
    ..setUint16(0, 0, Endian.little)
    ..setUint16(2, 1, Endian.little)
    ..setUint16(4, images.length, Endian.little);
  header.add(h.buffer.asUint8List());
  for (final (size, png) in images) {
    final e = ByteData(16)
      ..setUint8(0, size >= 256 ? 0 : size)
      ..setUint8(1, size >= 256 ? 0 : size)
      ..setUint16(4, 1, Endian.little)
      ..setUint16(6, 32, Endian.little)
      ..setUint32(8, png.length, Endian.little)
      ..setUint32(12, offset, Endian.little);
    header.add(e.buffer.asUint8List());
    data.add(png);
    offset += png.length;
  }
  return Uint8List.fromList([...header.takeBytes(), ...data.takeBytes()]);
}

void main() {
  testWidgets('make icon', (tester) async {
    final root = Platform.environment['FLUTTER_ROOT'] ?? (throw StateError('Run through flutter test (FLUTTER_ROOT is unset)'));
    final font = File('$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf');
    await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())))).load();
    await tester.runAsync(() async {
      final images = [for (final s in _sizes) (s, await _render(s))];
      File('windows/runner/resources/app_icon.ico').writeAsBytesSync(_ico(images));
      File('build/app_icon_256.png').writeAsBytesSync(images.last.$2);
      await _android();
      await _ios();
    });
  });
}

/// iPhone: every size the app icon set lists, green to the edges.
Future<void> _ios() async {
  final dir = Directory('ios/Runner/Assets.xcassets/AppIcon.appiconset');
  final name = RegExp(r'^Icon-App-([\d.]+)x[\d.]+@(\d)x\.png$');
  for (final f in dir.listSync().whereType<File>()) {
    final m = name.firstMatch(f.uri.pathSegments.last);
    if (m == null) continue;
    final px = (double.parse(m[1]!) * int.parse(m[2]!)).round();
    f.writeAsBytesSync(await _render(px, fullBleed: true, mark: 0.62));
  }
}

/// build/android_icon_preview.png: the adaptive icon as phones cut it (circle,
/// squircle, rounded square), each showing the middle 72 of 108 dp.
Future<void> _preview(Uint8List foregroundPng) async {
  final codec = await ui.instantiateImageCodec(foregroundPng);
  final fg = (await codec.getNextFrame()).image;
  const cell = 220.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..drawRect(const Rect.fromLTWH(0, 0, cell * 3, cell), Paint()..color = Colors.white);
  final masks = <Path Function(Rect)>[
    (r) => Path()..addOval(r),
    (r) => Path()..addRRect(RRect.fromRectAndRadius(r, Radius.circular(r.width * 0.36))),
    (r) => Path()..addRRect(RRect.fromRectAndRadius(r, Radius.circular(r.width * 0.18))),
  ];
  for (var i = 0; i < masks.length; i++) {
    final shown = Rect.fromLTWH(i * cell + 20, 20, cell - 40, cell - 40);
    // The whole 108 dp layer, so its middle 72 dp fills [shown].
    final layer = Rect.fromCenter(center: shown.center, width: shown.width * 108 / 72, height: shown.height * 108 / 72);
    canvas
      ..save()
      ..clipPath(masks[i](shown))
      ..drawRect(shown, Paint()..color = SonarColors.accentDefault)
      ..drawImageRect(fg, Rect.fromLTWH(0, 0, fg.width.toDouble(), fg.height.toDouble()), layer, Paint())
      ..restore();
  }
  final image = await recorder.endRecording().toImage((cell * 3).round(), cell.round());
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File('build/android_icon_preview.png').writeAsBytesSync(png!.buffer.asUint8List());
}

Future<void> _android() async {
  const res = 'android/app/src/main/res';
  for (final MapEntry(key: density, value: scale) in _densities.entries) {
    final dir = Directory('$res/mipmap-$density')..createSync(recursive: true);
    File('${dir.path}/ic_launcher.png').writeAsBytesSync(await _render((48 * scale).round()));
    File(
      '${dir.path}/ic_launcher_foreground.png',
    ).writeAsBytesSync(await _render((108 * scale).round(), square: false, mark: _adaptiveMark));
  }
  Directory('$res/mipmap-anydpi-v26').createSync(recursive: true);
  // The mark doubles as the themed-icon layer: Android 13 tints it.
  File('$res/mipmap-anydpi-v26/ic_launcher.xml').writeAsStringSync('''
<?xml version="1.0" encoding="utf-8"?>
<!-- Made by tool/make_icon.dart -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
''');
  await _preview(await _render(432, square: false, mark: _adaptiveMark));
  final green = SonarColors.accentDefault.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase();
  File('$res/values/ic_launcher_background.xml').writeAsStringSync('''
<?xml version="1.0" encoding="utf-8"?>
<!-- Made by tool/make_icon.dart -->
<resources>
    <color name="ic_launcher_background">#$green</color>
</resources>
''');
}
