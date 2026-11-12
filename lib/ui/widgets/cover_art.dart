import 'dart:math';
import 'dart:ui' show lerpDouble;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../core/theme.dart';
import '../../data/subsonic/subsonic_client.dart';
import '../../state/providers.dart';

/// Two size buckets keep the disk cache small and hits frequent.
int _bucket(double logicalPx, double dpr) => logicalPx * dpr > 360 ? 600 : 300;

/// Covers outlive the default 30-day / 200-file cache so downloaded albums
/// keep their art offline.
final coverCacheManager = CacheManager(
  Config('sonarCovers', stalePeriod: const Duration(days: 3650), maxNrOfCacheObjects: 20000),
);

String _coverKey(String coverArt, int size) => 'cover_${coverArt}_$size';

/// Supplies cover images without a server (screenshot renders, widget tests).
final coverImageOverrideProvider = Provider<ImageProvider Function(String coverArt)?>((_) => null);

/// Cover URLs carry a fresh auth token every time, so the cache key is the
/// stable part (id + size) instead of the URL.
ImageProvider coverImageProvider(SubsonicClient client, String coverArt, {int size = 600}) =>
    CachedNetworkImageProvider(
      client.coverArtUrl(coverArt, size: size).toString(),
      cacheKey: _coverKey(coverArt, size),
      cacheManager: coverCacheManager,
    );

/// Fetches both size buckets of a cover into the cache ahead of time.
Future<void> precacheCoverArt(SubsonicClient client, String coverArt) async {
  for (final size in const [300, 600]) {
    final key = _coverKey(coverArt, size);
    if (await coverCacheManager.getFileFromCache(key) != null) continue;
    await coverCacheManager.downloadFile(client.coverArtUrl(coverArt, size: size).toString(), key: key);
  }
}

class CoverArt extends ConsumerWidget {
  const CoverArt({
    super.key,
    required this.coverArt,
    this.size,
    this.radius = SonarRadius.art,
    this.heroTag,
    this.flight,
    this.shadow = false,
    this.circle = false,
    this.icon = Icons.music_note_rounded,
  });

  final String? coverArt;

  /// Draws the cover while it flies between pages (with [heroTag]).
  final HeroFlightShuttleBuilder? flight;

  /// Square side in logical px. Null fills the parent's width.
  final double? size;
  final double radius;
  final Object? heroTag;
  final bool shadow;
  final bool circle;
  final IconData icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(clientProvider);
    final override = ref.watch(coverImageOverrideProvider);
    final borderRadius = BorderRadius.circular(circle ? 9999 : radius);
    final placeholder = Container(
      color: SonarColors.surfaceElevated,
      alignment: Alignment.center,
      child: LayoutBuilder(
        builder: (_, c) =>
            Icon(icon, color: SonarColors.textSecondary, size: c.maxWidth.isFinite ? c.maxWidth * 0.36 : 32),
      ),
    );

    Widget image = LayoutBuilder(
      builder: (context, c) {
        final side = size ?? (c.maxWidth.isFinite ? c.maxWidth : 300);
        if (coverArt == null) return placeholder;
        if (override != null) {
          return Image(image: override(coverArt!), fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder);
        }
        if (client == null) return placeholder;
        final bucket = _bucket(side, MediaQuery.devicePixelRatioOf(context));
        return CachedNetworkImage(
          imageUrl: client.coverArtUrl(coverArt!, size: bucket).toString(),
          cacheKey: _coverKey(coverArt!, bucket),
          cacheManager: coverCacheManager,
          fit: BoxFit.cover,
          fadeInDuration: SonarMotion.fast,
          placeholder: (_, _) => placeholder,
          errorWidget: (_, _, _) => placeholder,
        );
      },
    );

    image = ClipRRect(
      borderRadius: borderRadius,
      child: AspectRatio(aspectRatio: 1, child: image),
    );
    if (shadow) {
      image = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 10))],
        ),
        child: image,
      );
    }
    if (size != null) image = SizedBox.square(dimension: size, child: image);
    if (heroTag != null) {
      image = Hero(
        tag: heroTag!,
        flightShuttleBuilder: flight,
        createRectTween: flight == null ? null : (a, b) => SquareArcTween(begin: a, end: b),
        child: image,
      );
    }
    return image;
  }
}

/// A hero path that curves like Material's but keeps the cover square: the
/// default arc moves each corner separately and stretches it mid-flight.
class SquareArcTween extends RectTween {
  SquareArcTween({super.begin, super.end});

  late final _center = MaterialPointArcTween(begin: begin?.center, end: end?.center);

  @override
  Rect? lerp(double t) {
    if (begin == null || end == null) return super.lerp(t);
    return Rect.fromCenter(
      center: _center.lerp(t),
      width: lerpDouble(begin!.width, end!.width, t)!,
      height: lerpDouble(begin!.height, end!.height, t)!,
    );
  }
}

/// Loads the large version of a cover into memory ahead of Now Playing, so
/// the page (and the cover flying into it) never shows a placeholder.
void precacheLargeCover(BuildContext context, WidgetRef ref, String? coverArt) {
  final client = ref.read(clientProvider);
  if (coverArt == null || client == null || ref.read(coverImageOverrideProvider) != null) return;
  precacheImage(coverImageProvider(client, coverArt, size: 600), context);
}

/// A cover's colours: [accent] for buttons and bars, and four [glow] tones
/// for the Now Playing background.
class CoverColors {
  const CoverColors(this.accent, this.glow);
  final Color accent;
  final List<Color> glow;

  static final fallback = CoverColors(SonarColors.accentDefault, glowColors(const [], SonarColors.accentDefault));
}

/// Up to four distinct tones from [swatches], dark enough for white text and
/// filled out with shades of [accent] when the cover has fewer colours.
List<Color> glowColors(List<Color> swatches, Color accent) {
  Color tone(Color c) {
    final hsl = HSLColor.fromColor(c);
    return hsl.withLightness(hsl.lightness.clamp(0.2, 0.46)).withSaturation(hsl.saturation.clamp(0.0, 0.8)).toColor();
  }

  final out = <Color>[];
  for (final c in swatches.map(tone)) {
    // Skip near-duplicates so the glows don't all read as one colour.
    final hsl = HSLColor.fromColor(c);
    final close = out.any((o) {
      final h = HSLColor.fromColor(o);
      final dh = (h.hue - hsl.hue).abs();
      return min(dh, 360 - dh) < 14 && (h.lightness - hsl.lightness).abs() < 0.08;
    });
    if (!close) out.add(c);
    if (out.length == 4) return out;
  }
  final base = HSLColor.fromColor(tone(accent));
  if (out.isEmpty) out.add(base.toColor());
  const shifts = [(24.0, -0.08), (-24.0, 0.06), (48.0, -0.12)];
  for (var i = 0; out.length < 4; i++) {
    final (hue, light) = shifts[i];
    out.add(base.withHue((base.hue + hue) % 360).withLightness((base.lightness + light).clamp(0.14, 0.46)).toColor());
  }
  return out;
}

/// Colours pulled from a cover, tuned so white text stays readable on them.
final coverColorsProvider = FutureProvider.family<CoverColors, String>((ref, coverArt) async {
  final client = ref.watch(clientProvider);
  final override = ref.watch(coverImageOverrideProvider);
  if (client == null && override == null) return CoverColors.fallback;
  try {
    final palette = await PaletteGenerator.fromImageProvider(
      override?.call(coverArt) ?? coverImageProvider(client!, coverArt, size: 300),
      size: const Size(96, 96),
      maximumColorCount: 16,
      timeout: const Duration(seconds: 8),
    );
    final picked =
        palette.vibrantColor?.color ??
        palette.dominantColor?.color ??
        palette.darkVibrantColor?.color ??
        palette.mutedColor?.color;
    if (picked == null) return CoverColors.fallback;
    final hsl = HSLColor.fromColor(picked);
    final accent = hsl
        .withLightness(hsl.lightness.clamp(0.28, 0.5))
        .withSaturation(hsl.saturation.clamp(0.0, 0.75))
        .toColor();
    final swatches = [
      palette.dominantColor,
      palette.vibrantColor,
      palette.darkVibrantColor,
      palette.mutedColor,
      palette.lightVibrantColor,
      palette.darkMutedColor,
    ].nonNulls.map((s) => s.color).toList();
    return CoverColors(accent, glowColors(swatches, accent));
  } catch (_) {
    return CoverColors.fallback;
  }
});

/// Accent colour pulled from a cover, tuned so white text stays readable on it.
final coverColorProvider = FutureProvider.family<Color, String>(
  (ref, coverArt) async => (await ref.watch(coverColorsProvider(coverArt).future)).accent,
);

/// Resolves to the cover colour once known, the default accent until then.
Color watchCoverColor(WidgetRef ref, String? coverArt) {
  if (coverArt == null) return SonarColors.accentDefault;
  return ref.watch(coverColorProvider(coverArt)).valueOrNull ?? SonarColors.accentDefault;
}

/// A colour bright enough to read as a button on the dark background.
Color buttonColorFor(Color c) {
  final hsl = HSLColor.fromColor(c);
  // Greyscale covers: a tinted button would invent a hue, so go white.
  if (hsl.saturation < 0.12) return SonarColors.textPrimary;
  return hsl.withLightness(hsl.lightness.clamp(0.5, 0.62)).withSaturation(hsl.saturation.clamp(0.45, 0.9)).toColor();
}

/// A deep shade of the cover colour for bars and the mini player: dark enough
/// for white text, but still coloured (mixing in grey turns golds to mud).
Color barColorFor(Color c) {
  final hsl = HSLColor.fromColor(c);
  if (hsl.saturation < 0.12) return SonarColors.surfaceElevated;
  return hsl.withLightness(0.22).withSaturation(hsl.saturation.clamp(0.35, 0.7)).toColor();
}

/// Black or white, whichever reads on [background].
Color onColor(Color background) =>
    ThemeData.estimateBrightnessForColor(background) == Brightness.dark ? Colors.white : Colors.black;
