import 'package:flutter/material.dart';

/// Aul design tokens (mirrors docs/design-tokens.json / web tokens): a warm,
/// trustworthy palette — "family hearth + engineering honesty".
class AulColors {
  static const cream = Color(0xFFFAF7F2);
  static const surface = Color(0xFFFFFFFF);
  static const primary = Color(0xFF155E4A); // deep pine
  static const primaryHover = Color(0xFF0F4536);
  static const text = Color(0xFF1C1917);
  static const textSecondary = Color(0xFF78716C);
  static const amber = Color(0xFFF59E0B); // notice / battery
  static const danger = Color(0xFFDC2626); // SOS only
  static const success = Color(0xFF16A34A);
  static const border = Color(0xFFE7E5E4);

  // Dark
  static const darkBg = Color(0xFF131211);
  static const darkSurface = Color(0xFF1C1A19);
  static const darkPrimary = Color(0xFF34D399);
}

ThemeData aulLightTheme() => _theme(Brightness.light);
ThemeData aulDarkTheme() => _theme(Brightness.dark);

ThemeData _theme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final primary = dark ? AulColors.darkPrimary : AulColors.primary;
  final bg = dark ? AulColors.darkBg : AulColors.cream;
  final surface = dark ? AulColors.darkSurface : AulColors.surface;
  final onSurface = dark ? AulColors.cream : AulColors.text;

  final scheme = ColorScheme(
    brightness: brightness,
    primary: primary,
    onPrimary: dark ? AulColors.darkBg : Colors.white,
    secondary: AulColors.amber,
    onSecondary: AulColors.text,
    error: AulColors.danger,
    onError: Colors.white,
    surface: surface,
    onSurface: onSurface,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    fontFamily: 'Inter',
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      foregroundColor: onSurface,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: dark ? const Color(0xFF2A2725) : AulColors.border,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF232120) : Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AulColors.border),
      ),
    ),
  );
}
