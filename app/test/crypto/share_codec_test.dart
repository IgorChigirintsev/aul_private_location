import 'dart:convert';

import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:aul/src/crypto/share_codec.dart';
import 'package:flutter_test/flutter_test.dart';

/// The live-share seal: a position sealed under K_share — the per-session key
/// that exists only on the sharer's device and in the link's fragment.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AulCrypto crypto;
  late ShareCodec codec;

  setUpAll(() async {
    crypto = await AulCrypto.load();
    codec = ShareCodec(crypto);
  });

  ShareFix fixture() => ShareFix(
    lat: 43.238949,
    lng: 76.889709,
    accuracy: 12.5,
    capturedAt: DateTime.fromMillisecondsSinceEpoch(1752000000000, isUtc: true),
  );

  test('seal → open round-trips the position under K_share', () {
    final key = crypto.generateCircleKey();
    final fix = fixture();

    final sealed = codec.seal(fix, key);
    final opened = codec.open(sealed.nonceB64, sealed.ciphertextB64, key);

    expect(opened, isNotNull);
    expect(opened!.lat, closeTo(fix.lat, 1e-9));
    expect(opened.lng, closeTo(fix.lng, 1e-9));
    expect(opened.accuracy, closeTo(12.5, 1e-9));
    expect(opened.capturedAt, fix.capturedAt);
    key.dispose();
  });

  test('the WRONG key opens nothing — null, never a partial result', () {
    final key = crypto.generateCircleKey();
    final other = crypto.generateCircleKey();

    final sealed = codec.seal(fixture(), key);

    expect(codec.open(sealed.nonceB64, sealed.ciphertextB64, other), isNull);
    key.dispose();
    other.dispose();
  });

  test('a tampered ciphertext fails closed (AEAD tag)', () {
    final key = crypto.generateCircleKey();
    final sealed = codec.seal(fixture(), key);

    final bytes = base64.decode(sealed.ciphertextB64);
    bytes[0] ^= 0x01; // flip one bit
    expect(codec.open(sealed.nonceB64, base64.encode(bytes), key), isNull);

    // Garbage in the wire fields is a null too, not a crash.
    expect(codec.open('not-base64!', sealed.ciphertextB64, key), isNull);
    key.dispose();
  });

  test(
    'every sealed position is the same length — coordinates do not leak',
    () {
      final key = crypto.generateCircleKey();
      final near = codec.seal(
        ShareFix(lat: 0.1, lng: 0.1, capturedAt: DateTime.now()),
        key,
      );
      final far = codec.seal(
        ShareFix(
          lat: -43.2389491234,
          lng: 176.8897091234,
          accuracy: 1234.5,
          capturedAt: DateTime.now(),
        ),
        key,
      );
      expect(far.ciphertextB64.length, near.ciphertextB64.length);
      key.dispose();
    },
  );

  test('the sealed payload is the web ShareFix shape and nothing more', () {
    final key = crypto.generateCircleKey();
    final sealed = codec.seal(fixture(), key);

    // Open at the raw layer to inspect what actually goes over the wire: a
    // stranger with a link must get a point, not a battery level or a mode.
    final padded = crypto.openPing(
      base64.decode(sealed.nonceB64),
      base64.decode(sealed.ciphertextB64),
      key,
    );
    final json =
        jsonDecode(utf8.decode(crypto.unpad(padded, 256)))
            as Map<String, dynamic>;

    expect(json.keys.toSet(), {'lat', 'lng', 'acc', 'ts'});
    expect(json['ts'], 1752000000000); // epoch ms, exactly like the web
    key.dispose();
  });

  test('accuracy is omitted when unknown (optional, like the web)', () {
    final key = crypto.generateCircleKey();
    final fix = ShareFix(
      lat: 1,
      lng: 2,
      capturedAt: DateTime.fromMillisecondsSinceEpoch(5, isUtc: true),
    );
    expect(fix.toPayload().containsKey('acc'), isFalse);

    final sealed = codec.seal(fix, key);
    expect(
      codec.open(sealed.nonceB64, sealed.ciphertextB64, key)!.accuracy,
      isNull,
    );
    key.dispose();
  });

  test('a payload that is not a coordinate opens as null', () {
    expect(ShareFix.fromPayload({'lat': 1.0}), isNull); // no lng, no ts
    expect(ShareFix.fromPayload({'lat': 1.0, 'lng': 2.0}), isNull); // no ts
    expect(
      ShareFix.fromPayload({'lat': double.nan, 'lng': 2.0, 'ts': 1}),
      isNull,
    );
    expect(ShareFix.fromPayload({'lat': 1.0, 'lng': 2.0, 'ts': 1}), isNotNull);
  });
}
