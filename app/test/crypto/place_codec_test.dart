import 'dart:convert';
import 'dart:typed_data';

import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:aul/src/crypto/place_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AulCrypto crypto;
  late PlaceCodec codec;

  setUpAll(() async {
    crypto = await AulCrypto.load();
    codec = PlaceCodec(crypto);
  });

  test('sealFramed/openFramed round-trips (nonce || ciphertext)', () {
    final key = crypto.generateCircleKey();
    final msg = Uint8List.fromList([1, 2, 3, 4, 5]);
    final framed = crypto.sealFramed(msg, key);
    // nonce (24) + ciphertext (plaintext + 16-byte Poly1305 tag).
    expect(framed.length, crypto.nonceBytes + msg.length + 16);
    expect(crypto.openFramed(framed, key), msg);
  });

  test('place seal/open round-trips under the same key', () {
    final key = crypto.generateCircleKey();
    final ct = codec.seal(
      name: "Mom's house",
      lat: 43.238949,
      lng: 76.889709,
      radius: 150,
      key: key,
    );
    final place = codec.open(
      id: 'p1',
      version: 1,
      ciphertextB64: ct,
      keyring: [key],
    );
    expect(place, isNotNull);
    expect(place!.name, "Mom's house");
    expect(place.radius, 150);
    expect(place.lat, closeTo(43.238949, 1e-9));
    expect(place.lng, closeTo(76.889709, 1e-9));
  });

  test(
    'padding hides name length: short vs long name → equal ciphertext size',
    () {
      final key = crypto.generateCircleKey();
      final a = codec.seal(name: 'Gym', lat: 1, lng: 2, radius: 100, key: key);
      final b = codec.seal(
        name: 'A very long place name indeed',
        lat: 1,
        lng: 2,
        radius: 100,
        key: key,
      );
      expect(a.length, b.length);
    },
  );

  test('wrong AD → null (a place blob can\'t be opened as another type)', () {
    final key = crypto.generateCircleKey();
    // Seal the SAME padded place JSON but under the SOS domain-separation AD.
    // PlaceCodec.open must refuse it (openFramed auth fails on the AD mismatch),
    // returning null — mirroring the web openPlace, so a place ciphertext can
    // never be replayed as an SOS or vice-versa.
    final payload = utf8.encode('{"n":"X","lat":1.0,"lng":2.0,"rad":100.0}');
    final framed = crypto.sealFramed(
      crypto.pad(Uint8List.fromList(payload), 256),
      key,
      ad: Uint8List.fromList(utf8.encode('aul-sos:v1')),
    );
    final ct = base64.encode(framed);
    expect(
      codec.open(id: 'p', version: 1, ciphertextB64: ct, keyring: [key]),
      isNull,
    );
  });

  test('malformed ciphertext → null (no throw)', () {
    final key = crypto.generateCircleKey();
    expect(
      codec.open(
        id: 'p',
        version: 1,
        ciphertextB64: 'not valid base64!!',
        keyring: [key],
      ),
      isNull,
    );
  });

  test('wrong key → null; keyring tries every key (rotation-safe)', () {
    final oldKey = crypto.generateCircleKey();
    final newKey = crypto.generateCircleKey();
    final ct = codec.seal(
      name: 'School',
      lat: 5,
      lng: 6,
      radius: 200,
      key: oldKey,
    );
    expect(
      codec.open(id: 'p', version: 1, ciphertextB64: ct, keyring: [newKey]),
      isNull,
    );
    expect(
      codec
          .open(
            id: 'p',
            version: 2,
            ciphertextB64: ct,
            keyring: [newKey, oldKey],
          )
          ?.name,
      'School',
    );
  });
}
