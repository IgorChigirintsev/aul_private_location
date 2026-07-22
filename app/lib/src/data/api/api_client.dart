import 'package:dio/dio.dart';

import '../key_vault.dart';
import 'models.dart';

/// Thrown for API errors surfaced to the UI.
class AulApiException implements Exception {
  AulApiException(this.message, {this.statusCode, this.code});
  final String message;
  final int? statusCode;
  final String? code;
  @override
  String toString() => 'AulApiException($statusCode $code): $message';
}

/// Thrown by [AulApi.leaveCircle] when the caller is a circle's SOLE owner: the
/// server refuses the leave (HTTP 409) because it would orphan the circle. The
/// UI surfaces this distinctly to offer "delete the circle instead".
class SoleOwnerException implements Exception {
  const SoleOwnerException(this.message);
  final String message;
  @override
  String toString() => 'SoleOwnerException: $message';
}

/// Result of a ping batch upload.
class PingBatchResult {
  const PingBatchResult(this.accepted, this.stored, this.duplicate);
  final int accepted;
  final int stored;
  final int duplicate;
}

/// The typed HTTP client for the Aul server. Handles bearer auth with automatic,
/// serialized refresh-token rotation. The base URL is the user's chosen server.
class AulApi {
  factory AulApi({required String baseUrl, required KeyVault vault, Dio? dio}) {
    final client =
        dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            sendTimeout: const Duration(seconds: 30),
            receiveTimeout: const Duration(seconds: 30),
            headers: {'Content-Type': 'application/json'},
          ),
        );
    client.options.baseUrl = baseUrl;
    final api = AulApi._(client, vault);
    client.interceptors.add(
      QueuedInterceptorsWrapper(
        onRequest: api._attachAuth,
        onError: api._onError,
      ),
    );
    return api;
  }

  AulApi._(this._dio, this._vault);

  final Dio _dio;
  final KeyVault _vault;

  static bool _isAuthPath(String path) =>
      path.contains('/v1/auth/login') ||
      path.contains('/v1/auth/register') ||
      path.contains('/v1/auth/refresh');

  Future<void> _attachAuth(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (_isAuthPath(options.path)) {
      return handler.next(options);
    }
    var session = await _vault.loadSession();
    if (session != null && session.accessExpired) {
      session = await _refresh(session.refreshToken);
    }
    if (session != null) {
      options.headers['Authorization'] = 'Bearer ${session.accessToken}';
    }
    handler.next(options);
  }

  Future<void> _onError(DioException e, ErrorInterceptorHandler handler) async {
    final response = e.response;
    if (response?.statusCode == 401 &&
        !_isAuthPath(e.requestOptions.path) &&
        e.requestOptions.extra['retried'] != true) {
      final session = await _vault.loadSession();
      if (session != null) {
        final refreshed = await _refresh(session.refreshToken);
        if (refreshed != null) {
          final opts = e.requestOptions..extra['retried'] = true;
          opts.headers['Authorization'] = 'Bearer ${refreshed.accessToken}';
          try {
            final r = await _dio.fetch<dynamic>(opts);
            return handler.resolve(r);
          } catch (_) {
            // fall through to the error
          }
        }
      }
    }
    handler.next(e);
  }

  Future<SessionTokens?> _refresh(String refreshToken) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/v1/auth/refresh',
        data: {'refresh_token': refreshToken},
      );
      final auth = AuthResult.fromJson(r.data!);
      await _vault.saveSession(auth.tokens);
      return auth.tokens;
    } on DioException {
      await _vault.clearSession(); // refresh failed → force re-login
      return null;
    }
  }

  /// The freshest access token, for authenticating a transport that ISN'T Dio —
  /// the realtime WebSocket. Refreshes first when the current token has expired,
  /// because the socket cannot ride the request interceptor that quietly does
  /// this for every HTTP call.
  ///
  /// Returns null when there is no session, or when the refresh failed and the
  /// user must sign in again — so the caller doesn't open a socket that can only
  /// be answered with a 401.
  Future<String?> socketAccessToken() async {
    var session = await _vault.loadSession();
    if (session == null) return null;
    if (session.accessExpired) {
      session = await _refresh(session.refreshToken);
    }
    return session?.accessToken;
  }

  Never _throw(DioException e) {
    final data = e.response?.data;
    String msg = e.message ?? 'network error';
    String? code;
    if (data is Map && data['error'] is Map) {
      msg = (data['error']['message'] as String?) ?? msg;
      code = data['error']['code'] as String?;
    }
    throw AulApiException(msg, statusCode: e.response?.statusCode, code: code);
  }

  // --- auth ---

  Future<AuthResult> register({
    required String email,
    required String password,
    required String platform,
    String? pubkeyB64,
    String? displayName,
  }) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/v1/auth/register',
        data: {
          'email': email,
          'password': password,
          'platform': platform,
          'pubkey': ?pubkeyB64,
          'display_name': ?displayName,
        },
      );
      final auth = AuthResult.fromJson(r.data!);
      await _persist(auth);
      return auth;
    } on DioException catch (e) {
      _throw(e);
    }
  }

  Future<AuthResult> login({
    required String email,
    required String password,
    required String platform,
    String? deviceId,
    String? pubkeyB64,
  }) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/v1/auth/login',
        data: {
          'email': email,
          'password': password,
          'platform': platform,
          'device_id': ?deviceId,
          'pubkey': ?pubkeyB64,
        },
      );
      final auth = AuthResult.fromJson(r.data!);
      await _persist(auth);
      return auth;
    } on DioException catch (e) {
      _throw(e);
    }
  }

  Future<void> _persist(AuthResult auth) async {
    await _vault.saveSession(auth.tokens);
    if (auth.deviceId != null) await _vault.saveDeviceId(auth.deviceId!);
    // Who "you" are, so a restored session can still pick its own row out of a
    // members list without a round-trip.
    if (auth.userId != null) await _vault.saveUserId(auth.userId!);
    if (auth.email != null) await _vault.saveEmail(auth.email!);
  }

  Future<void> logout() async {
    try {
      await _dio.post<void>('/v1/auth/logout');
    } on DioException {
      // best effort
    }
    await _vault.clearSession();
  }

  // --- server info ---

  /// Public, unauthenticated server posture, including the retention-features
  /// kill-switch clients gate the opt-in features behind.
  Future<ServerInfo> serverInfo() async {
    try {
      final r = await _dio.get<Map<String, dynamic>>('/v1/server-info');
      return ServerInfo.fromJson(r.data!);
    } on DioException catch (e) {
      _throw(e);
    }
  }

  // --- invites ---

  Future<InviteInfo> getInvite(String inviteId) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>('/v1/invites/$inviteId');
      return InviteInfo.fromJson(r.data!);
    } on DioException catch (e) {
      _throw(e);
    }
  }

  /// Accepts an invite; returns the joined circle id.
  Future<String> acceptInvite(String inviteId) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/v1/invites/$inviteId/accept',
      );
      return r.data!['circle_id'] as String;
    } on DioException catch (e) {
      _throw(e);
    }
  }

  // --- circles ---

  Future<List<CircleSummary>> listCircles() async {
    try {
      final r = await _dio.get<Map<String, dynamic>>('/v1/circles');
      final list = (r.data!['circles'] as List).cast<Map<String, dynamic>>();
      return list.map(CircleSummary.fromJson).toList();
    } on DioException catch (e) {
      _throw(e);
    }
  }

  Future<CircleSummary> createCircle({
    String? nameEncB64,
    int? retentionDays,
  }) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/v1/circles',
        data: {'name_enc': ?nameEncB64, 'retention_days': ?retentionDays},
      );
      return CircleSummary.fromJson(r.data!);
    } on DioException catch (e) {
      _throw(e);
    }
  }

  /// Creates an invite for [circleId] and returns its id. The invite is only
  /// half of a usable link: the circle key K_c is never sent here — the caller
  /// staples it onto the URL fragment (see `inviteLink`), which is why the
  /// server can hand out invites to a circle it cannot read.
  Future<String> createInvite(
    String circleId, {
    int maxUses = 5,
    int? ttlSeconds,
  }) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/v1/circles/$circleId/invites',
        data: {'max_uses': maxUses, 'ttl_seconds': ?ttlSeconds},
      );
      return r.data!['id'] as String;
    } on DioException catch (e) {
      _throw(e);
    }
  }

  /// Asks the server to relay ONE sealed notification blob to the circle's OTHER
  /// members over Web Push. [payloadEncB64] is base64 of
  /// `sealFramed(json, K_c, "aul-notify:v1")` — the server relays those bytes
  /// verbatim and cannot read them; it learns only that this circle had *an*
  /// event. The fan-out already skips the sender and anyone who muted the circle
  /// or the sender. Returns how many pushes were sent.
  ///
  /// A server without VAPID keys configured answers 503: that is a no-op, not an
  /// error (nothing to fix, nothing to retry), so it returns 0 like a fan-out to
  /// nobody.
  Future<int> notifyCircle(String circleId, String payloadEncB64) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/v1/circles/$circleId/notify',
        data: {'payload_enc': payloadEncB64},
      );
      return (r.data?['sent'] as num?)?.toInt() ?? 0;
    } on DioException catch (e) {
      if (e.response?.statusCode == 503) return 0; // push not configured
      _throw(e);
    }
  }

  // --- push registration (the RECEIVING half of notifyCircle) ---
  //
  // What the server learns here: that this account has an Android device, and a
  // token it can wake. It never learns what it delivers — the payload it relays
  // is already sealed under K_c (see NotifyCodec), so FCM is only the transport,
  // exactly as Web Push is for the dashboard.

  /// Registers this device's FCM registration token so the server can wake it
  /// with a data-only push. Idempotent server-side: re-registering the same
  /// token (on refresh, or on every launch) is a no-op, not a duplicate.
  Future<void> pushSubscribeFcm(String token) async {
    try {
      await _dio.post<void>(
        '/v1/push/subscribe',
        data: {'kind': 'fcm', 'token': token},
      );
    } on DioException catch (e) {
      _throw(e);
    }
  }

  /// Unregisters a push destination. [endpoint] is the FCM token for Android
  /// (the field is named for the Web Push endpoint URL the dashboard sends —
  /// one shape serves both transports).
  Future<void> pushUnsubscribe(String endpoint) async {
    try {
      await _dio.delete<void>(
        '/v1/push/subscribe',
        data: {'endpoint': endpoint},
      );
    } on DioException catch (e) {
      _throw(e);
    }
  }

  /// Circle members with their sealed per-circle profiles (nick + avatar).
  Future<List<Member>> members(String circleId) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/v1/circles/$circleId/members',
      );
      return (r.data!['members'] as List)
          .cast<Map<String, dynamic>>()
          .map(Member.fromJson)
          .toList();
    } on DioException catch (e) {
      _throw(e);
    }
  }

  /// Sets (or clears, with null) the caller's OWN per-circle profile blob. The
  /// server relays it opaquely; the profile is sealed under K_c client-side.
  Future<void> setProfile(String circleId, String? profileEncB64) async {
    try {
      await _dio.put<void>(
        '/v1/circles/$circleId/profile',
        data: {'profile_enc': profileEncB64},
      );
    } on DioException catch (e) {
      _throw(e);
    }
  }

  /// Owner-only: re-seal the circle name under K_c and update it. Returns the
  /// updated circle summary.
  Future<CircleSummary> renameCircle(String circleId, String nameEncB64) async {
    try {
      final r = await _dio.patch<Map<String, dynamic>>(
        '/v1/circles/$circleId',
        data: {'name_enc': nameEncB64},
      );
      return CircleSummary.fromJson(r.data!);
    } on DioException catch (e) {
      _throw(e);
    }
  }

  /// Removes the caller from the circle (instant self-leave; no owner approval).
  /// A SOLE owner cannot leave (they'd orphan the circle): the server returns
  /// HTTP 409, which we surface as [SoleOwnerException] so the UI can offer
  /// "delete the circle instead".
  Future<void> leaveCircle(String circleId) async {
    try {
      await _dio.post<void>('/v1/circles/$circleId/leave');
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        final data = e.response?.data;
        final msg = (data is Map && data['error'] is Map)
            ? (data['error']['message'] as String?)
            : null;
        throw SoleOwnerException(msg ?? 'transfer ownership or delete first');
      }
      _throw(e);
    }
  }

  /// Owner-only: permanently deletes the circle for everyone.
  Future<void> deleteCircle(String circleId) async {
    try {
      await _dio.delete<void>('/v1/circles/$circleId');
    } on DioException catch (e) {
      _throw(e);
    }
  }

  /// Owner-only: removes another member from the circle. NOTE: this does NOT take
  /// back the copy of K_c they already hold (v1 has no forward secrecy), so the
  /// caller should offer a key rotation right afterwards.
  Future<void> removeMember(String circleId, String userId) async {
    try {
      await _dio.delete<void>('/v1/circles/$circleId/members/$userId');
    } on DioException catch (e) {
      _throw(e);
    }
  }

  /// Sets the caller's precision mode in ONE circle ('precise' | 'city' |
  /// 'paused'). The mode is metadata the circle can see — it is what greys out a
  /// paused member's marker for everyone else — so it must be told to the server,
  /// not only applied locally. Returns the stored mode.
  Future<String> setPrecision(String circleId, String mode) async {
    try {
      final r = await _dio.put<Map<String, dynamic>>(
        '/v1/circles/$circleId/precision',
        data: {'mode': mode},
      );
      return (r.data!['precision_mode'] as String?) ?? mode;
    } on DioException catch (e) {
      _throw(e);
    }
  }

  // --- notification mutes ---
  //
  // A mute is enforced SERVER-side: the fan-out for POST /circles/{id}/notify
  // skips muted recipients, so a muted member's notifications never reach this
  // account. The server exposes only the CALLER's own mutes — a member can never
  // learn that someone muted them.

  /// The caller's OWN mutes in [circleId].
  Future<Mutes> mutes(String circleId) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/v1/circles/$circleId/mutes',
      );
      return Mutes.fromJson(r.data!);
    } on DioException catch (e) {
      _throw(e);
    }
  }

  /// REPLACES the caller's whole mute set for [circleId] and returns what the
  /// server actually stored (idempotent). Callers must pass the complete desired
  /// state — build it with [Mutes.withCircleMuted] / [Mutes.withMemberMuted].
  /// The server rejects (400) a non-member id, a SELF-mute, a malformed uuid, or
  /// more than 500 ids.
  Future<Mutes> setMutes(String circleId, Mutes next) async {
    try {
      final r = await _dio.put<Map<String, dynamic>>(
        '/v1/circles/$circleId/mutes',
        data: next.toJson(),
      );
      return Mutes.fromJson(r.data!);
    } on DioException catch (e) {
      _throw(e);
    }
  }

  /// Latest ping per device in a circle (encrypted; the watcher decrypts).
  Future<List<RemotePing>> latestPings(String circleId) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/v1/circles/$circleId/pings/latest',
      );
      final list = (r.data!['pings'] as List).cast<Map<String, dynamic>>();
      return list.map(RemotePing.fromJson).toList();
    } on DioException catch (e) {
      _throw(e);
    }
  }

  // --- pings ---

  Future<PingBatchResult> sendPings(List<OutgoingPing> pings) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/v1/pings/batch',
        data: {'pings': pings.map((p) => p.toJson()).toList()},
      );
      final d = r.data!;
      return PingBatchResult(
        (d['accepted'] as num?)?.toInt() ?? 0,
        (d['stored'] as num?)?.toInt() ?? 0,
        (d['duplicate'] as num?)?.toInt() ?? 0,
      );
    } on DioException catch (e) {
      _throw(e);
    }
  }

  // --- places (Phase 5: encrypted places + client-side geofences) ---

  /// Lists the circle's places (opaque ciphertext; the client decrypts + runs
  /// geofences locally).
  Future<List<RemotePlace>> listPlaces(String circleId) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/v1/circles/$circleId/places',
      );
      return (r.data!['places'] as List)
          .cast<Map<String, dynamic>>()
          .map(RemotePlace.fromJson)
          .toList();
    } on DioException catch (e) {
      _throw(e);
    }
  }

  Future<RemotePlace> createPlace(String circleId, String ciphertextB64) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/v1/circles/$circleId/places',
        data: {'ciphertext': ciphertextB64},
      );
      return RemotePlace.fromJson(r.data!);
    } on DioException catch (e) {
      _throw(e);
    }
  }

  /// Updates a place with optimistic concurrency; throws (409) on version clash.
  Future<RemotePlace> updatePlace(
    String circleId,
    String placeId,
    String ciphertextB64,
    int version,
  ) async {
    try {
      final r = await _dio.put<Map<String, dynamic>>(
        '/v1/circles/$circleId/places/$placeId',
        data: {'ciphertext': ciphertextB64, 'version': version},
      );
      return RemotePlace.fromJson(r.data!);
    } on DioException catch (e) {
      _throw(e);
    }
  }

  Future<void> deletePlace(String circleId, String placeId) async {
    try {
      await _dio.delete<void>('/v1/circles/$circleId/places/$placeId');
    } on DioException catch (e) {
      _throw(e);
    }
  }

  // --- SOS (Phase 5) ---

  /// Raises a sealed SOS (payload: last-known location + message under K_c).
  Future<RemoteSos> createSos(String circleId, String ciphertextB64) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/v1/circles/$circleId/sos',
        data: {'ciphertext': ciphertextB64},
      );
      return RemoteSos.fromJson(r.data!);
    } on DioException catch (e) {
      _throw(e);
    }
  }

  Future<void> resolveSos(String circleId, String sosId) async {
    try {
      await _dio.post<void>('/v1/circles/$circleId/sos/$sosId/resolve');
    } on DioException catch (e) {
      _throw(e);
    }
  }

  Future<List<RemoteSos>> listSos(String circleId) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/v1/circles/$circleId/sos',
      );
      return (r.data!['sos'] as List)
          .cast<Map<String, dynamic>>()
          .map(RemoteSos.fromJson)
          .toList();
    } on DioException catch (e) {
      _throw(e);
    }
  }

  // --- live share (a time-boxed link for ONE outsider, no account) ---
  //
  // The server issues the session, relays one sealed position, and enforces the
  // deadline. It never sees K_share: that exists only on this device and in the
  // link's fragment, so a share shows this one person, to whoever holds the
  // link, and only until the deadline.

  /// Creates a session. [ttlSeconds] is clamped by the server to 60..3600.
  Future<ShareSession> createShare(int ttlSeconds) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/v1/share',
        data: {'ttl_seconds': ttlSeconds},
      );
      // The create response carries only id + expires_at; the rest is knowable
      // (nobody has opened a link that does not exist yet).
      return ShareSession(
        id: r.data!['id'] as String,
        createdAt: DateTime.now().toUtc(),
        expiresAt: DateTime.parse(r.data!['expires_at'] as String),
        viewerBound: false,
        revoked: false,
      );
    } on DioException catch (e) {
      _throw(e);
    }
  }

  /// The caller's OWN unexpired sessions.
  Future<List<ShareSession>> listShares() async {
    try {
      final r = await _dio.get<Map<String, dynamic>>('/v1/share');
      return (r.data!['sessions'] as List)
          .cast<Map<String, dynamic>>()
          .map(ShareSession.fromJson)
          .toList();
    } on DioException catch (e) {
      _throw(e);
    }
  }

  /// Kills a session now: whoever is watching stops seeing the sharer at once.
  Future<void> revokeShare(String id) async {
    try {
      await _dio.delete<void>('/v1/share/$id');
    } on DioException catch (e) {
      _throw(e);
    }
  }

  /// Owner-only: upserts the session's single latest sealed position (sealed
  /// under K_share — opaque to the server).
  Future<void> putSharePing(
    String id, {
    required String nonceB64,
    required String ciphertextB64,
    required DateTime capturedAt,
  }) async {
    try {
      await _dio.put<void>(
        '/v1/share/$id/ping',
        data: {
          'nonce': nonceB64,
          'ciphertext': ciphertextB64,
          'captured_at': capturedAt.toUtc().toIso8601String(),
        },
      );
    } on DioException catch (e) {
      _throw(e);
    }
  }

  // --- key envelopes (Phase 4: multi-device key distribution + rotation) ---

  /// Member devices of a circle with their identity public keys.
  Future<List<CircleDevice>> circleDevices(String circleId) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/v1/circles/$circleId/devices',
      );
      return (r.data!['devices'] as List)
          .cast<Map<String, dynamic>>()
          .map(CircleDevice.fromJson)
          .toList();
    } on DioException catch (e) {
      _throw(e);
    }
  }

  Future<List<KeyEnvelope>> pendingEnvelopes() async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/v1/key-envelopes/pending',
      );
      return (r.data!['envelopes'] as List)
          .cast<Map<String, dynamic>>()
          .map(KeyEnvelope.fromJson)
          .toList();
    } on DioException catch (e) {
      _throw(e);
    }
  }

  Future<int> postEnvelopes(
    String circleId,
    List<Map<String, dynamic>> envelopes,
  ) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/v1/key-envelopes',
        data: {'circle_id': circleId, 'envelopes': envelopes},
      );
      return (r.data!['delivered'] as num?)?.toInt() ?? 0;
    } on DioException catch (e) {
      _throw(e);
    }
  }

  Future<void> consumeEnvelope(String id) async {
    try {
      await _dio.post<void>('/v1/key-envelopes/$id/consume');
    } on DioException catch (e) {
      _throw(e);
    }
  }

  Future<int> rotateKey(String circleId) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/v1/circles/$circleId/rotate-key',
      );
      return (r.data!['key_epoch'] as num?)?.toInt() ?? 0;
    } on DioException catch (e) {
      _throw(e);
    }
  }

  // --- version (self-update) ---

  Future<AppVersionInfo?> latestVersion(String platform) async {
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        '/v1/version/latest',
        queryParameters: {'platform': platform},
      );
      return AppVersionInfo.fromJson(r.data!);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      _throw(e);
    }
  }
}
