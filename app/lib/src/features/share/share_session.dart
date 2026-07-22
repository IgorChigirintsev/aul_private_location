import 'dart:convert';
import 'dart:typed_data';

import '../../data/api/models.dart';

/// A session is live while it is neither revoked nor past its deadline. Both
/// ends matter: the server only drops a session from the list on the next fetch,
/// so the deadline has to be checked locally too. Mirrors the web `isShareLive`.
bool isShareLive(ShareSession s, [DateTime? now]) =>
    !s.revoked && msUntilDeadline(s.expiresAt, now) > 0;

/// How often the session list is re-read, to notice a viewer claiming a link, a
/// revoke from another device, or a session dying. Both the UI and the location
/// isolate re-read on this interval, independently: the UI so the countdown and
/// the "viewer connected" badge are honest, the isolate so it stops feeding a
/// link that was revoked from another device. Lives here, next to
/// [isShareLive], because the isolate cannot import the Riverpod controller.
const Duration kShareRefreshInterval = Duration(seconds: 30);

/// The durations offered. The server clamps `ttl_seconds` to 60..3600 — an hour
/// of live location to a stranger is already the outer edge of sensible, so
/// there is nothing longer to offer.
const List<int> kShareTtlChoicesSeconds = [900, 1800, 3600];
const int kShareTtlDefaultSeconds = 900;

/// Milliseconds left until [deadline], floored at 0.
///
/// This drives whether a link still shows someone's location, so it fails
/// CLOSED: a null/absurd deadline reads as expired, never as "keep sharing".
int msUntilDeadline(DateTime? deadline, [DateTime? now]) {
  if (deadline == null) return 0;
  final ms = deadline
      .toUtc()
      .difference((now ?? DateTime.now()).toUtc())
      .inMilliseconds;
  return ms > 0 ? ms : 0;
}

/// Formats a remaining duration as a mm:ss countdown ("09:07"), rolling over to
/// h:mm:ss past an hour. Digits only — nothing to translate. Matches the web
/// `formatCountdown` so both clients count the same link down identically.
String formatCountdown(int ms) {
  final total = ((ms > 0 ? ms : 0) + 999) ~/ 1000; // ceil: 0.4 s left is not 0
  final s = total % 60;
  final m = (total ~/ 60) % 60;
  final h = total ~/ 3600;
  String p2(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${p2(m)}:${p2(s)}' : '${p2(m)}:${p2(s)}';
}

/// The share link an outsider opens in a BROWSER: `<origin>/s/<id>#<K_share>`.
///
/// The key rides in the FRAGMENT, which browsers never put on the wire — that is
/// the whole design: the server hands out the page and the ciphertext, and the
/// link itself carries the only thing that can decrypt them. [serverOrigin] is
/// the user's own server (the one they signed in to), so the viewer page comes
/// from the same place the ciphertext does.
String shareLink(String serverOrigin, String id, String keyB64Url) {
  final origin = serverOrigin.endsWith('/')
      ? serverOrigin.substring(0, serverOrigin.length - 1)
      : serverOrigin;
  return '$origin/s/$id#$keyB64Url';
}

/// base64url, unpadded — the exact encoding the link fragment carries (and the
/// same one the invite links use).
String toBase64Url(Uint8List raw) => base64Url.encode(raw).replaceAll('=', '');

/// Reverses [toBase64Url]. Throws [FormatException] on a malformed string.
Uint8List fromBase64Url(String s) {
  var v = s.replaceAll('-', '+').replaceAll('_', '/');
  while (v.length % 4 != 0) {
    v += '=';
  }
  return base64.decode(v);
}
