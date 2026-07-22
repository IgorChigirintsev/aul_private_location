/// Motion activity, as reported by Android ActivityRecognition (mapped natively)
/// or inferred. Drives the adaptive ping cadence.
enum MotionActivity {
  still,
  walking,
  running,
  onBicycle,
  inVehicle,
  unknown;

  /// Maps an Android `DetectedActivity` type constant to our enum.
  /// (STILL=3, WALKING=7, RUNNING=8, ON_BICYCLE=1, IN_VEHICLE=0, ON_FOOT=2.)
  static MotionActivity fromAndroidType(int type) {
    switch (type) {
      case 3:
        return MotionActivity.still;
      case 7:
        return MotionActivity.walking;
      case 8:
        return MotionActivity.running;
      case 2: // ON_FOOT (generic) → treat as walking cadence
        return MotionActivity.walking;
      case 1:
        return MotionActivity.onBicycle;
      case 0:
        return MotionActivity.inVehicle;
      default:
        return MotionActivity.unknown;
    }
  }
}

/// Higher-priority tracking overrides that shorten the cadence regardless of
/// motion (live-share session or an active SOS).
enum TrackingMode { normal, liveShare, sos }
