import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import '../domain/location_fix.dart';
import 'aul_crypto.dart';

/// Turns a [LocationFix] into a sealed ping and back. The plaintext JSON is
/// padded to a fixed block before encryption so the ciphertext length does not
/// leak precision mode or which optional fields are present (a metadata-
/// minimization measure from THREAT_MODEL.md §5).
class PingCodec {
  PingCodec(this._crypto, {this.padBlock = 256});

  final AulCrypto _crypto;
  final int padBlock;

  /// Seals [fix] (already coarsened for its mode) under [circleKey].
  SealedBlob seal(LocationFix fix, SecureKey circleKey) {
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(fix.toPayload())));
    final padded = _crypto.pad(plain, padBlock);
    return _crypto.sealPing(padded, circleKey);
  }

  /// Opens a sealed ping back into a [LocationFix] (for local history/debug).
  LocationFix open(Uint8List nonce, Uint8List ciphertext, SecureKey circleKey) {
    final padded = _crypto.openPing(nonce, ciphertext, circleKey);
    final plain = _crypto.unpad(padded, padBlock);
    final map = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    return LocationFix.fromPayload(map);
  }

  /// Opens a sealed ping by trying every key in [keyring] (rotation-safe: a ping
  /// sealed under a pre-rotation key still opens once newer keys are added).
  /// Returns null when no key opens it — wrong/rotated key, tampering, or a
  /// malformed blob — mirroring the per-ping try/skip in the map + history
  /// pipelines.
  LocationFix? openWithKeyring(
    Uint8List nonce,
    Uint8List ciphertext,
    List<SecureKey> keyring,
  ) {
    for (final key in keyring) {
      try {
        return open(nonce, ciphertext, key);
      } catch (_) {
        // try the next key
      }
    }
    return null;
  }
}
