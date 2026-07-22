import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:aul/src/crypto/ping_codec.dart';
import 'package:aul/src/domain/location_fix.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AulCrypto crypto;
  late PingCodec codec;

  setUpAll(() async {
    crypto = await AulCrypto.load();
    codec = PingCodec(crypto);
  });

  test('seals a fix and opens it back', () {
    final key = crypto.generateCircleKey();
    final fix = LocationFix(
      lat: 43.238949,
      lng: 76.889709,
      accuracy: 12,
      battery: 64,
      capturedAt: DateTime.utc(2026, 7, 14, 9, 30),
    );
    final blob = codec.seal(fix, key);
    final back = codec.open(blob.nonce, blob.ciphertext, key);
    expect(back.lat, closeTo(fix.lat, 1e-9));
    expect(back.battery, 64);
  });

  test('padding makes precise and city ciphertext the same length', () {
    final key = crypto.generateCircleKey();
    final at = DateTime.utc(2026, 7, 14, 9, 30);
    final precise = LocationFix(
      lat: 43.238949,
      lng: 76.889709,
      accuracy: 5,
      speed: 3,
      heading: 200,
      battery: 50,
      capturedAt: at,
    );
    final city = precise.forMode(PrecisionMode.city);
    final a = codec.seal(precise, key);
    final b = codec.seal(city, key);
    // Fixed-size padding ⇒ ciphertext length does not leak precision mode.
    expect(a.ciphertext.length, b.ciphertext.length);
  });
}
