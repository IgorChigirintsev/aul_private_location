import 'package:aul/src/domain/location_fix.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fix = LocationFix(
    lat: 51.50735,
    lng: -0.12776,
    accuracy: 8,
    speed: 1.4,
    heading: 90,
    battery: 77,
    capturedAt: DateTime.utc(2026, 7, 14, 12, 0, 0),
    mode: PrecisionMode.precise,
  );

  test('payload round-trips', () {
    final back = LocationFix.fromPayload(fix.toPayload());
    expect(back.lat, closeTo(fix.lat, 1e-9));
    expect(back.lng, closeTo(fix.lng, 1e-9));
    expect(back.battery, 77);
    expect(back.mode, PrecisionMode.precise);
    expect(back.capturedAt.toUtc(), fix.capturedAt);
  });

  test('city mode coarsens to a ~1km grid and drops speed/heading', () {
    final city = fix.forMode(PrecisionMode.city);
    expect(city.mode, PrecisionMode.city);
    expect(city.speed, isNull);
    expect(city.heading, isNull);
    // Snapped to 0.01° grid.
    expect((city.lat * 100).round() / 100, city.lat);
    expect(city.accuracy, greaterThanOrEqualTo(1000));
    // Still in the same neighbourhood.
    expect((city.lat - fix.lat).abs(), lessThan(0.01));
  });

  test('city mode KEEPS the battery — it is not a location signal', () {
    // Speed and heading go because at city granularity they would re-narrow the
    // very thing the grid widened. Battery says nothing about where you are, and
    // it is what tells a circle "phone died" from "stopped sharing". The web
    // reporter sends it in city mode too (webReporter.ts), so dropping it here
    // left city-mode members with a blank battery on the web dashboard.
    final withBattery = fix.copyWith(battery: 42);
    expect(withBattery.forMode(PrecisionMode.city).battery, 42);
    // And a fix with no battery still has none — nothing is invented.
    expect(fix.forMode(PrecisionMode.city).battery, fix.battery);
  });

  test('paused mode carries the mode label', () {
    expect(fix.forMode(PrecisionMode.paused).mode, PrecisionMode.paused);
  });
}
