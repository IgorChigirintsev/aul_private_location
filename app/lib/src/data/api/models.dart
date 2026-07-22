import '../key_vault.dart';

/// Result of register/login: tokens plus identity.
class AuthResult {
  const AuthResult({
    required this.tokens,
    required this.refreshExpiresAt,
    this.userId,
    this.deviceId,
    this.email,
  });

  final SessionTokens tokens;
  final DateTime refreshExpiresAt;
  final String? userId;
  final String? deviceId;
  final String? email;

  factory AuthResult.fromJson(Map<String, dynamic> j) {
    final user = j['user'] as Map<String, dynamic>?;
    final device = j['device'] as Map<String, dynamic>?;
    return AuthResult(
      tokens: SessionTokens(
        accessToken: j['access_token'] as String,
        refreshToken: j['refresh_token'] as String,
        accessExpiresAt: DateTime.parse(j['access_expires_at'] as String),
      ),
      refreshExpiresAt: DateTime.parse(j['refresh_expires_at'] as String),
      userId: user?['id'] as String?,
      deviceId: device?['id'] as String?,
      email: user?['email'] as String?,
    );
  }
}

/// The server's E2EE posture and feature kill-switches (GET /v1/server-info).
class ServerInfo {
  const ServerInfo({
    required this.e2ee,
    required this.trustedServerMode,
    required this.retentionFeaturesEnabled,
    this.fcmEnabled = false,
    this.publicOrigin,
  });

  final bool e2ee;
  final bool trustedServerMode;

  /// Whether the operator configured FCM credentials, i.e. whether this server
  /// can deliver background push to Android at all. Defaults FALSE when the
  /// field is absent — an older server that never heard of FCM cannot send to
  /// it, so registering a token there would only hand it a device identifier for
  /// nothing.
  final bool fcmEnabled;

  /// Operator kill-switch for the opt-in retention features (arrival alerts,
  /// re-engagement reminders). When false, clients keep BOTH disabled regardless
  /// of the user's local opt-in. Defaults true (features are available for the
  /// user to opt in to) if the server omits the field.
  final bool retentionFeaturesEnabled;
  final String? publicOrigin;

  factory ServerInfo.fromJson(Map<String, dynamic> j) => ServerInfo(
    e2ee: (j['e2ee'] as bool?) ?? true,
    trustedServerMode: (j['trusted_server_mode'] as bool?) ?? false,
    retentionFeaturesEnabled:
        (j['retention_features_enabled'] as bool?) ?? true,
    fcmEnabled: (j['fcm_enabled'] as bool?) ?? false,
    publicOrigin: j['public_origin'] as String?,
  );
}

/// A circle the user belongs to. [nameEnc] is the circle name sealed under K_c
/// (base64 sealFramed, circle-name form / no AD) — opaque to the server, or null
/// when unnamed; decode it locally with the circle key (see
/// [AppController.decodeCircleName]).
class CircleSummary {
  const CircleSummary({
    required this.id,
    required this.role,
    required this.keyEpoch,
    required this.retentionDays,
    required this.precisionMode,
    this.nameEnc,
  });

  final String id;
  final String role;
  final int keyEpoch;
  final int retentionDays;
  final String precisionMode;

  /// base64 sealFramed(utf8(name), K_c), or null if the circle has no name set.
  final String? nameEnc;

  factory CircleSummary.fromJson(Map<String, dynamic> j) => CircleSummary(
    id: j['id'] as String,
    role: (j['role'] as String?) ?? 'member',
    keyEpoch: (j['key_epoch'] as num?)?.toInt() ?? 1,
    retentionDays: (j['retention_days'] as num?)?.toInt() ?? 7,
    precisionMode: (j['precision_mode'] as String?) ?? 'precise',
    nameEnc: j['name_enc'] as String?,
  );
}

/// A member of a circle as returned by GET /v1/circles/{id}/members. [profileEnc]
/// is the member's per-circle profile (nickname + optional avatar) sealed under
/// K_c — opaque to the server — or null if none set; decode it with ProfileCodec.
class Member {
  const Member({
    required this.userId,
    required this.email,
    required this.role,
    required this.precisionMode,
    required this.joinedAt,
    this.profileEnc,
  });

  final String userId;

  /// Fallback identity shown where no profile nick is set.
  final String email;
  final String role;
  final String precisionMode;
  final DateTime joinedAt;

  /// base64 sealFramed(json, K_c, "aul-profile:v1"), or null if unset.
  final String? profileEnc;

  factory Member.fromJson(Map<String, dynamic> j) => Member(
    userId: j['user_id'] as String,
    email: (j['email'] as String?) ?? '',
    role: (j['role'] as String?) ?? 'member',
    precisionMode: (j['precision_mode'] as String?) ?? 'precise',
    joinedAt: DateTime.parse(j['joined_at'] as String),
    profileEnc: j['profile_enc'] as String?,
  );
}

/// Minimal invite status (the circle key is NOT here — it's in the URL fragment).
class InviteInfo {
  const InviteInfo({
    required this.circleId,
    required this.role,
    required this.valid,
    required this.expiresAt,
  });

  final String circleId;
  final String role;
  final bool valid;
  final DateTime expiresAt;

  factory InviteInfo.fromJson(Map<String, dynamic> j) => InviteInfo(
    circleId: j['circle_id'] as String,
    role: (j['role'] as String?) ?? 'member',
    valid: (j['valid'] as bool?) ?? false,
    expiresAt: DateTime.parse(j['expires_at'] as String),
  );
}

/// Latest published app version (self-update).
class AppVersionInfo {
  const AppVersionInfo({
    required this.versionCode,
    required this.versionName,
    this.apkUrl,
    this.sha256,
    this.changelog,
    this.minSupported = 0,
  });

  final int versionCode;
  final String versionName;
  final String? apkUrl;
  final String? sha256;
  final String? changelog;
  final int minSupported;

  factory AppVersionInfo.fromJson(Map<String, dynamic> j) => AppVersionInfo(
    versionCode: (j['version_code'] as num).toInt(),
    versionName: j['version_name'] as String,
    apkUrl: j['apk_url'] as String?,
    sha256: j['sha256'] as String?,
    changelog: j['changelog'] as String?,
    minSupported: (j['min_supported'] as num?)?.toInt() ?? 0,
  );
}

/// A member device with its identity public key (Phase 4 key distribution).
class CircleDevice {
  const CircleDevice({
    required this.id,
    required this.userId,
    required this.platform,
    this.pubkeyB64,
  });

  final String id;
  final String userId;
  final String platform;
  final String? pubkeyB64;

  factory CircleDevice.fromJson(Map<String, dynamic> j) => CircleDevice(
    id: j['id'] as String,
    userId: j['user_id'] as String,
    platform: j['platform'] as String,
    pubkeyB64: j['pubkey'] as String?,
  );
}

/// A sealed key envelope addressed to this device (crypto_box_seal of K_c).
class KeyEnvelope {
  const KeyEnvelope({
    required this.id,
    required this.circleId,
    required this.ciphertextB64,
    required this.keyEpoch,
    this.senderDeviceId,
  });

  final String id;
  final String circleId;
  final String ciphertextB64;
  final int keyEpoch;
  final String? senderDeviceId;

  factory KeyEnvelope.fromJson(Map<String, dynamic> j) => KeyEnvelope(
    id: j['id'] as String,
    circleId: j['circle_id'] as String,
    ciphertextB64: j['ciphertext'] as String,
    keyEpoch: (j['key_epoch'] as num?)?.toInt() ?? 1,
    senderDeviceId: j['sender_device_id'] as String?,
  );
}

/// A sealed ping as returned by the server (for decrypting locally).
class RemotePing {
  const RemotePing({
    required this.deviceId,
    required this.nonceB64,
    required this.ciphertextB64,
    required this.capturedAt,
  });

  final String deviceId;
  final String nonceB64;
  final String ciphertextB64;
  final DateTime capturedAt;

  factory RemotePing.fromJson(Map<String, dynamic> j) => RemotePing(
    deviceId: j['device_id'] as String,
    nonceB64: j['nonce'] as String,
    ciphertextB64: j['ciphertext'] as String,
    capturedAt: DateTime.parse(j['captured_at'] as String),
  );
}

/// A place as the server stores it: one opaque framed+padded ciphertext blob
/// (name + coords + radius sealed under K_c) + optimistic-concurrency version.
class RemotePlace {
  const RemotePlace({
    required this.id,
    required this.ciphertextB64,
    required this.version,
    this.createdBy,
  });

  final String id;
  final String ciphertextB64;
  final int version;

  /// The member who created the place (user id). Server METADATA — it is not
  /// part of the sealed blob, so the server knows who added a place but still
  /// never learns its name or coordinates. Null on an older server, or when the
  /// creator's account is gone.
  final String? createdBy;

  factory RemotePlace.fromJson(Map<String, dynamic> j) => RemotePlace(
    id: j['id'] as String,
    ciphertextB64: j['ciphertext'] as String,
    version: (j['version'] as num?)?.toInt() ?? 1,
    createdBy: j['created_by'] as String?,
  );
}

/// The caller's OWN notification mutes in one circle (GET/PUT
/// `/v1/circles/{id}/mutes`).
///
/// A mute here is NOT local suppression: the server skips muted recipients when
/// it fans a notification out, so a muted member's notifications never reach this
/// account at all. The server also only ever reveals the CALLER's own mutes —
/// nobody can learn that they were muted.
///
/// The PUT REPLACES the whole set, so both fields are always the complete desired
/// state. Build the next state with [withCircleMuted] / [withMemberMuted] rather
/// than hand-assembling one at each call site — that is what keeps the replace
/// contract honest.
class Mutes {
  const Mutes({this.circleMuted = false, this.mutedUserIds = const []});

  /// Mute the whole circle: no member of it can notify this account.
  final bool circleMuted;

  /// Individually muted members (user ids) within the circle.
  final List<String> mutedUserIds;

  /// The "nothing muted" state, and the fallback whenever the mute set cannot be
  /// read (older server without the endpoint, offline). Failing OPEN is the
  /// honest default: an unreadable mute set must never be rendered as "muted",
  /// which would tell the user notifications are stopped when they are not.
  static const none = Mutes();

  factory Mutes.fromJson(Map<String, dynamic> j) => Mutes(
    circleMuted: (j['circle_muted'] as bool?) ?? false,
    mutedUserIds: ((j['muted_user_ids'] as List?) ?? const [])
        .cast<String>()
        .toList(growable: false),
  );

  Map<String, dynamic> toJson() => {
    'circle_muted': circleMuted,
    'muted_user_ids': mutedUserIds,
  };

  /// Whether [userId] is individually muted (ignores [circleMuted]).
  bool isMemberMuted(String userId) => mutedUserIds.contains(userId);

  /// The full mute set with the whole-circle flag flipped. Pure.
  Mutes withCircleMuted(bool muted) =>
      Mutes(circleMuted: muted, mutedUserIds: mutedUserIds);

  /// The full mute set with one member added/removed. Pure, idempotent, and it
  /// never duplicates a user id.
  Mutes withMemberMuted(String userId, bool muted) {
    final others = [
      for (final id in mutedUserIds)
        if (id != userId) id,
    ];
    return Mutes(
      circleMuted: circleMuted,
      mutedUserIds: muted ? [...others, userId] : others,
    );
  }
}

/// An SOS event as the server stores it (opaque sealed payload + metadata).
class RemoteSos {
  const RemoteSos({
    required this.id,
    required this.circleId,
    required this.ciphertextB64,
    required this.createdAt,
    this.deviceId,
    this.resolvedAt,
  });

  final String id;
  final String circleId;
  final String ciphertextB64;
  final DateTime createdAt;
  final String? deviceId;
  final DateTime? resolvedAt;

  factory RemoteSos.fromJson(Map<String, dynamic> j) => RemoteSos(
    id: j['id'] as String,
    circleId: j['circle_id'] as String,
    ciphertextB64: j['ciphertext'] as String,
    createdAt: DateTime.parse(j['created_at'] as String),
    deviceId: j['device_id'] as String?,
    resolvedAt: j['resolved_at'] != null
        ? DateTime.parse(j['resolved_at'] as String)
        : null,
  );
}

/// One sealed ping ready to POST.
class OutgoingPing {
  const OutgoingPing({
    required this.circleId,
    required this.clientId,
    required this.nonceB64,
    required this.ciphertextB64,
    required this.capturedAt,
    this.ttlSeconds,
  });

  final String circleId;
  final String clientId;
  final String nonceB64;
  final String ciphertextB64;
  final DateTime capturedAt;
  final int? ttlSeconds;

  Map<String, dynamic> toJson() => {
    'circle_id': circleId,
    'client_id': clientId,
    'nonce': nonceB64,
    'ciphertext': ciphertextB64,
    'captured_at': capturedAt.toUtc().toIso8601String(),
    if (ttlSeconds != null) 'ttl_seconds': ttlSeconds,
  };
}

/// One live-share session as the server reports it. The server knows a session
/// exists, when it dies, and whether a viewer has claimed it — never where the
/// sharer is, and never K_share. Mirrors the web `ShareSessionDTO`.
class ShareSession {
  const ShareSession({
    required this.id,
    required this.createdAt,
    required this.expiresAt,
    required this.viewerBound,
    required this.revoked,
  });

  final String id;
  final DateTime createdAt;
  final DateTime expiresAt;

  /// True once a viewer has opened the link: the server bound it to that one
  /// device, and every other device now gets a 403.
  final bool viewerBound;
  final bool revoked;

  factory ShareSession.fromJson(Map<String, dynamic> j) => ShareSession(
    id: j['id'] as String,
    createdAt: DateTime.parse(j['created_at'] as String),
    expiresAt: DateTime.parse(j['expires_at'] as String),
    viewerBound: (j['viewer_bound'] as bool?) ?? false,
    revoked: (j['revoked'] as bool?) ?? false,
  );
}
