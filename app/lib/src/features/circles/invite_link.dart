import 'dart:typed_data';

import '../share/share_session.dart' show fromBase64Url, toBase64Url;

/// Why an invite link could not be parsed. Each maps to its own message so a
/// mistyped link and a truncated one don't read the same.
enum InviteLinkError {
  /// No `/i/<id>` in the path — not an invite link at all.
  notAnInvite,

  /// The `#<key>` fragment is missing: the server half is there, the half the
  /// server must never see is not, so this link can never open the circle.
  missingKey,

  /// The fragment is there but isn't a circle key (bad base64 / wrong length).
  malformedKey,
}

/// The two halves of an invite link, once split.
class InviteLinkParts {
  const InviteLinkParts({required this.inviteId, required this.key});

  /// The invite the server accepts. This half is public.
  final String inviteId;

  /// The raw circle key K_c, carried ONLY in the URL fragment. Browsers never
  /// put a fragment on the wire and neither do we — the server issues the invite
  /// knowing nothing about the key that makes it useful.
  final Uint8List key;
}

/// The result of [parseInviteLink]: either the parsed halves or the reason it
/// failed.
sealed class InviteLinkResult {
  const InviteLinkResult();
}

final class InviteLinkOk extends InviteLinkResult {
  const InviteLinkOk(this.parts);
  final InviteLinkParts parts;
}

final class InviteLinkFailed extends InviteLinkResult {
  const InviteLinkFailed(this.error);
  final InviteLinkError error;
}

/// Builds the invite link for [inviteId] against [serverOrigin], with the circle
/// key in the fragment: `<origin>/i/<id>#<base64url(K_c)>`.
///
/// The fragment is the whole design: `POST /circles/{id}/invites` tells the
/// server an invite exists, and this function then staples on a key the server
/// was never given. Whoever opens the link holds both halves; the server holds
/// one. Mirrors the web `InviteDialog` (`${location.origin}/i/${invite.id}#${toBase64Url(circleKey)}`)
/// and is the exact shape [parseInviteLink] — and therefore the app's own
/// join-by-link path — reads back.
String inviteLink(String serverOrigin, String inviteId, Uint8List circleKey) {
  final origin = serverOrigin.endsWith('/')
      ? serverOrigin.substring(0, serverOrigin.length - 1)
      : serverOrigin;
  return '$origin/i/$inviteId#${toBase64Url(circleKey)}';
}

/// Splits an invite link back into its invite id and circle key. [keyBytes] is
/// the expected K_c length (32) — a fragment of any other length is rejected
/// rather than handed to libsodium.
///
/// Deliberately lenient about the origin and the path prefix: an invite may be
/// served from any host, and links get pasted after being wrapped, shortened or
/// mangled by a messenger. All that must hold is `…/i/<id>#<key>`.
InviteLinkResult parseInviteLink(String raw, {required int keyBytes}) {
  final Uri uri;
  try {
    uri = Uri.parse(raw.trim());
  } catch (_) {
    return const InviteLinkFailed(InviteLinkError.notAnInvite);
  }
  final segments = uri.pathSegments;
  final idx = segments.indexOf('i');
  if (idx == -1 || idx + 1 >= segments.length || segments[idx + 1].isEmpty) {
    return const InviteLinkFailed(InviteLinkError.notAnInvite);
  }
  final fragment = uri.fragment; // K_c — never sent to the server
  if (fragment.isEmpty) {
    return const InviteLinkFailed(InviteLinkError.missingKey);
  }
  final Uint8List key;
  try {
    key = fromBase64Url(fragment);
  } catch (_) {
    return const InviteLinkFailed(InviteLinkError.malformedKey);
  }
  if (key.length != keyBytes) {
    return const InviteLinkFailed(InviteLinkError.malformedKey);
  }
  return InviteLinkOk(InviteLinkParts(inviteId: segments[idx + 1], key: key));
}
