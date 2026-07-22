import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import 'aul_crypto.dart';

/// A live-share position: a point and nothing else.
///
/// Deliberately narrower than [LocationFix] — no battery, no speed/heading, no
/// precision mode. A stranger holding a share link gets where you are, for as
/// long as the link lives, and not one field more. Mirrors the web `ShareFix`.
class ShareFix {
  const ShareFix({
    required this.lat,
    required this.lng,
    required this.capturedAt,
    this.accuracy,
  });

  final double lat;
  final double lng;
  final double? accuracy; // metres

  final DateTime capturedAt;

  /// The exact JSON that is sealed. Byte-for-byte the web's payload
  /// (`{lat, lng, acc?, ts}`, `ts` in epoch milliseconds), so a link made by
  /// this app opens in the web viewer and vice versa.
  Map<String, dynamic> toPayload() => {
    'lat': lat,
    'lng': lng,
    if (accuracy != null) 'acc': accuracy,
    'ts': capturedAt.toUtc().millisecondsSinceEpoch,
  };

  static ShareFix? fromPayload(Map<String, dynamic> p) {
    final lat = (p['lat'] as num?)?.toDouble();
    final lng = (p['lng'] as num?)?.toDouble();
    final ts = (p['ts'] as num?)?.toInt();
    // Fail closed on anything that isn't a coordinate: a partial result here
    // would put a wrong dot on a stranger's map.
    if (lat == null || lng == null || ts == null) return null;
    if (!lat.isFinite || !lng.isFinite) return null;
    return ShareFix(
      lat: lat,
      lng: lng,
      accuracy: (p['acc'] as num?)?.toDouble(),
      capturedAt: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
    );
  }
}

/// Seals a live-share position under K_share and opens it again.
///
/// K_share is a per-session key that exists ONLY in the sharer's device and the
/// link's fragment — never the circle key, and never sent to the server. The
/// wire layout is byte-for-byte the circle ping codec's (pad → XChaCha20-
/// Poly1305 → base64), just under a different key, so the server sees the same
/// opaque shape it always does and cannot tell a share from a ping.
class ShareCodec {
  ShareCodec(this._crypto, {this.padBlock = 256});

  final AulCrypto _crypto;

  /// Same 256-byte block as the ping codec: every sealed position is one
  /// fixed-size blob, so its length leaks nothing about the coordinates.
  final int padBlock;

  /// Seals [fix] under [shareKey], returning the base64 `nonce`/`ciphertext`
  /// pair the server stores verbatim.
  ({String nonceB64, String ciphertextB64}) seal(
    ShareFix fix,
    SecureKey shareKey,
  ) {
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(fix.toPayload())));
    final blob = _crypto.sealPing(_crypto.pad(plain, padBlock), shareKey);
    return (
      nonceB64: base64.encode(blob.nonce),
      ciphertextB64: base64.encode(blob.ciphertext),
    );
  }

  /// Opens a sealed position with K_share. Returns null — never a partial
  /// result — for a wrong key, a corrupt blob, or a payload that isn't a
  /// coordinate: the AEAD tag fails closed, so the wrong key learns nothing.
  ShareFix? open(String nonceB64, String ciphertextB64, SecureKey shareKey) {
    try {
      final padded = _crypto.openPing(
        base64.decode(nonceB64),
        base64.decode(ciphertextB64),
        shareKey,
      );
      final plain = _crypto.unpad(padded, padBlock);
      final map = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      return ShareFix.fromPayload(map);
    } catch (_) {
      return null;
    }
  }
}
