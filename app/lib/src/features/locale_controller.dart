import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_localizations.dart';

/// SharedPreferences key for the persisted language override.
const _localeKey = 'app.locale';

/// Global mirror of the user's language override (null = follow the system).
///
/// Kept in sync by [LocaleController] so code WITHOUT a [BuildContext] — the
/// notification service and the reporting foreground-notification text — can
/// resolve localized strings via [currentL10n]. Widgets should prefer
/// `AppLocalizations.of(context)`.
Locale? gLocaleOverride;

/// Languages for which RUSSIAN is the nearer of the two we ship: Cyrillic-script
/// and post-Soviet locales, where Russian is far more likely to be readable than
/// English. Mirrors the web's `nearestLanguage` (web/src/i18n/index.ts).
const _ruNear = {
  'uk', 'be', 'kk', 'ky', 'uz', 'tg', 'tk', 'az', 'hy', 'ka', 'mo', 'mn',
  'bg', 'sr', 'mk',
};

/// Narrows any locale to one the app actually ships: an exact language match
/// wins; otherwise the NEARER of our two — a Ukrainian or Kazakh device lands on
/// Russian rather than English, which a flat English fallback used to do.
Locale nearestSupportedLocale(Locale system) {
  final code = system.languageCode.toLowerCase();
  final supported = AppLocalizations.supportedLocales.any(
    (l) => l.languageCode == code,
  );
  if (supported) return Locale(code);
  return _ruNear.contains(code) ? const Locale('ru') : const Locale('en');
}

/// The effective locale for context-free code: the user's override if set, else
/// the system locale narrowed to the nearest one we ship.
Locale effectiveLocale() {
  final override = gLocaleOverride;
  if (override != null) return override;
  return nearestSupportedLocale(PlatformDispatcher.instance.locale);
}

/// Localizations for code without a [BuildContext] (service / notification
/// paths). Uses the same override the UI does, so notifications match the app.
AppLocalizations currentL10n() => lookupAppLocalizations(effectiveLocale());

/// Re-reads the persisted language override into [gLocaleOverride] for an
/// isolate that has no [LocaleController] to do it — namely the FCM background
/// isolate, which starts with a blank Dart heap and would otherwise render a
/// push in the SYSTEM language while the app itself is pinned to another.
///
/// The web solves the same problem the same way (its service worker reads the
/// mirrored language out of IndexedDB — see sw.ts `lang()`). Best-effort: on any
/// failure the override stays null and [effectiveLocale] falls back to the
/// system language, which is a good answer, just not always the user's.
Future<void> restoreLocaleOverride() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_localeKey);
    gLocaleOverride = (code == null || code.isEmpty) ? null : Locale(code);
  } catch (_) {
    // No SharedPreferences in this isolate — follow the system.
  }
}

/// The user's language choice: null = follow the system, or a specific [Locale].
/// Persisted in [SharedPreferences] and mirrored into [gLocaleOverride].
final localeControllerProvider = NotifierProvider<LocaleController, Locale?>(
  LocaleController.new,
);

class LocaleController extends Notifier<Locale?> {
  @override
  Locale? build() {
    _load();
    return gLocaleOverride;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final code = prefs.getString(_localeKey);
      final locale = (code == null || code.isEmpty) ? null : Locale(code);
      gLocaleOverride = locale;
      state = locale;
    } catch (_) {
      // No SharedPreferences (e.g. a hermetic test host) — follow the system.
    }
  }

  /// Sets (or clears, when [locale] is null) the language override and persists
  /// it. Updates [gLocaleOverride] immediately so context-free strings follow.
  Future<void> setLocale(Locale? locale) async {
    gLocaleOverride = locale;
    state = locale;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (locale == null) {
        await prefs.remove(_localeKey);
      } else {
        await prefs.setString(_localeKey, locale.languageCode);
      }
    } catch (_) {
      // Persistence is best-effort; the in-memory override still applies.
    }
  }
}
