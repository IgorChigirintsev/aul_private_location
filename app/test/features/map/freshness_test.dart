import 'package:aul/src/features/map/freshness.dart';
import 'package:aul/src/features/map/geofence_feed.dart';
import 'package:aul/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 7, 15, 12);

Ago _agoOf(Duration since) => relativeAgo(_now.subtract(since), _now);

bool _staleAfter(Duration since) => isStale(_now.subtract(since), _now);

void main() {
  group('relativeAgo buckets — mirrors the web members panel', () {
    test('under a minute is "just now"', () {
      expect(_agoOf(Duration.zero).unit, AgoUnit.justNow);
      expect(_agoOf(const Duration(seconds: 1)).unit, AgoUnit.justNow);
      expect(_agoOf(const Duration(seconds: 59)).unit, AgoUnit.justNow);
    });

    test('60 s is the boundary into minutes', () {
      final ago = _agoOf(const Duration(seconds: 60));
      expect(ago.unit, AgoUnit.minutes);
      expect(ago.count, 1);
    });

    test('minutes are ROUNDED, not truncated', () {
      // 89 s is nearer 2 min than 1 — matching the web's Math.round, and the
      // friendlier read either way.
      expect(_agoOf(const Duration(seconds: 89)).count, 1);
      expect(_agoOf(const Duration(seconds: 90)).count, 2);
      expect(_agoOf(const Duration(seconds: 119)).count, 2);
      expect(_agoOf(const Duration(minutes: 5)).count, 5);
    });

    test('under an hour stays in minutes', () {
      final ago = _agoOf(const Duration(minutes: 59));
      expect(ago.unit, AgoUnit.minutes);
      expect(ago.count, 59);
    });

    test('60 min is the boundary into hours', () {
      final ago = _agoOf(const Duration(minutes: 60));
      expect(ago.unit, AgoUnit.hours);
      expect(ago.count, 1);
    });

    test('hours are rounded too', () {
      expect(_agoOf(const Duration(minutes: 89)).count, 1);
      expect(_agoOf(const Duration(minutes: 90)).count, 2);
      expect(_agoOf(const Duration(hours: 5)).count, 5);
      expect(_agoOf(const Duration(hours: 30)).count, 30);
    });

    test('a fix from the FUTURE clamps to "just now"', () {
      // The timestamp is the reporter's own clock (it comes from inside the
      // sealed payload), so a phone running a minute fast is entirely possible.
      // "in -1 minutes ago" is not a thing to show anyone.
      expect(
        relativeAgo(_now.add(const Duration(minutes: 5)), _now).unit,
        AgoUnit.justNow,
      );
    });

    test('mixed timezones compare by absolute instant', () {
      final utc = DateTime.utc(2026, 7, 15, 11, 30);
      expect(relativeAgo(utc.toLocal(), _now).count, 30);
    });
  });

  group('isStale — the ONE freshness threshold, shared with the geofence feed', () {
    test(
      'the threshold IS the presence-freshness constant, not a copy of it',
      () {
        // One number for "stale on the map / members list" and "aged out of a
        // place": if these ever diverged, a dot could read fresh on one surface and
        // stale on another for the same capture.
        expect(kStaleAfter, kPresenceFreshness);
        expect(kStaleAfter, const Duration(minutes: 15));
      },
    );

    test('below the threshold is fresh — nothing changes', () {
      expect(_staleAfter(Duration.zero), isFalse);
      expect(_staleAfter(const Duration(minutes: 5)), isFalse);
      expect(_staleAfter(const Duration(minutes: 14, seconds: 59)), isFalse);
    });

    test('exactly at the threshold is stale (>=) — the mirror of the feed <', () {
      // The feed calls a fix fresh while `age < freshness`; stale is the exact
      // complement, so the boundary instant belongs to stale and to neither both.
      expect(_staleAfter(const Duration(minutes: 15)), isTrue);
    });

    test('beyond the threshold stays stale', () {
      expect(_staleAfter(const Duration(minutes: 16)), isTrue);
      expect(_staleAfter(const Duration(hours: 2)), isTrue);
    });

    test('a fix from the FUTURE is never stale', () {
      // The timestamp is the reporter's own clock (sealed inside the payload), so
      // a phone running fast yields a negative age — not "very old".
      expect(isStale(_now.add(const Duration(minutes: 10)), _now), isFalse);
    });
  });

  group(
    'batteryColor — the web thresholds, so a phone reads the same on both',
    () {
      const primary = AulColors.primary;
      Color colorOf(int? pct) => batteryColor(pct, primary: primary);

      test('≤15 is danger', () {
        expect(colorOf(0), AulColors.danger);
        expect(colorOf(15), AulColors.danger);
      });

      test('16..30 is amber', () {
        expect(colorOf(16), AulColors.amber);
        expect(colorOf(30), AulColors.amber);
      });

      test('above 30 is the theme primary', () {
        expect(colorOf(31), primary);
        expect(colorOf(100), primary);
      });

      test('the primary is the CALLER\'s, so dark mode gets its own green', () {
        expect(
          batteryColor(80, primary: AulColors.darkPrimary),
          AulColors.darkPrimary,
        );
        // ...but a flat battery is alarming in either theme.
        expect(
          batteryColor(5, primary: AulColors.darkPrimary),
          AulColors.danger,
        );
      });

      test('no battery reported reads as muted, not as healthy', () {
        expect(colorOf(null), AulColors.textSecondary);
      });
    },
  );
}
