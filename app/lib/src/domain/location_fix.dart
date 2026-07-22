import 'dart:math' as math;

/// Precision mode the reporter is currently sharing at. The circle sees the mode
/// (it is metadata), but only the coordinate is encrypted.
enum PrecisionMode {
  /// Exact coordinates.
  precise,

  /// Coarsened to ~city granularity before encryption.
  city,

  /// Not sharing (no pings emitted).
  paused;

  String get wire => name;

  static PrecisionMode fromWire(String s) => PrecisionMode.values.firstWhere(
    (m) => m.name == s,
    orElse: () => PrecisionMode.precise,
  );
}

/// A single location sample. This is the plaintext that gets sealed with the
/// circle key — it MUST never be logged or persisted unencrypted.
class LocationFix {
  const LocationFix({
    required this.lat,
    required this.lng,
    required this.capturedAt,
    this.accuracy,
    this.speed,
    this.heading,
    this.battery,
    this.mode = PrecisionMode.precise,
  });

  final double lat;
  final double lng;
  final double? accuracy; // metres
  final double? speed; // m/s
  final double? heading; // degrees
  final int? battery; // 0..100
  final DateTime capturedAt;
  final PrecisionMode mode;

  /// Returns a copy coarsened for [mode]: `city` snaps to ~1 km grid and drops
  /// speed/heading; `precise` is unchanged. Used before sealing so the plaintext
  /// itself carries only the intended precision.
  LocationFix forMode(PrecisionMode mode) {
    switch (mode) {
      case PrecisionMode.precise:
        return copyWith(mode: PrecisionMode.precise);
      case PrecisionMode.paused:
        return copyWith(mode: PrecisionMode.paused);
      case PrecisionMode.city:
        // ~0.01° ≈ 1.1 km latitude; good enough for "in this part of town".
        const grid = 0.01;
        return LocationFix(
          lat: (lat / grid).roundToDouble() * grid,
          lng: (lng / grid).roundToDouble() * grid,
          accuracy: math.max(accuracy ?? 0, 1000),
          // Speed and heading are dropped: they are LOCATION detail, and at city
          // granularity they would re-narrow the very thing the grid widened.
          // Battery is NOT — it says nothing about where you are, and the circle
          // is shown it precisely so someone can tell "phone died" from "stopped
          // sharing". The web reporter keeps it in city mode for the same reason
          // (webReporter.ts sends `batt` unconditionally); dropping it here left
          // city-mode members with a blank battery on the web dashboard.
          battery: battery,
          capturedAt: capturedAt,
          mode: PrecisionMode.city,
        );
    }
  }

  LocationFix copyWith({
    double? lat,
    double? lng,
    double? accuracy,
    double? speed,
    double? heading,
    int? battery,
    DateTime? capturedAt,
    PrecisionMode? mode,
  }) => LocationFix(
    lat: lat ?? this.lat,
    lng: lng ?? this.lng,
    accuracy: accuracy ?? this.accuracy,
    speed: speed ?? this.speed,
    heading: heading ?? this.heading,
    battery: battery ?? this.battery,
    capturedAt: capturedAt ?? this.capturedAt,
    mode: mode ?? this.mode,
  );

  /// The exact JSON object that is encrypted and sent as a ping. Keys are terse
  /// to keep the (padded) payload small.
  Map<String, dynamic> toPayload() => {
    'lat': lat,
    'lng': lng,
    if (accuracy != null) 'acc': accuracy,
    if (speed != null) 'spd': speed,
    if (heading != null) 'hdg': heading,
    if (battery != null) 'batt': battery,
    'ts': capturedAt.toUtc().millisecondsSinceEpoch,
    'mode': mode.wire,
  };

  factory LocationFix.fromPayload(Map<String, dynamic> p) => LocationFix(
    lat: (p['lat'] as num).toDouble(),
    lng: (p['lng'] as num).toDouble(),
    accuracy: (p['acc'] as num?)?.toDouble(),
    speed: (p['spd'] as num?)?.toDouble(),
    heading: (p['hdg'] as num?)?.toDouble(),
    battery: (p['batt'] as num?)?.toInt(),
    capturedAt: DateTime.fromMillisecondsSinceEpoch(
      p['ts'] as int,
      isUtc: true,
    ),
    mode: PrecisionMode.fromWire(p['mode'] as String? ?? 'precise'),
  );
}
