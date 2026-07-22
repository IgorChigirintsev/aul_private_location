import 'package:aul/src/domain/location_fix.dart';
import 'package:aul/src/tracking/adaptive_scheduler.dart';
import 'package:aul/src/tracking/backoff.dart';
import 'package:aul/src/tracking/motion.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const s = AdaptiveScheduler();

  group('AdaptiveScheduler cadence', () {
    TrackingProfile p(
      MotionActivity a, {
      TrackingMode mode = TrackingMode.normal,
      PrecisionMode precision = PrecisionMode.precise,
    }) => s.profileFor(activity: a, mode: mode, precision: precision);

    test('still → 10 min with displacement filter', () {
      final prof = p(MotionActivity.still);
      expect(prof.interval, const Duration(minutes: 10));
      expect(prof.minDisplacementMeters, greaterThan(0));
    });

    test('walking → 60 s', () {
      expect(p(MotionActivity.walking).interval, const Duration(seconds: 60));
    });

    test('driving → 15 s', () {
      expect(p(MotionActivity.inVehicle).interval, const Duration(seconds: 15));
    });

    test('SOS overrides to 5 s regardless of motion', () {
      expect(
        p(MotionActivity.still, mode: TrackingMode.sos).interval,
        const Duration(seconds: 5),
      );
    });

    test('live-share overrides to 10 s regardless of motion', () {
      expect(
        p(MotionActivity.still, mode: TrackingMode.liveShare).interval,
        const Duration(seconds: 10),
      );
    });

    test('paused precision → no sampling (even during SOS off)', () {
      final prof = p(MotionActivity.walking, precision: PrecisionMode.paused);
      expect(prof.isPaused, isTrue);
      expect(prof.interval, Duration.zero);
    });

    test('unknown activity → the de-facto circle cadence', () {
      final prof = p(MotionActivity.unknown);
      expect(prof.interval, const Duration(seconds: 30));
    });
  });

  group('AdaptiveScheduler precedence (fastest active need wins)', () {
    TrackingProfile needs({
      required bool circle,
      required bool share,
      required bool sos,
      PrecisionMode circlePrecision = PrecisionMode.precise,
    }) => s.profileForNeeds(
      circle: circle,
      share: share,
      sos: sos,
      circlePrecision: circlePrecision,
    );

    test('circle alone → 30 s', () {
      expect(
        needs(circle: true, share: false, sos: false).interval,
        const Duration(seconds: 30),
      );
    });

    test('a share on top of a circle wins → 10 s', () {
      expect(
        needs(circle: true, share: true, sos: false).interval,
        const Duration(seconds: 10),
      );
    });

    test('SOS beats a share when both are active → 5 s', () {
      expect(
        needs(circle: true, share: true, sos: true).interval,
        const Duration(seconds: 5),
      );
    });

    test('a share survives a paused circle precision → 10 s', () {
      // The circle wants nothing, but the share must not be silenced by it.
      expect(
        needs(
          circle: true,
          share: true,
          sos: false,
          circlePrecision: PrecisionMode.paused,
        ).interval,
        const Duration(seconds: 10),
      );
    });

    test('no active need → paused', () {
      expect(needs(circle: false, share: false, sos: false).isPaused, isTrue);
    });
  });

  group('Backoff', () {
    test('ceiling grows exponentially then caps', () {
      final b = Backoff(
        base: const Duration(seconds: 1),
        max: const Duration(seconds: 30),
      );
      expect(b.ceiling(0), const Duration(seconds: 1));
      expect(b.ceiling(1), const Duration(seconds: 2));
      expect(b.ceiling(2), const Duration(seconds: 4));
      expect(b.ceiling(10), const Duration(seconds: 30)); // capped
    });

    test('delay stays within [0, ceiling]', () {
      final b = Backoff(base: const Duration(seconds: 1));
      for (var attempt = 0; attempt < 12; attempt++) {
        final d = b.delay(attempt);
        expect(d, greaterThanOrEqualTo(Duration.zero));
        expect(d, lessThanOrEqualTo(b.ceiling(attempt)));
      }
    });
  });
}
