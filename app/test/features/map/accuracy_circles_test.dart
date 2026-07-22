import 'dart:math' as math;

import 'package:aul/src/domain/location_fix.dart';
import 'package:aul/src/features/map/map_screen.dart';
import 'package:aul/src/features/map/member_positions.dart';
import 'package:flutter_test/flutter_test.dart';

MemberPosition member(
  String deviceId, {
  double? accuracy,
  double lat = 51.5,
  double lng = -0.1,
}) => MemberPosition(
  deviceId: deviceId,
  fix: LocationFix(
    lat: lat,
    lng: lng,
    accuracy: accuracy,
    capturedAt: DateTime.utc(2026, 7, 15, 12),
  ),
);

List<dynamic> featuresOf(Map<String, dynamic> fc) => fc['features'] as List;

/// The ring's ground radius, north–south, in metres — the axis that needs no
/// latitude correction, so it is the honest one to measure.
double ringRadiusMeters(Map<String, dynamic> feature, double centerLat) {
  final ring =
      ((feature['geometry'] as Map)['coordinates'] as List).first as List;
  var maxLat = -90.0;
  for (final pt in ring) {
    final lat = (pt as List)[1] as double;
    maxLat = math.max(maxLat, lat);
  }
  return (maxLat - centerLat) * (math.pi / 180) * 6371000;
}

void main() {
  test('a vague fix gets a halo sized to its true ground accuracy', () {
    final fc = positionsToAccuracyCircles([member('d1', accuracy: 500)]);
    final features = featuresOf(fc);

    expect(features, hasLength(1));
    expect((features.single as Map)['properties'], {'id': 'd1'});
    expect(
      ringRadiusMeters(features.single as Map<String, dynamic>, 51.5),
      closeTo(500, 1),
    );
  });

  test('a tiny accuracy is skipped — the ring would hide under the pin', () {
    expect(
      featuresOf(positionsToAccuracyCircles([member('d1', accuracy: 5)])),
      isEmpty,
    );
  });

  test('an absent accuracy draws no halo rather than a fake one', () {
    // An older reporter sends no `acc`. Inventing a radius would be worse than
    // showing none: it would render a guess as a measurement.
    expect(featuresOf(positionsToAccuracyCircles([member('d1')])), isEmpty);
  });

  test('the 25 m threshold is inclusive at the boundary', () {
    expect(
      featuresOf(positionsToAccuracyCircles([member('d1', accuracy: 25)])),
      hasLength(1),
    );
    expect(
      featuresOf(positionsToAccuracyCircles([member('d2', accuracy: 24.9)])),
      isEmpty,
    );
  });

  test('a city-mode member shows the ~1 km grid they actually shared', () {
    // forMode(city) floors accuracy at 1000 m, so the halo tells the truth about
    // how coarse the shared position is.
    final cityFix = LocationFix(
      lat: 51.5,
      lng: -0.1,
      accuracy: 8,
      capturedAt: DateTime.utc(2026, 7, 15, 12),
    ).forMode(PrecisionMode.city);
    final pos = MemberPosition(deviceId: 'd1', fix: cityFix);

    final features = featuresOf(positionsToAccuracyCircles([pos]));
    expect(features, hasLength(1));
    expect(
      ringRadiusMeters(features.single as Map<String, dynamic>, cityFix.lat),
      closeTo(1000, 1),
    );
  });

  test('only the members worth haloing are emitted', () {
    final features = featuresOf(
      positionsToAccuracyCircles([
        member('sharp', accuracy: 6),
        member('vague', accuracy: 300),
        member('unknown'),
      ]),
    );
    expect(features, hasLength(1));
    expect(((features.single as Map)['properties'] as Map)['id'], 'vague');
  });

  test('no members means an empty collection, not a malformed source', () {
    final fc = positionsToAccuracyCircles([]);
    expect(fc['type'], 'FeatureCollection');
    expect(featuresOf(fc), isEmpty);
  });
}
