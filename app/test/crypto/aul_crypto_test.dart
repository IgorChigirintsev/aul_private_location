import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _hex(String h) {
  if (h.isEmpty) return Uint8List(0);
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _toHex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AulCrypto crypto;

  setUpAll(() async {
    crypto = await AulCrypto.load();
  });

  test('ping seal/open round-trips', () {
    final key = crypto.generateCircleKey();
    final msg = Uint8List.fromList(
      utf8.encode('{"lat":1.0,"lng":2.0,"batt":80}'),
    );
    final blob = crypto.sealPing(msg, key);
    expect(blob.nonce.length, crypto.nonceBytes);
    expect(crypto.openPing(blob.nonce, blob.ciphertext, key), msg);
  });

  test('wrong circle key cannot open a ping', () {
    final key = crypto.generateCircleKey();
    final wrong = crypto.generateCircleKey();
    final blob = crypto.sealPing(
      Uint8List.fromList(utf8.encode('secret')),
      key,
    );
    expect(
      () => crypto.openPing(blob.nonce, blob.ciphertext, wrong),
      throwsA(anything),
    );
  });

  test('padding hides payload length then reverses', () {
    final short = Uint8List.fromList(utf8.encode('a'));
    final long = Uint8List.fromList(utf8.encode('a' * 40));
    final ps = crypto.pad(short, 64);
    final pl = crypto.pad(long, 64);
    expect(ps.length, pl.length); // both padded to the same block
    expect(crypto.unpad(ps, 64), short);
  });

  test('X25519 sealed box round-trips (key envelope path)', () {
    final id = crypto.generateIdentityKeyPair();
    final secret = Uint8List.fromList(
      utf8.encode('32-byte-circle-key-material-here'),
    );
    final sealed = crypto.sealToPublicKey(secret, id.publicKey);
    expect(crypto.openSealed(sealed, id), secret);
  });

  test('opens Go crypto_box_seal envelopes (Dart⇄Go key-envelope interop)', () {
    final data =
        json.decode(File('../vectors/crypto-vectors.json').readAsStringSync())
            as Map<String, dynamic>;
    final vectors = (data['crypto_box_seal'] as List)
        .cast<Map<String, dynamic>>();
    expect(vectors, isNotEmpty);
    for (final v in vectors) {
      final id = crypto.identityKeyPairFromBytes(
        _hex(v['recipient_pub_hex'] as String),
        _hex(v['recipient_priv_hex'] as String),
      );
      final opened = crypto.openSealed(_hex(v['sealed_hex'] as String), id);
      expect(
        opened,
        _hex(v['plaintext_hex'] as String),
        reason: 'Dart must open Go crypto_box_seal',
      );
    }
  });

  test('decrypts and reproduces Go XChaCha20 vectors (Dart⇄Go interop)', () {
    final data =
        json.decode(File('../vectors/crypto-vectors.json').readAsStringSync())
            as Map<String, dynamic>;
    final vectors = (data['aead_xchacha20poly1305_ietf'] as List)
        .cast<Map<String, dynamic>>();
    expect(vectors, isNotEmpty);
    final aead = crypto.sodium.crypto.aeadXChaCha20Poly1305IETF;

    for (final v in vectors) {
      final key = crypto.circleKeyFromBytes(_hex(v['key_hex'] as String));
      final nonce = _hex(v['nonce_hex'] as String);
      final ct = _hex(v['ciphertext_hex'] as String);
      final ad = _hex(v['ad_hex'] as String);
      final expected = Uint8List.fromList(
        utf8.encode(v['plaintext_utf8'] as String),
      );

      // 1) Dart decrypts Go's ciphertext.
      final opened = aead.decrypt(
        cipherText: ct,
        nonce: nonce,
        key: key,
        additionalData: ad.isEmpty ? null : ad,
      );
      expect(opened, expected, reason: 'decrypt mismatch');

      // 2) Dart re-encrypts to byte-identical ciphertext.
      final reCt = aead.encrypt(
        message: expected,
        nonce: nonce,
        key: key,
        additionalData: ad.isEmpty ? null : ad,
      );
      expect(reCt, ct, reason: 'encrypt mismatch');
    }
  });

  test('reproduces Go place padding + framing (place_framed, Dart⇄Go)', () {
    final data =
        json.decode(File('../vectors/crypto-vectors.json').readAsStringSync())
            as Map<String, dynamic>;
    final vectors = (data['place_framed'] as List).cast<Map<String, dynamic>>();
    expect(vectors, isNotEmpty);

    for (final v in vectors) {
      final key = crypto.circleKeyFromBytes(_hex(v['key_hex'] as String));
      final ad = Uint8List.fromList(utf8.encode(v['ad_utf8'] as String));
      final plain = Uint8List.fromList(
        utf8.encode(v['plaintext_utf8'] as String),
      );
      final block = v['block'] as int;

      // pad() must be byte-identical to Go's sodium_pad.
      expect(
        _toHex(crypto.pad(plain, block)),
        v['padded_hex'],
        reason: 'padding mismatch',
      );

      // Open Go's framed blob (nonce||ciphertext) with the domain AD and unpad.
      final framed = _hex(v['framed_hex'] as String);
      final opened = crypto.unpad(
        crypto.openFramed(framed, key, ad: ad),
        block,
      );
      expect(
        utf8.decode(opened),
        v['plaintext_utf8'],
        reason: 'framing mismatch',
      );

      // Wrong AD must NOT open it (domain separation).
      expect(
        () => crypto.openFramed(
          framed,
          key,
          ad: Uint8List.fromList(utf8.encode('aul-sos:v1')),
        ),
        throwsA(anything),
      );
    }
  });
}
