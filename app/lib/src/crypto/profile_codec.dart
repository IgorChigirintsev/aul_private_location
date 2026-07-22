import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import 'aul_crypto.dart';

/// Seals/opens a member's per-circle profile (nickname + optional avatar) as a
/// single framed blob under the circle key K_c. The byte layout
/// (nonce||ciphertext, terse JSON, associated data "aul-profile:v1") matches the
/// web `profileCodec`, so a profile set on the web opens on the app and
/// vice-versa. The plaintext is NOT padded (matching web): the avatar dominates
/// the size, so padding would buy nothing while breaking cross-client bytes.
class ProfileCodec {
  ProfileCodec(this._crypto);

  final AulCrypto _crypto;

  /// Domain-separation AD (must match the web profileCodec + the contract) so a
  /// profile ciphertext can't be replayed as a place/SOS or the circle name.
  static final _profileAd = Uint8List.fromList(utf8.encode('aul-profile:v1'));

  /// Seals a profile into the base64 blob the server relays. `nick` is always
  /// present in the JSON (may be an empty string); `avatar` is only added when
  /// set, so a profile with no picture stays small.
  String seal({required String nick, String? avatar, required SecureKey key}) {
    final payload = <String, dynamic>{'nick': nick, 'avatar': ?avatar};
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final framed = _crypto.sealFramed(plain, key, ad: _profileAd);
    return base64.encode(framed);
  }

  /// Opens a profile blob by trying every key in [keyring] (rotation-safe: a
  /// profile sealed under a pre-rotation key still opens once newer keys are
  /// added). Returns null when no key opens it.
  ({String nick, String? avatar})? openWithKeyring(
    String b64,
    List<SecureKey> keyring,
  ) {
    for (final key in keyring) {
      final p = open(b64, key);
      if (p != null) return p;
    }
    return null;
  }

  /// Opens a profile blob under [key]. Never throws: returns null if the input
  /// is malformed, the key is wrong, or the associated data doesn't match.
  ({String nick, String? avatar})? open(String b64, SecureKey key) {
    Uint8List blob;
    try {
      blob = base64.decode(b64);
    } catch (_) {
      return null;
    }
    try {
      final plain = _crypto.openFramed(blob, key, ad: _profileAd);
      final m = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      return (
        nick: (m['nick'] as String?) ?? '',
        avatar: m['avatar'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}
