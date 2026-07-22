import 'package:aul/src/domain/place.dart';
import 'package:aul/src/tracking/geofence_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const place = Place(
    id: 'home',
    version: 1,
    name: 'Home',
    lat: 43.2,
    lng: 76.8,
    radius: 100,
  );
  final t0 = DateTime.utc(2026, 1, 1);

  test('distanceMeters is ~0 for the same point and grows with separation', () {
    expect(distanceMeters(43.2, 76.8, 43.2, 76.8), lessThan(1));
    final d = distanceMeters(43.2, 76.8, 43.21, 76.8); // ~0.01° lat ≈ 1.11 km
    expect(d, greaterThan(1000));
    expect(d, lessThan(1200));
  });

  test('enter then exit with hysteresis (no flapping at the boundary)', () {
    final e = GeofenceEngine(hysteresisM: 30);
    expect(e.update(43.25, 76.85, [place], t0), isEmpty); // far away
    final enter = e.update(43.2, 76.8, [place], t0);
    expect(enter, hasLength(1));
    expect(enter.first.kind, GeofenceKind.enter);
    expect(e.insidePlaceIds, {'home'});

    // ~111 m out — past the 100 m radius but inside the 130 m exit band → no event.
    expect(e.update(43.201, 76.8, [place], t0), isEmpty);
    expect(e.isInside('home'), isTrue);

    // Clearly beyond radius + margin → exit.
    final exit = e.update(43.25, 76.85, [place], t0);
    expect(exit, hasLength(1));
    expect(exit.first.kind, GeofenceKind.exit);
    expect(e.insidePlaceIds, isEmpty);
  });

  test('deleted place is pruned without a spurious exit', () {
    final e = GeofenceEngine();
    e.update(43.2, 76.8, [place], t0); // enter
    expect(e.insidePlaceIds, {'home'});
    expect(e.update(43.2, 76.8, const [], t0), isEmpty);
    expect(e.insidePlaceIds, isEmpty);
  });
}
