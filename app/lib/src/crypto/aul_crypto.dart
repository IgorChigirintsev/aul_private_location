import 'dart:typed_data';

import 'package:sodium/sodium.dart';

/// SealedBlob is a nonce + ciphertext pair produced by [AulCrypto.sealPing].
class SealedBlob {
  const SealedBlob(this.nonce, this.ciphertext);
  final Uint8List nonce;
  final Uint8List ciphertext;
}

/// AulCrypto wraps libsodium (via the `sodium` package) with exactly the
/// primitives Aul needs. Everything here is real libsodium — no hand-rolled
/// crypto, no stubs:
///
///  * X25519 identity keypair               — crypto_box keypair
///  * circle key K_c                         — 32 random bytes (XChaCha20 key)
///  * ping/place sealing                     — XChaCha20-Poly1305-IETF
///  * sealed key envelopes (Phase 4)         — crypto_box_seal
///
/// The private identity key never leaves the device; K_c never touches the
/// server. Cross-language interop with Go/JS is pinned by
/// /vectors/crypto-vectors.json.
class AulCrypto {
  AulCrypto(this.sodium);

  final Sodium sodium;

  /// Loads libsodium. On mobile the native lib is bundled; on desktop/test it
  /// is provided by the native-assets build hook.
  static Future<AulCrypto> load() async => AulCrypto(await SodiumInit.init());

  Aead get _aead => sodium.crypto.aeadXChaCha20Poly1305IETF;

  /// Circle-key length in bytes (32).
  int get circleKeyBytes => _aead.keyBytes;

  /// XChaCha20 nonce length in bytes (24).
  int get nonceBytes => _aead.nonceBytes;

  // --- identity keys (X25519) ---

  /// Generates a fresh X25519 identity keypair. The secret key is a [SecureKey]
  /// (mlocked); persist only its bytes to secure storage.
  KeyPair generateIdentityKeyPair() => sodium.crypto.box.keyPair();

  /// Reconstructs an identity keypair from stored bytes.
  KeyPair identityKeyPairFromBytes(Uint8List publicKey, Uint8List secretKey) =>
      KeyPair(publicKey: publicKey, secretKey: sodium.secureCopy(secretKey));

  // --- circle key K_c ---

  /// Generates a new random circle key (owner, at circle creation).
  SecureKey generateCircleKey() => sodium.secureRandom(circleKeyBytes);

  /// Imports a circle key from raw bytes (e.g. from the invite-link fragment).
  SecureKey circleKeyFromBytes(Uint8List raw) {
    if (raw.length != circleKeyBytes) {
      throw ArgumentError('circle key must be $circleKeyBytes bytes');
    }
    return sodium.secureCopy(raw);
  }

  // --- ping / place sealing (XChaCha20-Poly1305-IETF) ---

  /// Seals [plaintext] under [key] with a fresh random nonce.
  SealedBlob sealPing(Uint8List plaintext, SecureKey key) {
    final nonce = sodium.randombytes.buf(nonceBytes);
    final ct = _aead.encrypt(message: plaintext, nonce: nonce, key: key);
    return SealedBlob(nonce, ct);
  }

  /// Opens a sealed ping. Throws on authentication failure (tampering/wrong key).
  Uint8List openPing(Uint8List nonce, Uint8List ciphertext, SecureKey key) =>
      _aead.decrypt(cipherText: ciphertext, nonce: nonce, key: key);

  /// Seals [plaintext] into a self-framed blob (nonce || ciphertext) for
  /// single-blob fields — places, SOS, the circle name — whose server column is
  /// one opaque ciphertext with no separate nonce. Byte-for-byte compatible with
  /// the web `sealFramed` (nonce is the first [nonceBytes] bytes). The optional
  /// [ad] gives domain separation (e.g. "aul-place:v1" vs "aul-sos:v1") so a
  /// ciphertext of one type cannot be opened as another; null = circle-name form.
  Uint8List sealFramed(Uint8List plaintext, SecureKey key, {Uint8List? ad}) {
    final nonce = sodium.randombytes.buf(nonceBytes);
    final ct = _aead.encrypt(
      message: plaintext,
      nonce: nonce,
      key: key,
      additionalData: ad,
    );
    final out = Uint8List(nonce.length + ct.length);
    out.setRange(0, nonce.length, nonce);
    out.setRange(nonce.length, out.length, ct);
    return out;
  }

  /// Opens a self-framed blob produced by [sealFramed]; [ad] must match.
  Uint8List openFramed(Uint8List framed, SecureKey key, {Uint8List? ad}) {
    final nonce = Uint8List.sublistView(framed, 0, nonceBytes);
    final ct = Uint8List.sublistView(framed, nonceBytes);
    return _aead.decrypt(
      cipherText: ct,
      nonce: nonce,
      key: key,
      additionalData: ad,
    );
  }

  /// Pads [buf] up to a multiple of [blockSize] (libsodium ISO/IEC 7816-4
  /// padding) so ciphertext length does not leak payload contents.
  Uint8List pad(Uint8List buf, int blockSize) => sodium.pad(buf, blockSize);

  /// Reverses [pad].
  Uint8List unpad(Uint8List buf, int blockSize) => sodium.unpad(buf, blockSize);

  // --- sealed key envelopes (crypto_box_seal) — used from Phase 4 ---

  /// Anonymously seals [message] to a recipient's X25519 public key.
  Uint8List sealToPublicKey(Uint8List message, Uint8List recipientPublicKey) =>
      sodium.crypto.box.seal(message: message, publicKey: recipientPublicKey);

  /// Opens a sealed box addressed to [identity].
  Uint8List openSealed(Uint8List cipher, KeyPair identity) =>
      sodium.crypto.box.sealOpen(
        cipherText: cipher,
        publicKey: identity.publicKey,
        secretKey: identity.secretKey,
      );
}
