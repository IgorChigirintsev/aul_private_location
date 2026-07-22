import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import 'aul_crypto.dart';

/// What happened at a place. The wire values ('arrival' / 'departure') are the
/// web's, byte-for-byte — the receiving service worker switches on them.
enum NotifyKind {
  arrival('arrival'),
  departure('departure');

  const NotifyKind(this.wire);
  final String wire;

  static NotifyKind? fromWire(String s) {
    for (final k in NotifyKind.values) {
      if (k.wire == s) return k;
    }
    return null;
  }
}

/// The plaintext of a background notification. Terse and small on purpose: the
/// sealed blob is relayed by the server as the opaque Web Push payload, so every
/// byte counts against [NotifyCodec.maxNotifyBytes].
class NotifyPayload {
  const NotifyPayload({
    required this.kind,
    required this.place,
    required this.who,
    required this.ts,
  });

  /// What happened.
  final NotifyKind kind;

  /// The place name — plaintext here, sealed on the wire; the server never sees
  /// it.
  final String place;

  /// The mover's nickname in that circle, falling back to their email.
  final String who;

  /// Epoch ms of the transition.
  final int ts;
}

/// Seals/opens the background-notification payload under the circle key K_c.
///
/// The byte layout matches the web `notifyCodec` (web/src/data/notifyCodec.ts)
/// exactly — the dashboard's service worker opens what this app seals, and this
/// app opens what the dashboard seals:
///
///  * plaintext  = terse JSON `{"t":..,"place":..,"who":..,"ts":..}`, in THAT
///                 key order
///  * framed     = nonce(24) || XChaCha20-Poly1305-IETF ciphertext
///  * ad         = utf8("aul-notify:v1") — domain separation, so a notify blob
///                 can never be opened as a place ("aul-place:v1") or an SOS
///  * payload_enc = base64(framed) — the opaque blob the server relays verbatim
///
/// NOTE the one deviation from the place/SOS codecs: the plaintext is NOT padded
/// to a block. The web doesn't pad here either, and both ends must agree — a
/// padded blob would simply fail to parse as JSON on the other side. What length
/// leaks is the length of a place name, to a server that already sees the
/// notification's timing and circle.
class NotifyCodec {
  NotifyCodec(this._crypto);

  final AulCrypto _crypto;

  /// Domain-separation AD (must match the web `NOTIFY_AD`).
  static final _notifyAd = Uint8List.fromList(utf8.encode('aul-notify:v1'));

  /// The server's hard ceiling on POST /v1/circles/{id}/notify: 3 KiB of DECODED
  /// payload (Web Push itself only guarantees ~4 KiB). Clamped fields keep us
  /// far below it.
  static const int maxNotifyBytes = 3 * 1024;

  /// Free-text fields (a place name, a nickname) come from user input and have
  /// no length limit of their own, so they are clamped before sealing: a
  /// pathological 50 KB nickname must not blow the payload budget (and would be
  /// unreadable in a notification anyway). Generous enough that real names and
  /// places survive intact.
  static const int maxFieldChars = 64;

  /// Truncates to [maxFieldChars] *code points* (not UTF-16 units), so clamping
  /// never splits a surrogate pair (an emoji nickname) into a lone half. Matches
  /// the web's `[...s].slice(0, MAX_FIELD_CHARS)`.
  static String clamp(String s) {
    final runes = s.runes.toList();
    return runes.length <= maxFieldChars
        ? s
        : String.fromCharCodes(runes.take(maxFieldChars));
  }

  /// Seals [payload] under [key] into the base64 blob the server relays.
  /// Throws when the result would exceed [maxNotifyBytes] (it cannot with
  /// clamped fields — the check is a belt-and-braces guard against a future
  /// field being added without a budget).
  String seal(NotifyPayload payload, SecureKey key) {
    // Key order is part of the format: the web seals JSON.stringify of an object
    // built {t, place, who, ts}, and a byte-compare across clients must match.
    final json = <String, dynamic>{
      't': payload.kind.wire,
      'place': clamp(payload.place),
      'who': clamp(payload.who),
      'ts': payload.ts,
    };
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    final framed = _crypto.sealFramed(plain, key, ad: _notifyAd);
    if (framed.length > maxNotifyBytes) {
      throw ArgumentError(
        'notify payload too large: ${framed.length} > $maxNotifyBytes bytes',
      );
    }
    return base64.encode(framed);
  }

  /// Opens a relayed blob, trying every key in [keyring] (rotation-safe: a push
  /// carries no key epoch, and a rotated circle has several). Never throws:
  /// returns null when the input is malformed, when no key opens it (a circle
  /// this device has no key for), or when the plaintext isn't a well-formed
  /// payload. Mirrors the web `openNotify`.
  NotifyPayload? open(String b64, List<SecureKey> keyring) {
    final Uint8List blob;
    try {
      blob = base64.decode(b64);
    } catch (_) {
      return null;
    }
    for (final key in keyring) {
      final Map<String, dynamic> m;
      try {
        final plain = _crypto.openFramed(blob, key, ad: _notifyAd);
        m = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      } catch (_) {
        continue; // wrong key, wrong AD, or corrupt — try the next key
      }
      // Authentic but malformed — no other key can do better.
      final kind = NotifyKind.fromWire(m['t'] as String? ?? '');
      final place = m['place'];
      final who = m['who'];
      final ts = m['ts'];
      if (kind == null || place is! String || who is! String || ts is! num) {
        return null;
      }
      return NotifyPayload(
        kind: kind,
        place: clamp(place),
        who: clamp(who),
        ts: ts.toInt(),
      );
    }
    return null;
  }
}
