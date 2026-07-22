import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import '../../crypto/ping_codec.dart';
import '../../data/api/models.dart';
import '../../domain/location_fix.dart';

/// One circle member's most-recent decrypted position, joined with the device's
/// platform + owning user and the member's per-circle profile (nickname +
/// avatar) for the marker label/icon. Mirrors the web `MemberPosition` +
/// `markerInfo` join (deviceId → device → profile). Every coordinate here is
/// decrypted on-device with K_c — the server only ever relays ciphertext.
class MemberPosition {
  const MemberPosition({
    required this.deviceId,
    required this.fix,
    this.userId,
    this.platform = '',
    this.precisionMode = 'precise',
    this.nick,
    this.email,
    this.avatarBytes,
  });

  final String deviceId;
  final LocationFix fix;
  final String? userId;

  /// The device's platform: 'web', 'android', 'ios', … (from the device roster).
  final String platform;

  /// The owning member's CURRENT precision mode ('precise' | 'city' | 'paused')
  /// as reported by the members list — server metadata that is always up to date.
  ///
  /// Deliberately NOT the mode carried inside [fix]: a paused reporter stops
  /// sending pings entirely, so the last decrypted ping keeps claiming its old
  /// mode forever and would render a stale marker as live. Defaults to 'precise'
  /// when the device's owner isn't in the members list (unknown ⇒ treat as live,
  /// same as the web).
  final String precisionMode;

  /// The member's per-circle nickname, if a profile is set.
  final String? nick;

  /// The member's email — the label fallback when no nickname is set.
  final String? email;

  /// The decoded avatar image (from the profile's data-URL), or null for the
  /// coloured-initial fallback.
  final Uint8List? avatarBytes;

  /// This member's battery percentage (0..100) as of [updatedAt], or null when
  /// their reporter sent none (an older client, or a platform that won't say).
  ///
  /// It rides INSIDE the sealed ping, so it is end-to-end encrypted like the
  /// coordinates — the server never learns it. Surfaced because "she's not moving"
  /// and "her phone is at 4%" are very different things to a worried parent, and
  /// the web's members panel has always shown it.
  int? get battery => fix.battery;

  /// When this position was CAPTURED (the reporter's own clock, from inside the
  /// sealed payload — not a server receipt time). Drives the "updated N min ago"
  /// label, and the newest-wins rule when the poller and the socket both deliver.
  DateTime get updatedAt => fix.capturedAt;

  /// Web devices are computers; everything else (android/ios) is a phone. Mirrors
  /// the web "PC" badge (platform === 'web').
  bool get isPc => platform == 'web';

  /// True when the owner has switched sharing OFF. Their pin stays at this — the
  /// last place they actually shared — but must render greyed out / not-live, so
  /// it never passes for a live position. Mirrors the web `aul-marker--paused`.
  bool get isPaused => precisionMode == 'paused';

  /// The display label: nickname if set, else the email, else the device id.
  String get label {
    final n = nick?.trim();
    if (n != null && n.isNotEmpty) return n;
    final e = email?.trim();
    if (e != null && e.isNotEmpty) return e;
    return deviceId;
  }

  /// The single-letter initial for the coloured-pin fallback.
  String get initial {
    final s = label.trim();
    return s.isEmpty ? '?' : s.substring(0, 1).toUpperCase();
  }

  /// A copy with a new [fix], keeping every joined field.
  ///
  /// This is what lets a realtime ping move a marker: the socket delivers only a
  /// device id and a sealed fix, with none of the roster/profile/precision join
  /// that the poll does. So the newest fix lands on top of the last poll's
  /// metadata, and the member keeps their name and face between polls instead of
  /// briefly collapsing to a bare device id.
  MemberPosition copyWith({LocationFix? fix}) => MemberPosition(
    deviceId: deviceId,
    fix: fix ?? this.fix,
    userId: userId,
    platform: platform,
    precisionMode: precisionMode,
    nick: nick,
    email: email,
    avatarBytes: avatarBytes,
  );
}

/// The freshest position per USER, keyed by user id — for the members screen,
/// which lists people, while positions arrive keyed by DEVICE.
///
/// A member with a phone and a laptop has two devices reporting; the most
/// recently captured one is the answer to "where are they / what's their
/// battery". Positions whose device has no known owner are dropped: an
/// unattributable pin cannot be put on anyone's row.
///
/// The web can't do this at all — it shows `posList[0]`, an arbitrary circle
/// member's position on EVERY row, because its device→user join isn't wired up.
/// The app has the roster, so it shows each member their own.
Map<String, MemberPosition> positionsByUser(
  Map<String, MemberPosition> byDevice,
) {
  final out = <String, MemberPosition>{};
  for (final p in byDevice.values) {
    final userId = p.userId;
    if (userId == null) continue;
    final existing = out[userId];
    if (existing == null || p.updatedAt.isAfter(existing.updatedAt)) {
      out[userId] = p;
    }
  }
  return out;
}

/// Decodes a `data:image/...;base64,` avatar data URL into raw bytes for a
/// marker image. Returns null when the input is null or malformed.
Uint8List? decodeAvatarDataUrl(String? dataUrl) {
  if (dataUrl == null) return null;
  final comma = dataUrl.indexOf(',');
  if (comma < 0) return null;
  try {
    return base64.decode(dataUrl.substring(comma + 1));
  } catch (_) {
    return null;
  }
}

/// Builds the deviceId → [MemberPosition] map from already-fetched inputs: the
/// latest sealed [pings], the [circleKeys] ring (all K_c epochs, rotation-safe),
/// the device roster ([devicesById]: deviceId → platform + userId), the decoded
/// per-user profiles ([profilesByUserId]: userId → nick/avatar), member emails
/// ([emailsByUserId]) for the label fallback, and each member's CURRENT sharing
/// mode ([precisionByUserId]: userId → 'precise' | 'city' | 'paused') so a member
/// who paused renders as not-live rather than as a stale live pin.
///
/// Pings that don't decrypt under ANY key in [circleKeys] — wrong/rotated key,
/// tampering, or malformed base64 — are skipped SILENTLY (no key on this device
/// just yields an empty map upstream). When several pings share a device, the
/// NEWEST capture wins (safe against out-of-order delivery, mirroring the web
/// positions store).
///
/// This is the unit-testable heart of the map pipeline: it takes plain data in
/// and returns plain data out, with no network, timers, or widgets.
Map<String, MemberPosition> buildMemberPositions({
  required List<RemotePing> pings,
  required PingCodec codec,
  required List<SecureKey> circleKeys,
  Map<String, CircleDevice> devicesById = const {},
  Map<String, ({String nick, String? avatar})?> profilesByUserId = const {},
  Map<String, String> emailsByUserId = const {},
  Map<String, String> precisionByUserId = const {},
}) {
  final out = <String, MemberPosition>{};
  for (final ping in pings) {
    final LocationFix? fix;
    try {
      fix = codec.openWithKeyring(
        base64.decode(ping.nonceB64),
        base64.decode(ping.ciphertextB64),
        circleKeys,
      );
    } catch (_) {
      continue; // malformed base64 — skip silently
    }
    if (fix == null) continue; // no key opened it — skip silently
    final existing = out[ping.deviceId];
    if (existing != null && !fix.capturedAt.isAfter(existing.fix.capturedAt)) {
      continue; // keep the newer capture
    }
    final device = devicesById[ping.deviceId];
    final userId = device?.userId;
    final profile = userId == null ? null : profilesByUserId[userId];
    out[ping.deviceId] = MemberPosition(
      deviceId: ping.deviceId,
      fix: fix,
      userId: userId,
      platform: device?.platform ?? '',
      precisionMode:
          (userId == null ? null : precisionByUserId[userId]) ?? 'precise',
      nick: profile?.nick,
      email: userId == null ? null : emailsByUserId[userId],
      avatarBytes: decodeAvatarDataUrl(profile?.avatar),
    );
  }
  return out;
}
