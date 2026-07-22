import 'dart:convert';
import 'dart:typed_data';

import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:aul/src/crypto/notify_codec.dart';
import 'package:aul/src/crypto/place_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';

/// Cross-client vectors, produced by the WEB's own libsodium build
/// (web/node_modules/libsodium-wrappers) running web/src/data/notifyCodec.ts's
/// sealNotify byte for byte — JSON.stringify({t, place, who, ts}) sealed with
/// sealFramed(plain, K_c, utf8("aul-notify:v1")), base64 of nonce||ciphertext.
/// The nonce is pinned to 0x2a*24 so the blob is reproducible; everything else
/// is exactly what the dashboard puts on the wire.
///
/// If the app stops opening these, the phones stop announcing arrivals to the
/// browsers — which is the entire point of the /notify relay.
class _WebVector {
  const _WebVector({
    required this.payloadEncB64,
    required this.json,
    required this.kind,
    required this.place,
    required this.who,
    required this.ts,
  });

  final String payloadEncB64;

  /// The exact plaintext the web sealed — the shape the app must reproduce.
  final String json;
  final NotifyKind kind;
  final String place;
  final String who;
  final int ts;
}

/// K_c = 0x11 * 32, the key the vectors were sealed under.
final _vectorKey = Uint8List.fromList(List.filled(32, 0x11));

const _vectors = <_WebVector>[
  _WebVector(
    payloadEncB64:
        'KioqKioqKioqKioqKioqKioqKioqKioqKqFF/WRrRi/de7WeNHLPk7GrZajghlwW37xx'
        'ccQ5lAPasNy7Bz6m6XMOXbJJJ+P1pk0pHkXw+F4sIvPkJ1UAQYbu6vRDm6/3w/SX/mKr'
        'LA==',
    json: '{"t":"arrival","place":"Home","who":"Aisha","ts":1750000000000}',
    kind: NotifyKind.arrival,
    place: 'Home',
    who: 'Aisha',
    ts: 1750000000000,
  ),
  // Non-ASCII place + an emoji nickname: UTF-8 all the way through, and the
  // surrogate pair must survive both ends.
  _WebVector(
    payloadEncB64:
        'KioqKioqKioqKioqKioqKioqKioqKioqKqFF/WRrQzjfc7GLLSKGk+3ldKfkxwMWrfHM'
        'vDavZspiZC4xB1Pt7XMAXaRJgwAHJa2W+8XgOPGNteH4NREO3esDf+AdB7La/MJ9iqnT'
        'XI0nJ5tQHuMFKVapYl1O4Vg=',
    json:
        '{"t":"departure","place":"Школа","who":"Айша 👧","ts":1750000123456}',
    kind: NotifyKind.departure,
    place: 'Школа',
    who: 'Айша 👧',
    ts: 1750000123456,
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AulCrypto crypto;
  late NotifyCodec codec;

  setUpAll(() async {
    crypto = await AulCrypto.load();
    codec = NotifyCodec(crypto);
  });

  NotifyPayload payload({
    NotifyKind kind = NotifyKind.arrival,
    String place = 'Home',
    String who = 'Aisha',
    int ts = 1750000000000,
  }) => NotifyPayload(kind: kind, place: place, who: who, ts: ts);

  group('round-trip', () {
    test('seals and opens under the same key', () {
      final key = crypto.generateCircleKey();
      final opened = codec.open(codec.seal(payload(), key), [key]);
      expect(opened, isNotNull);
      expect(opened!.kind, NotifyKind.arrival);
      expect(opened.place, 'Home');
      expect(opened.who, 'Aisha');
      expect(opened.ts, 1750000000000);
    });

    test('a departure survives the round-trip as a departure', () {
      final key = crypto.generateCircleKey();
      final sealed = codec.seal(payload(kind: NotifyKind.departure), key);
      expect(codec.open(sealed, [key])?.kind, NotifyKind.departure);
    });

    test('opens with a rotated keyring (the push carries no key epoch)', () {
      final old = crypto.generateCircleKey();
      final fresh = crypto.generateCircleKey();
      final sealed = codec.seal(payload(), old);
      // Sealed under the pre-rotation key; the whole ring is tried.
      expect(codec.open(sealed, [old, fresh]), isNotNull);
      expect(codec.open(sealed, [fresh]), isNull); // wrong key only ⇒ nothing
    });

    test('a wrong key, a corrupt blob, and junk base64 all open to null', () {
      final key = crypto.generateCircleKey();
      final other = crypto.generateCircleKey();
      final sealed = codec.seal(payload(), key);
      expect(codec.open(sealed, [other]), isNull);
      expect(codec.open(sealed, const []), isNull); // no keys at all
      expect(codec.open('not base64 !!!', [key]), isNull);
      // Flip a ciphertext byte: the Poly1305 tag must reject it.
      final bytes = base64.decode(sealed);
      bytes[bytes.length - 1] ^= 0xFF;
      expect(codec.open(base64.encode(bytes), [key]), isNull);
    });
  });

  group('domain separation', () {
    test('a place blob cannot be opened as a notify (and vice-versa)', () {
      final key = crypto.generateCircleKey();
      final placeCt = PlaceCodec(
        crypto,
      ).seal(name: 'Home', lat: 43.2, lng: 76.8, radius: 100, key: key);
      // "aul-place:v1" ≠ "aul-notify:v1": the AEAD tag fails closed.
      expect(codec.open(placeCt, [key]), isNull);

      final notifyCt = codec.seal(payload(), key);
      expect(
        PlaceCodec(
          crypto,
        ).open(id: 'p', version: 1, ciphertextB64: notifyCt, keyring: [key]),
        isNull,
      );
    });

    test('the AD is exactly utf8("aul-notify:v1")', () {
      final key = crypto.generateCircleKey();
      final blob = base64.decode(codec.seal(payload(), key));
      final ad = Uint8List.fromList(utf8.encode('aul-notify:v1'));
      // Opening by hand with that AD must work — and must not with any other.
      expect(() => crypto.openFramed(blob, key, ad: ad), returnsNormally);
      expect(
        () => crypto.openFramed(
          blob,
          key,
          ad: Uint8List.fromList(utf8.encode('aul-place:v1')),
        ),
        throwsA(anything),
      );
    });
  });

  group('field clamping (the payload budget)', () {
    test('long free text is clamped to 64 code points', () {
      final key = crypto.generateCircleKey();
      final opened = codec.open(
        codec.seal(payload(place: 'A' * 200, who: 'B' * 200), key),
        [key],
      );
      expect(opened!.place.length, NotifyCodec.maxFieldChars);
      expect(opened.who.length, NotifyCodec.maxFieldChars);
    });

    test('clamping never splits an emoji into a lone surrogate half', () {
      // 100 emoji: 100 code points but 200 UTF-16 units. Clamping by code point
      // keeps whole emoji — a lone half would render as a replacement char.
      final nick = '👧' * 100;
      final clamped = NotifyCodec.clamp(nick);
      expect(clamped.runes.length, NotifyCodec.maxFieldChars);
      expect(clamped, '👧' * NotifyCodec.maxFieldChars);
    });

    test('a pathological nickname still fits the server ceiling', () {
      final key = crypto.generateCircleKey();
      final sealed = codec.seal(
        payload(place: '👧' * 5000, who: 'x' * 50000),
        key,
      );
      expect(
        base64.decode(sealed).length,
        lessThan(NotifyCodec.maxNotifyBytes),
      );
    });

    test('normal names pass through untouched', () {
      expect(NotifyCodec.clamp('Aisha'), 'Aisha');
      expect(NotifyCodec.clamp("Mom's house"), "Mom's house");
    });
  });

  group('cross-client vectors (sealed by the web, opened by the app)', () {
    test('every web-sealed blob opens to the right payload', () {
      final key = crypto.circleKeyFromBytes(_vectorKey);
      for (final v in _vectors) {
        final opened = codec.open(v.payloadEncB64.replaceAll('\n', ''), [key]);
        expect(
          opened,
          isNotNull,
          reason: 'web vector failed to open: ${v.json}',
        );
        expect(opened!.kind, v.kind);
        expect(opened.place, v.place);
        expect(opened.who, v.who);
        expect(opened.ts, v.ts);
      }
    });

    test('the app seals the web\'s exact plaintext shape', () {
      final key = crypto.circleKeyFromBytes(_vectorKey);
      final ad = Uint8List.fromList(utf8.encode('aul-notify:v1'));
      for (final v in _vectors) {
        final blob = base64.decode(
          codec.seal(
            NotifyPayload(kind: v.kind, place: v.place, who: v.who, ts: v.ts),
            key,
          ),
        );
        // Byte-for-byte the JSON the web's service worker will JSON.parse:
        // same keys, same order, same UTF-8.
        expect(utf8.decode(crypto.openFramed(blob, key, ad: ad)), v.json);
      }
    });

    test('the framing is nonce(24) || ciphertext, with NO padding', () {
      // The web does not pad notify payloads (unlike places/SOS). A padded blob
      // would decrypt fine and then fail to JSON.parse on the other side — the
      // exact interop trap this pins shut.
      final key = crypto.circleKeyFromBytes(_vectorKey);
      final v = _vectors.first;
      final blob = base64.decode(
        codec.seal(
          NotifyPayload(kind: v.kind, place: v.place, who: v.who, ts: v.ts),
          key,
        ),
      );
      expect(blob.length, crypto.nonceBytes + utf8.encode(v.json).length + 16);
      // And the web's own blob has that same shape.
      expect(
        base64.decode(v.payloadEncB64.replaceAll('\n', '')).length,
        blob.length,
      );
    });
  });

  test('the sealed blob stays well under the server\'s 3 KiB ceiling', () {
    final SecureKey key = crypto.generateCircleKey();
    final sealed = codec.seal(payload(place: "Mom's house", who: 'Aisha'), key);
    expect(base64.decode(sealed).length, lessThan(NotifyCodec.maxNotifyBytes));
  });
}
