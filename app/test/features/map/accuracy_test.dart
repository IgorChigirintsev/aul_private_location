import 'package:aul/src/features/map/accuracy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isUsableAccuracy (present, finite, positive)', () {
    test('accepts a real positive radius', () {
      expect(isUsableAccuracy(40), isTrue);
    });

    test('rejects null / zero / negative / non-finite', () {
      expect(isUsableAccuracy(null), isFalse);
      expect(isUsableAccuracy(0), isFalse);
      expect(isUsableAccuracy(-5), isFalse);
      expect(isUsableAccuracy(double.nan), isFalse);
      expect(isUsableAccuracy(double.infinity), isFalse);
    });
  });

  group('accuracyParts (matches the web accuracyParts)', () {
    test('whole metres below a kilometre', () {
      final p = accuracyParts(40, 'en');
      expect(p.value, '40');
      expect(p.isKilometers, isFalse);
    });

    test('rounds metres (no false decimetre precision)', () {
      expect(accuracyParts(39.6, 'en').value, '40');
    });

    test('kilometres to one decimal, EN notation', () {
      final p = accuracyParts(1200, 'en');
      expect(p.value, '1.2');
      expect(p.isKilometers, isTrue);
    });

    test('kilometres to one decimal, RU notation (comma separator)', () {
      final p = accuracyParts(1200, 'ru');
      expect(p.value, '1,2');
      expect(p.isKilometers, isTrue);
    });

    test('rounding decides the unit: 999.6 m reads as 1 km', () {
      final p = accuracyParts(999.6, 'en');
      expect(p.isKilometers, isTrue);
      expect(p.value, '1');
    });
  });
}
