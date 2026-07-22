import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import '../domain/place.dart';
import 'aul_crypto.dart';

/// Seals/opens places as a single framed+padded blob under the circle key K_c.
/// This is the ONE source of truth for the place wire format on the app: the
/// foreground geofence loader, the places view, and the editor all go through it.
///
/// The byte layout matches the web `placeCodec` (web/src/data/placeCodec.ts) and
/// the pinned cross-language vector (vectors/crypto-vectors.json → `place_framed`)
/// exactly, so a place created on the web opens on the app and vice-versa:
///
///  * plaintext  = terse JSON `{"n":name,"lat":lat,"lng":lng,"rad":radius}`
///  * padded     = libsodium ISO/IEC 7816-4 padding to a 256-byte block (hides
///                 the name length), BEFORE sealing
///  * framed     = nonce(24) || XChaCha20-Poly1305-IETF ciphertext
///  * ad         = utf8("aul-place:v1") — domain separation, so a place blob can
///                 never be opened as an SOS ("aul-sos:v1") or the circle name.
///  * ciphertext = base64(framed) — the single opaque column the server stores.
class PlaceCodec {
  PlaceCodec(this._crypto, {this.padBlock = 256});

  final AulCrypto _crypto;
  final int padBlock;

  /// Domain-separation AD (must match the web placeCodec) so a place ciphertext
  /// can't be replayed as an SOS or the circle name.
  static final _placeAd = Uint8List.fromList(utf8.encode('aul-place:v1'));

  /// Seals a place into the base64 ciphertext the server stores opaquely.
  String seal({
    required String name,
    required double lat,
    required double lng,
    required double radius,
    required SecureKey key,
  }) {
    final payload = <String, dynamic>{
      'n': name,
      'lat': lat,
      'lng': lng,
      'rad': radius,
    };
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final framed = _crypto.sealFramed(
      _crypto.pad(plain, padBlock),
      key,
      ad: _placeAd,
    );
    return base64.encode(framed);
  }

  /// Opens a place ciphertext, trying every key in [keyring] (rotation-safe).
  /// Returns null if no key opens it (wrong key, wrong AD, or malformed blob) —
  /// mirroring the web `openPlace`, which returns null rather than throwing.
  ///
  /// [createdBy] rides along untouched: it is server metadata, never part of the
  /// sealed blob, so it needs no key — the NAME is what stays E2EE.
  Place? open({
    required String id,
    required int version,
    required String ciphertextB64,
    required List<SecureKey> keyring,
    String? createdBy,
  }) {
    final Uint8List blob;
    try {
      blob = base64.decode(ciphertextB64);
    } catch (_) {
      return null;
    }
    for (final key in keyring) {
      try {
        final plain = _crypto.unpad(
          _crypto.openFramed(blob, key, ad: _placeAd),
          padBlock,
        );
        final m = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
        return Place(
          id: id,
          version: version,
          name: m['n'] as String,
          lat: (m['lat'] as num).toDouble(),
          lng: (m['lng'] as num).toDouble(),
          radius: (m['rad'] as num).toDouble(),
          createdBy: createdBy,
        );
      } catch (_) {
        // try the next key
      }
    }
    return null;
  }
}
