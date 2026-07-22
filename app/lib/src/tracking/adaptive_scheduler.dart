import '../domain/location_fix.dart';
import 'motion.dart';

/// A tracking profile: how often to sample, and how far the device must move
/// before a new sample is worth taking (displacement filter saves battery when
/// stationary).
class TrackingProfile {
  const TrackingProfile({
    required this.interval,
    required this.minDisplacementMeters,
  });

  final Duration interval;
  final double minDisplacementMeters;

  /// The empty profile: do not sample at all (paused).
  static const paused = TrackingProfile(
    interval: Duration.zero,
    minDisplacementMeters: 0,
  );

  bool get isPaused => interval == Duration.zero;
}

/// Decides the sampling profile from the current motion activity, the tracking
/// mode (live-share/SOS override), and the user's precision mode. This is the
/// battery-defining logic: the ≤3 %/day target is achieved by these intervals
/// plus the displacement filter, so it is unit-tested directly.
///
/// Cadence (spec §9):
///   STILL     → 10 min, only on significant displacement
///   WALKING   → 60 s
///   DRIVING   → 15 s
///   SOS       → 5 s
///   liveShare → 10 s
///   circle    → 30 s (de-facto, see [unknownInterval])
///   paused    → none
class AdaptiveScheduler {
  const AdaptiveScheduler();

  /// An emergency must be at least as fast as a share — keep SOS the fastest.
  static const Duration sosInterval = Duration(seconds: 5);

  /// A live-share link refreshes for its viewer at this cadence.
  static const Duration shareInterval = Duration(seconds: 10);

  static const Duration stillInterval = Duration(minutes: 10);
  static const Duration walkingInterval = Duration(seconds: 60);
  static const Duration drivingInterval = Duration(seconds: 15);

  /// The de-facto circle cadence today: motion detection is unwired, so every
  /// circle fix resolves to [MotionActivity.unknown] and lands here. Tune this
  /// to change how often the circle refreshes.
  static const Duration unknownInterval = Duration(seconds: 30);

  TrackingProfile profileFor({
    required MotionActivity activity,
    required TrackingMode mode,
    required PrecisionMode precision,
  }) {
    if (precision == PrecisionMode.paused) return TrackingProfile.paused;

    // SOS and live-share force a fast cadence regardless of motion, but not the
    // SAME one: an emergency stays the fastest, a share is a step slower.
    if (mode == TrackingMode.sos) {
      return const TrackingProfile(
        interval: sosInterval,
        minDisplacementMeters: 0,
      );
    }
    if (mode == TrackingMode.liveShare) {
      return const TrackingProfile(
        interval: shareInterval,
        minDisplacementMeters: 0,
      );
    }

    switch (activity) {
      case MotionActivity.still:
        return const TrackingProfile(
          interval: stillInterval,
          minDisplacementMeters: 100,
        );
      case MotionActivity.walking:
      case MotionActivity.running:
      case MotionActivity.onBicycle:
        return const TrackingProfile(
          interval: walkingInterval,
          minDisplacementMeters: 20,
        );
      case MotionActivity.inVehicle:
        return const TrackingProfile(
          interval: drivingInterval,
          minDisplacementMeters: 50,
        );
      case MotionActivity.unknown:
        return const TrackingProfile(
          interval: unknownInterval,
          minDisplacementMeters: 30,
        );
    }
  }

  /// The profile for the ONE shared foreground stream when several needs want it
  /// at once. The fastest active need wins: SOS < share < circle. A live share
  /// and SOS always sample at the precise/fast cadence, so a paused circle
  /// precision never silences them; the circle contributes only via
  /// [circlePrecision] (paused ⇒ the circle wants nothing).
  ///
  /// This is the single expression of that precedence — every start site routes
  /// its active-stream profile through here, so a share riding a slower circle
  /// stream is reconfigured up to the share cadence, and drops back to the
  /// circle's own when it ends.
  TrackingProfile profileForNeeds({
    required bool circle,
    required bool share,
    required bool sos,
    required PrecisionMode circlePrecision,
    MotionActivity activity = MotionActivity.unknown,
  }) {
    TrackingProfile? best;
    void consider(TrackingProfile p) {
      if (p.isPaused) return;
      if (best == null || p.interval < best!.interval) best = p;
    }

    if (sos) {
      consider(
        profileFor(
          activity: activity,
          mode: TrackingMode.sos,
          precision: PrecisionMode.precise,
        ),
      );
    }
    if (share) {
      consider(
        profileFor(
          activity: activity,
          mode: TrackingMode.liveShare,
          precision: PrecisionMode.precise,
        ),
      );
    }
    if (circle) {
      consider(
        profileFor(
          activity: activity,
          mode: TrackingMode.normal,
          precision: circlePrecision,
        ),
      );
    }
    return best ?? TrackingProfile.paused;
  }
}
