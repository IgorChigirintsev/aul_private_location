import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key for the persisted theme choice.
const _themeKey = 'app.theme';

/// The user's colour-theme choice. [ThemeMode.system] — the default, and what the
/// app did before there was a switch — follows the device; light/dark pin it.
/// Persisted in [SharedPreferences], mirroring [LocaleController].
final themeControllerProvider = NotifierProvider<ThemeController, ThemeMode>(
  ThemeController.new,
);

class ThemeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    _load();
    return ThemeMode.system;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = decodeThemeMode(prefs.getString(_themeKey));
    } catch (_) {
      // No SharedPreferences (e.g. a hermetic test host) — follow the system.
    }
  }

  /// Sets and persists the theme. "System" clears the key rather than storing a
  /// value, so a later default change would still reach anyone on system.
  Future<void> setMode(ThemeMode mode) async {
    state = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mode == ThemeMode.system) {
        await prefs.remove(_themeKey);
      } else {
        await prefs.setString(
          _themeKey,
          mode == ThemeMode.dark ? 'dark' : 'light',
        );
      }
    } catch (_) {
      // Persistence is best-effort; the in-memory choice still applies.
    }
  }
}

/// Parses the persisted value; anything unknown/absent means "follow the system".
/// Exported for tests.
ThemeMode decodeThemeMode(String? v) => switch (v) {
  'dark' => ThemeMode.dark,
  'light' => ThemeMode.light,
  _ => ThemeMode.system,
};
