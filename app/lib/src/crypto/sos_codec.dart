import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import '../data/api/models.dart';
import '../domain/sos_alert.dart';
import 'aul_crypto.dart';

/// Seals/opens SOS alerts as a single framed+padded blob under the circle key
/// K_c. This is the ONE source of truth for the SOS wire format on the app: the
/// raise-SOS action and the SOS centre both go through it.
///
/// The byte layout matches the web `placeCodec` (web/src/data/placeCodec.ts →
/// sealSos/openSos) exactly, so an SOS raised on the web opens on the app and
/// vice-versa:
///
///  * plaintext  = terse JSON `{"lat":..,"lng":..,"msg":..,"ts":..}` (lat/lng/msg
///                 optional; ts always present, epoch ms)
///  * padded     = libsodium ISO/IEC 7816-4 padding to a 256-byte block (hides
///                 the message length), BEFORE sealing
///  * framed     = nonce(24) || XChaCha20-Poly1305-IETF ciphertext
///  * ad         = utf8("aul-sos:v1") — domain separation, so a place blob can
///                 never be opened as an SOS (or vice-versa)
///  * ciphertext = base64(framed) — the single opaque column the server stores.
class SosCodec {
  SosCodec(this._crypto, {this.padBlock = 256});

  final AulCrypto _crypto;
  final int padBlock;

  /// Domain-separation AD (must match the web sealSos/openSos) so an SOS
  /// ciphertext can't be replayed as a place or the circle name.
  static final _sosAd = Uint8List.fromList(utf8.encode('aul-sos:v1'));

  /// Seals an SOS payload into the base64 ciphertext the server stores opaquely.
  /// [message] is trimmed and omitted when blank; [lat]/[lng] are included only
  /// when both are present; [ts] defaults to now (epoch ms).
  String seal({
    required SecureKey key,
    String? message,
    double? lat,
    double? lng,
    int? ts,
  }) {
    final msg = message?.trim();
    final payload = <String, dynamic>{
      if (lat != null && lng != null) 'lat': lat,
      if (lat != null && lng != null) 'lng': lng,
      if (msg != null && msg.isNotEmpty) 'msg': msg,
      'ts': ts ?? DateTime.now().millisecondsSinceEpoch,
    };
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final framed = _crypto.sealFramed(
      _crypto.pad(plain, padBlock),
      key,
      ad: _sosAd,
    );
    return base64.encode(framed);
  }

  /// Opens a [RemoteSos] with [keyring] (rotation-safe — an alert sealed under an
  /// old key still opens). If no key opens it — wrong/rotated key, wrong AD, or
  /// malformed blob — the alert is STILL returned from server metadata with
  /// `decrypted: false`, so a watcher never misses an emergency. Mirrors the web
  /// `openSos`.
  SosAlert open(RemoteSos dto, List<SecureKey> keyring) {
    final meta = SosAlert(
      id: dto.id,
      createdAt: dto.createdAt,
      deviceId: dto.deviceId,
    );
    Uint8List blob;
    try {
      blob = base64.decode(dto.ciphertextB64);
    } catch (_) {
      return meta; // malformed ciphertext — still surface the alert from metadata
    }
    for (final key in keyring) {
      try {
        final plain = _crypto.unpad(
          _crypto.openFramed(blob, key, ad: _sosAd),
          padBlock,
        );
        final m = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
        return SosAlert(
          id: dto.id,
          createdAt: dto.createdAt,
          deviceId: dto.deviceId,
          lat: (m['lat'] as num?)?.toDouble(),
          lng: (m['lng'] as num?)?.toDouble(),
          message: m['msg'] as String?,
          ts: (m['ts'] as num?)?.toInt(),
          decrypted: true,
        );
      } catch (_) {
        // try the next key
      }
    }
    return meta;
  }
}
