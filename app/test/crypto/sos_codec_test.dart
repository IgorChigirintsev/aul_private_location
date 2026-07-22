import 'dart:convert';
import 'dart:typed_data';

import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:aul/src/crypto/place_codec.dart';
import 'package:aul/src/crypto/sos_codec.dart';
import 'package:aul/src/data/api/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AulCrypto crypto;
  late SosCodec codec;
  setUpAll(() async {
    crypto = await AulCrypto.load();
    codec = SosCodec(crypto);
  });

  RemoteSos dtoWith(String ciphertextB64, {String id = 'sos1'}) => RemoteSos(
    id: id,
    circleId: 'c1',
    ciphertextB64: ciphertextB64,
    createdAt: DateTime.utc(2026, 7, 14, 9),
    deviceId: 'devA',
  );

  test('round-trips a sealed SOS (message + location + ts) under K_c', () {
    final key = crypto.generateCircleKey();
    final ct = codec.seal(
      key: key,
      message: '  help  ',
      lat: 43.238,
      lng: 76.889,
      ts: 1234,
    );

    final alert = codec.open(dtoWith(ct), [key]);
    expect(alert.decrypted, isTrue);
    expect(alert.message, 'help'); // trimmed
    expect(alert.lat, closeTo(43.238, 1e-9));
    expect(alert.lng, closeTo(76.889, 1e-9));
    expect(alert.hasLocation, isTrue);
    expect(alert.ts, 1234);
    // Metadata is always carried through from the DTO.
    expect(alert.id, 'sos1');
    expect(alert.deviceId, 'devA');
    expect(alert.createdAt, DateTime.utc(2026, 7, 14, 9));
  });

  test('a message-only SOS decrypts with no location', () {
    final key = crypto.generateCircleKey();
    final alert = codec.open(dtoWith(codec.seal(key: key, message: 'sos')), [
      key,
    ]);
    expect(alert.decrypted, isTrue);
    expect(alert.message, 'sos');
    expect(alert.hasLocation, isFalse);
    expect(alert.lat, isNull);
  });

  test('an undecryptable SOS still surfaces from metadata (wrong key)', () {
    final key = crypto.generateCircleKey();
    final wrongKey = crypto.generateCircleKey();
    final ct = codec.seal(key: key, message: 'secret');

    final alert = codec.open(dtoWith(ct), [wrongKey]);
    expect(alert.decrypted, isFalse); // no emergency is missed
    expect(alert.message, isNull);
    expect(alert.hasLocation, isFalse);
    // …but the alert is still present with its metadata.
    expect(alert.id, 'sos1');
    expect(alert.deviceId, 'devA');
    expect(alert.createdAt, DateTime.utc(2026, 7, 14, 9));
  });

  test('an empty keyring (no key on device) still surfaces the alert', () {
    final key = crypto.generateCircleKey();
    final alert = codec.open(dtoWith(codec.seal(key: key, message: 'x')), []);
    expect(alert.decrypted, isFalse);
    expect(alert.id, 'sos1');
  });

  test('malformed base64 ciphertext still surfaces from metadata', () {
    final key = crypto.generateCircleKey();
    final alert = codec.open(dtoWith('not-base64-!!'), [key]);
    expect(alert.decrypted, isFalse);
    expect(alert.id, 'sos1');
  });

  test('rotation-safe: opens with a later key in the ring', () {
    final oldKey = crypto.generateCircleKey();
    final newKey = crypto.generateCircleKey();
    final ct = codec.seal(key: oldKey, message: 'old-epoch');

    // The current key is first; the (rotated-out) key that sealed it is second.
    final alert = codec.open(dtoWith(ct), [newKey, oldKey]);
    expect(alert.decrypted, isTrue);
    expect(alert.message, 'old-epoch');
  });

  test('domain separation: a place blob does not open as an SOS', () {
    final key = crypto.generateCircleKey();
    // Seal a place (AD "aul-place:v1") and try to open it as an SOS.
    final placeCt = PlaceCodec(
      crypto,
    ).seal(name: 'Home', lat: 1, lng: 2, radius: 100, key: key);
    final alert = codec.open(dtoWith(placeCt), [key]);
    expect(alert.decrypted, isFalse); // wrong AD ⇒ won't open
  });

  test('cross-client: opens a web-shaped SOS payload (lat/lng/msg/ts)', () {
    // Mirror the web sealSos byte format directly (framed+padded, AD aul-sos:v1)
    // to prove an SOS raised on the web opens on the app.
    final key = crypto.generateCircleKey();
    final payload = <String, dynamic>{
      'lat': 51.5,
      'lng': -0.12,
      'msg': 'from web',
      'ts': 9999,
    };
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final framed = crypto.sealFramed(
      crypto.pad(plain, 256),
      key,
      ad: Uint8List.fromList(utf8.encode('aul-sos:v1')),
    );
    final alert = codec.open(dtoWith(base64.encode(framed)), [key]);
    expect(alert.decrypted, isTrue);
    expect(alert.lat, closeTo(51.5, 1e-9));
    expect(alert.lng, closeTo(-0.12, 1e-9));
    expect(alert.message, 'from web');
    expect(alert.ts, 9999);
  });
}
