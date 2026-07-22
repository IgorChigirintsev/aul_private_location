import 'dart:ui' show Locale;

import 'package:aul/src/features/locale_controller.dart';
import 'package:aul/src/features/theme_controller.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// We ship exactly two languages. A device set to something else must land on
  /// whichever is actually READABLE there — a Ukrainian or Kazakh phone should
  /// get Russian, not the English a flat fallback used to give. Mirrors the web's
  /// `nearestLanguage` test.
  group('nearestSupportedLocale', () {
    test('keeps the two languages we ship (region tags included)', () {
      expect(nearestSupportedLocale(const Locale('en')).languageCode, 'en');
      expect(nearestSupportedLocale(const Locale('ru')).languageCode, 'ru');
      expect(
        nearestSupportedLocale(const Locale('ru', 'RU')).languageCode,
        'ru',
      );
      expect(
        nearestSupportedLocale(const Locale('en', 'GB')).languageCode,
        'en',
      );
    });

    test('sends Cyrillic / post-Soviet locales to Russian', () {
      for (final code in [
        'uk', 'be', 'kk', 'ky', 'uz', 'tg', 'tk',
        'az', 'hy', 'ka', 'mn', 'bg', 'sr', 'mk',
      ]) {
        expect(
          nearestSupportedLocale(Locale(code)).languageCode,
          'ru',
          reason: code,
        );
      }
    });

    test('falls back to English for everything else', () {
      for (final code in ['de', 'fr', 'es', 'zh', 'ja', 'tr', 'pl', 'ar']) {
        expect(
          nearestSupportedLocale(Locale(code)).languageCode,
          'en',
          reason: code,
        );
      }
    });
  });

  group('decodeThemeMode', () {
    test('parses the persisted value; anything unknown follows the system', () {
      expect(decodeThemeMode('dark'), ThemeMode.dark);
      expect(decodeThemeMode('light'), ThemeMode.light);
      expect(decodeThemeMode(null), ThemeMode.system);
      expect(decodeThemeMode(''), ThemeMode.system);
      expect(decodeThemeMode('nonsense'), ThemeMode.system);
    });
  });
}
