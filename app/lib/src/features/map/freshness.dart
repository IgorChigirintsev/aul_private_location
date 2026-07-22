import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../theme.dart';
import 'geofence_feed.dart' show kPresenceFreshness;

/// Which bucket a position's age falls into for the "updated N ago" label.
enum AgoUnit {
  /// Under a minute old — "just now".
  justNow,

  /// Under an hour old — "N min ago".
  minutes,

  /// An hour or more — "N h ago".
  hours,
}

/// A relative age, bucketed and ready to localize: the [unit] picks the phrase,
/// [count] fills its placeholder (and is 0 for [AgoUnit.justNow], which has none).
typedef Ago = ({AgoUnit unit, int count});

/// Buckets how long ago [at] was, as of [now] — the pure half of the "updated N
/// min ago" label, so the boundaries can be tested without a clock or a widget.
///
/// Mirrors the web members panel exactly (MembersPanel.tsx `agoLabel`): under a
/// minute is "just now", under an hour is rounded minutes, otherwise rounded
/// hours. Rounding, not truncation — matching the web's `Math.round`, and it is
/// the friendlier read anyway (119 s is closer to "2 min ago" than "1 min ago").
///
/// A capture from the FUTURE (a reporter whose clock runs fast — the timestamp
/// comes from inside the sealed payload, so it is their clock, not the server's)
/// clamps to "just now" rather than rendering a negative age.
Ago relativeAgo(DateTime at, DateTime now) {
  final seconds = now.difference(at).inSeconds;
  if (seconds < 60) return (unit: AgoUnit.justNow, count: 0);
  final minutes = (seconds / 60).round();
  if (minutes < 60) return (unit: AgoUnit.minutes, count: minutes);
  return (unit: AgoUnit.hours, count: (minutes / 60).round());
}

/// The ONE staleness threshold, shared verbatim with the geofence feed's
/// presence freshness ([kPresenceFreshness], which mirrors the web's
/// `FRESH_MS = 15min`). A position at or beyond this age tells you nothing about
/// where its device is NOW, so it must be presented as stale rather than current
/// — otherwise a phone that went offline (server switched off, network gone)
/// keeps a last-known dot looking live forever. Having the map's "stale" read and
/// the feed's "aged out of a place" read off the SAME number is what keeps them
/// from ever disagreeing.
const Duration kStaleAfter = kPresenceFreshness;

/// Whether a position captured [at] is STALE as of [now]: [threshold] old or
/// older. The exact boundary is stale (`>=`), the mirror image of the feed's
/// "fresh" test (`age < freshness`), so a position is fresh on one and stale on
/// the other for not a single instant.
///
/// A capture from the FUTURE (a reporter whose clock runs fast — the timestamp is
/// their own, sealed inside the payload) has a negative age and is never stale.
/// This is CLIENT-INFERRED and presentation-only: it changes how a decrypted
/// `capturedAt` is shown, never what is fetched or decrypted.
bool isStale(DateTime at, DateTime now, {Duration threshold = kStaleAfter}) =>
    now.difference(at) >= threshold;

/// The localized "updated N ago" label for a position captured [at], as of [now].
String formatAgo(AppLocalizations l10n, DateTime at, DateTime now) {
  final ago = relativeAgo(at, now);
  return switch (ago.unit) {
    AgoUnit.justNow => l10n.agoJustNow,
    AgoUnit.minutes => l10n.agoMinutes(ago.count),
    AgoUnit.hours => l10n.agoHours(ago.count),
  };
}

/// The colour a battery percentage reads at: red at/below 15, amber at/below 30,
/// otherwise the normal primary. Mirrors the web `batteryColor` thresholds
/// (web/src/design/tokens.ts) so the same phone reads the same on both.
///
/// [primary] is passed in rather than taken from [AulColors] because primary is
/// the one token that differs between the light and dark themes — a healthy
/// battery should be the theme's green, not the light theme's green on a dark
/// screen. Null (no battery reported) gets the muted secondary text colour.
Color batteryColor(int? pct, {required Color primary}) {
  if (pct == null) return AulColors.textSecondary;
  if (pct <= 15) return AulColors.danger;
  if (pct <= 30) return AulColors.amber;
  return primary;
}
