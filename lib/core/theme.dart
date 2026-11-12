import 'package:flutter/material.dart';

/// Design tokens from the spec: Spotify's dark layout, Apple Music's restraint.
abstract final class SonarColors {
  static const background = Color(0xFF0E0E0E);
  static const surface = Color(0xFF181818);
  static const surfaceElevated = Color(0xFF222222);
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFA7A7A7);
  static const divider = Color(0xFF2A2A2A);
  static const accentDefault = Color(0xFF1ED760);
}

/// Bundled in assets/fonts; weights 400–800 (pubspec.yaml).
abstract final class SonarFonts {
  static const family = 'Figtree';
}

abstract final class SonarRadius {
  static const art = 12.0;
  static const card = 16.0;
  static const miniPlayer = 14.0;
}

abstract final class SonarSpacing {
  static const gutter = 16.0;
  static const section = 24.0;
}

abstract final class SonarMotion {
  static const fast = Duration(milliseconds: 200);
  static const normal = Duration(milliseconds: 260);
  static const curve = Curves.easeOutCubic;
}

ThemeData buildSonarTheme() {
  const scheme = ColorScheme.dark(
    primary: SonarColors.accentDefault,
    onPrimary: Colors.black,
    secondary: SonarColors.accentDefault,
    surface: SonarColors.background,
    onSurface: SonarColors.textPrimary,
    surfaceContainerHighest: SonarColors.surfaceElevated,
    outline: SonarColors.divider,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    fontFamily: SonarFonts.family,
    scaffoldBackgroundColor: SonarColors.background,
    canvasColor: SonarColors.background,
    splashFactory: InkSparkle.splashFactory,
  );

  final text = base.textTheme.apply(bodyColor: SonarColors.textPrimary, displayColor: SonarColors.textPrimary);

  return base.copyWith(
    textTheme: text.copyWith(
      headlineMedium: text.headlineMedium?.copyWith(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.5),
      titleLarge: text.titleLarge?.copyWith(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.3),
      titleMedium: text.titleMedium?.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 14, color: SonarColors.textSecondary),
      bodySmall: text.bodySmall?.copyWith(fontSize: 13, color: SonarColors.textSecondary),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    dividerTheme: const DividerThemeData(color: Colors.transparent, space: 0),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: SonarColors.surfaceElevated,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(SonarRadius.art), borderSide: BorderSide.none),
      hintStyle: const TextStyle(color: SonarColors.textSecondary),
      labelStyle: const TextStyle(color: SonarColors.textSecondary),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: SonarColors.accentDefault,
        foregroundColor: Colors.black,
        minimumSize: const Size.fromHeight(52),
        shape: const StadiumBorder(),
        textStyle: text.labelLarge?.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: SonarColors.surfaceElevated,
      showDragHandle: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(SonarRadius.card))),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: SonarColors.surfaceElevated,
      // SnackBar uses this style as is (no merge with the theme), so name the family.
      contentTextStyle: TextStyle(fontFamily: SonarFonts.family, color: SonarColors.textPrimary),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: SonarColors.textPrimary,
      unselectedLabelColor: SonarColors.textSecondary,
      indicatorColor: SonarColors.textPrimary,
      dividerColor: Colors.transparent,
      tabAlignment: TabAlignment.start,
      labelStyle: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
    ),
    navigationBarTheme: NavigationBarThemeData(
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => text.labelMedium?.copyWith(
          fontSize: 12,
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
          color: s.contains(WidgetState.selected) ? SonarColors.textPrimary : SonarColors.textSecondary,
        ),
      ),
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 4,
      activeTrackColor: SonarColors.textPrimary,
      inactiveTrackColor: Color(0x40FFFFFF),
      thumbColor: SonarColors.textPrimary,
      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {TargetPlatform.android: FadeForwardsPageTransitionsBuilder()},
    ),
  );
}
