import 'package:aul/src/domain/location_fix.dart';
import 'package:aul/src/tracking/fix_gate.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fix at [seconds] past a fixed epoch with the given accuracy. The coordinates
/// differ per accuracy so "the marker moved" is visible in the assertions.
LocationFix fixAt(int seconds, {double? accuracy, double lat = 51.5}) =>
    LocationFix(
      lat: lat,
      lng: -0.1,
      accuracy: accuracy,
      capturedAt: DateTime.utc(
        2026,
        7,
        15,
        12,
        0,
        0,
      ).add(Duration(seconds: seconds)),
    );

void main() {
  test('the first fix is always accepted', () {
    expect(FixGate().accept(fixAt(0, accuracy: 500)), isTrue);
  });

  test('a sharper fix replaces a vaguer one', () {
    final gate = FixGate()..accept(fixAt(0, accuracy: 500));
    expect(gate.accept(fixAt(5, accuracy: 8)), isTrue);
    expect(gate.held!.accuracy, 8);
  });

  test('a much vaguer fix does NOT replace a sharp, current one', () {
    // The illness this guards: an ±8 m GPS lock, then a ±500 m network estimate
    // arrives 5 s later. Sealing it would yank the pin blocks away and back.
    final gate = FixGate()..accept(fixAt(0, accuracy: 8));
    expect(gate.accept(fixAt(5, accuracy: 500, lat: 51.51)), isFalse);
    expect(gate.held!.accuracy, 8, reason: 'the sharp fix stays authoritative');
    expect(gate.held!.lat, 51.5);
  });

  test('mild vagueness (under 2x) is ordinary jitter and passes', () {
    final gate = FixGate()..accept(fixAt(0, accuracy: 10));
    expect(gate.accept(fixAt(5, accuracy: 19)), isTrue);
    expect(gate.held!.accuracy, 19);
  });

  test('exactly 2x is not "much vaguer" — the guard is strict', () {
    final gate = FixGate()..accept(fixAt(0, accuracy: 10));
    expect(gate.accept(fixAt(5, accuracy: 20)), isTrue);
  });

  test('a vaguer fix DOES replace a sharp one that has gone stale', () {
    // Past 90 s the sharp fix is about where the device WAS. A vague fix about
    // where it IS is the better answer — otherwise one lucky GPS lock would
    // wedge the gate shut for the whole session.
    final gate = FixGate()..accept(fixAt(0, accuracy: 8));
    expect(gate.accept(fixAt(91, accuracy: 500)), isTrue);
    expect(gate.held!.accuracy, 500);
  });

  test('the staleness escape hatch does not open early', () {
    final gate = FixGate()..accept(fixAt(0, accuracy: 8));
    expect(gate.accept(fixAt(89, accuracy: 500)), isFalse);
  });

  test('a fix with no accuracy is passed through rather than dropped', () {
    // "Vaguer" is undefined without a number on both sides, and a fix we can't
    // rank is still the only fix we have — dropping it would freeze the marker.
    final gate = FixGate()..accept(fixAt(0, accuracy: 8));
    expect(gate.accept(fixAt(5)), isTrue);
    expect(gate.accept(fixAt(10, accuracy: 500)), isTrue);
  });

  test('a stationary device that keeps re-asking converges on the sharp fix', () {
    // The re-ask loop hands the gate a coarse fix first (the provider's cached
    // network estimate), then sharper ones as the GPS settles. The gate must let
    // the refinement through — it only blocks DOWNgrades.
    final gate = FixGate();
    expect(gate.accept(fixAt(0, accuracy: 800)), isTrue);
    expect(gate.accept(fixAt(120, accuracy: 60)), isTrue);
    expect(gate.accept(fixAt(240, accuracy: 6)), isTrue);
    expect(gate.held!.accuracy, 6);
  });
}
