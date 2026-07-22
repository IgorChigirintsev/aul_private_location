import type {
  AppVersion,
  AuthResult,
  CircleSummary,
  InviteDTO,
  MemberDTO,
  MutesDTO,
  PlaceDTO,
  RemotePing,
  ShareSessionDTO,
  SharePositionDTO,
  SharePublicDTO,
  SosDTO,
  UserDTO,
} from './types';

/// An API error surfaced to the UI.
export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly code?: string,
  ) {
    super(message);
  }
}

/// The web dashboard authenticates with httpOnly cookies (set by the server on
/// login). Nothing sensitive is kept in JS. On 401 we transparently refresh once
/// (the refresh cookie is sent to /v1/auth/refresh) and retry.
///
/// In dev, Vite proxies /v1 to the server, so everything is same-origin and
/// cookies flow. In prod the server serves this bundle, so it is same-origin too.
async function request<T>(
  method: string,
  path: string,
  body?: unknown,
  retry = true,
): Promise<T> {
  const res = await fetch(path, {
    method,
    credentials: 'include',
    headers: body !== undefined ? { 'Content-Type': 'application/json' } : undefined,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });

  if (res.status === 401 && retry && !path.includes('/v1/auth/')) {
    const refreshed = await tryRefresh();
    if (refreshed) return request<T>(method, path, body, false);
  }

  if (!res.ok) {
    let message = res.statusText;
    let code: string | undefined;
    try {
      const data = await res.json();
      if (data?.error) {
        message = data.error.message ?? message;
        code = data.error.code;
      }
    } catch {
      /* non-JSON error */
    }
    throw new ApiError(message, res.status, code);
  }

  if (res.status === 204) return undefined as T;
  return (await res.json()) as T;
}

let refreshInFlight: Promise<boolean> | null = null;
async function tryRefresh(): Promise<boolean> {
  refreshInFlight ??= (async () => {
    try {
      const res = await fetch('/v1/auth/refresh', {
        method: 'POST',
        credentials: 'include',
      });
      return res.ok;
    } catch {
      return false;
    } finally {
      refreshInFlight = null;
    }
  })();
  return refreshInFlight;
}

export const api = {
  // auth
  register(email: string, password: string, pubkeyB64: string, platform = 'web') {
    return request<AuthResult>('POST', '/v1/auth/register', {
      email,
      password,
      platform,
      pubkey: pubkeyB64,
    });
  },
  // `deviceId`, when this browser already registered one, tells the server to
  // REUSE that device rather than create a new one — the fix for a single
  // browser accumulating duplicate device rows across re-authentications.
  login(email: string, password: string, pubkeyB64?: string, deviceId?: string, platform = 'web') {
    return request<AuthResult>('POST', '/v1/auth/login', {
      email,
      password,
      platform,
      pubkey: pubkeyB64,
      device_id: deviceId,
    });
  },
  logout() {
    return request<void>('POST', '/v1/auth/logout');
  },
  me() {
    return request<UserDTO>('GET', '/v1/account/me');
  },

  // circles
  listCircles() {
    return request<{ circles: CircleSummary[] }>('GET', '/v1/circles').then((r) => r.circles);
  },
  createCircle(nameEncB64: string | null, retentionDays?: number) {
    return request<CircleSummary>('POST', '/v1/circles', {
      name_enc: nameEncB64,
      retention_days: retentionDays,
    });
  },
  /// Owner-only: re-seal the circle name under K_c and update it (name_enc is
  /// base64 ciphertext; the server never sees the plaintext name).
  renameCircle(circleId: string, nameEncB64: string) {
    return request<CircleSummary>('PATCH', `/v1/circles/${circleId}`, { name_enc: nameEncB64 });
  },
  /// Leave a circle immediately (anti-stalking: no owner approval). A sole owner
  /// gets 409 — delete the circle instead.
  leaveCircle(circleId: string) {
    return request<{ status: string }>('POST', `/v1/circles/${circleId}/leave`);
  },
  /// Owner-only: delete the circle for everyone.
  deleteCircle(circleId: string) {
    return request<{ status: string }>('DELETE', `/v1/circles/${circleId}`);
  },
  /// Owner-only: remove another member. NOTE: removal does NOT revoke the copy of
  /// K_c they already hold (v1 has no forward secrecy), so the caller should offer
  /// to rotate the circle key right after.
  removeMember(circleId: string, userId: string) {
    return request<{ status: string }>('DELETE', `/v1/circles/${circleId}/members/${userId}`);
  },
  members(circleId: string) {
    return request<{ members: MemberDTO[] }>('GET', `/v1/circles/${circleId}/members`).then(
      (r) => r.members,
    );
  },
  /// Sets (or clears, with null) the caller's OWN per-circle profile blob. The
  /// body carries base64 ciphertext sealed under K_c — the server stores it as
  /// opaque bytes and never sees the nickname or avatar.
  setProfile(circleId: string, profileEnc: string | null) {
    return request<{ status: string }>('PUT', `/v1/circles/${circleId}/profile`, {
      profile_enc: profileEnc,
    });
  },
  latestPings(circleId: string) {
    return request<{ pings: RemotePing[] }>('GET', `/v1/circles/${circleId}/pings/latest`).then(
      (r) => r.pings,
    );
  },

  /// Uploads sealed pings for THIS device (the server derives the device from the
  /// session; each item names its circle and a client id for idempotency). The
  /// server only ever sees the ciphertext + nonce — never coordinates.
  postPings(
    pings: {
      circle_id: string;
      client_id: string;
      nonce: string;
      ciphertext: string;
      captured_at: string;
    }[],
  ) {
    return request<{ accepted?: number; stored?: number }>('POST', '/v1/pings/batch', { pings });
  },
  setPrecision(circleId: string, mode: string) {
    return request<{ precision_mode: string }>('PUT', `/v1/circles/${circleId}/precision`, {
      mode,
    });
  },

  // Mutes — the CALLER's own, per circle. Nothing here is E2EE: a mute is server
  // metadata by necessity, because the SERVER is what skips muted recipients when
  // it fans out /notify. That is also what makes it real: muting genuinely stops
  // the other members' notifications reaching this account, rather than hiding
  // them after delivery.
  /// The caller's mutes in one circle.
  circleMutes(circleId: string) {
    return request<MutesDTO>('GET', `/v1/circles/${circleId}/mutes`);
  },
  /// REPLACES the caller's whole mute set for the circle (not a patch) — send the
  /// complete desired state, and the server echoes it back.
  setCircleMutes(circleId: string, mutes: MutesDTO) {
    return request<MutesDTO>('PUT', `/v1/circles/${circleId}/mutes`, mutes);
  },

  // encrypted places (name + coords + geofence radius sealed under K_c)
  listPlaces(circleId: string) {
    return request<{ places: PlaceDTO[] }>('GET', `/v1/circles/${circleId}/places`).then(
      (r) => r.places,
    );
  },
  createPlace(circleId: string, ciphertext: string) {
    return request<PlaceDTO>('POST', `/v1/circles/${circleId}/places`, { ciphertext });
  },
  updatePlace(circleId: string, placeId: string, ciphertext: string, version: number) {
    return request<PlaceDTO>('PUT', `/v1/circles/${circleId}/places/${placeId}`, {
      ciphertext,
      version,
    });
  },
  deletePlace(circleId: string, placeId: string) {
    return request<{ status: string }>('DELETE', `/v1/circles/${circleId}/places/${placeId}`);
  },

  // SOS (sealed payload; server relays + fans out the alert)
  listSos(circleId: string) {
    return request<{ sos: SosDTO[] }>('GET', `/v1/circles/${circleId}/sos`).then((r) => r.sos);
  },
  createSos(circleId: string, ciphertext: string) {
    return request<SosDTO>('POST', `/v1/circles/${circleId}/sos`, { ciphertext });
  },
  resolveSos(circleId: string, sosId: string) {
    return request<SosDTO>('POST', `/v1/circles/${circleId}/sos/${sosId}/resolve`);
  },

  // invites
  createInvite(circleId: string, maxUses = 5, ttlSeconds?: number) {
    return request<InviteDTO>('POST', `/v1/circles/${circleId}/invites`, {
      max_uses: maxUses,
      ttl_seconds: ttlSeconds,
    });
  },
  getInvite(inviteId: string) {
    return request<{ circle_id: string; role: string; valid: boolean; expires_at: string }>(
      'GET',
      `/v1/invites/${inviteId}`,
    );
  },
  acceptInvite(inviteId: string) {
    return request<{ circle_id: string; status: string }>(
      'POST',
      `/v1/invites/${inviteId}/accept`,
    );
  },

  // live share: a time-boxed link that lets ONE outsider (no account) watch the
  // caller's live location. The position is sealed under a per-session K_share
  // that is generated in the browser and lives ONLY in the link's fragment — so
  // the server stores opaque ciphertext, and the viewer sees just the sharer,
  // just until the deadline.
  /// Creates a session. ttlSeconds is clamped by the server to 60..3600.
  createShare(ttlSeconds: number) {
    return request<{ id: string; expires_at: string }>('POST', '/v1/share', {
      ttl_seconds: ttlSeconds,
    });
  },
  /// The caller's own unexpired sessions.
  listShares() {
    return request<{ sessions: ShareSessionDTO[] }>('GET', '/v1/share').then((r) => r.sessions);
  },
  revokeShare(id: string) {
    return request<{ status: string }>('DELETE', `/v1/share/${id}`);
  },
  /// Owner-only: upserts the session's single latest sealed position.
  putSharePing(id: string, position: SharePositionDTO) {
    return request<{ status: string }>('PUT', `/v1/share/${id}/ping`, position);
  },
  /// PUBLIC — no auth, no account. `credentials: 'include'` is what lets the
  /// server set (and then recognise) the httpOnly cookie that binds the link to
  /// the FIRST viewer; without it every poll would look like a new device.
  /// Distinct failures the caller must handle, via ApiError.status:
  ///   403 — bound to a different device, 410 — expired/revoked, 404 — unknown.
  /// Never retries through /v1/auth/refresh: the viewer has no account to refresh.
  getShare(id: string) {
    return request<SharePublicDTO>('GET', `/v1/share/${id}`, undefined, false);
  },

  // circle member devices (identity public keys) — for key distribution + safety codes
  circleDevices(circleId: string) {
    return request<{ devices: { id: string; user_id: string; platform: string; pubkey: string | null }[] }>(
      'GET',
      `/v1/circles/${circleId}/devices`,
    ).then((r) => r.devices);
  },

  // key envelopes (sealed K_c distribution)
  pendingEnvelopes() {
    return request<{
      envelopes: {
        id: string;
        circle_id: string;
        sender_device_id: string | null;
        ciphertext: string;
        key_epoch: number;
        created_at: string;
      }[];
    }>('GET', '/v1/key-envelopes/pending').then((r) => r.envelopes);
  },
  postEnvelopes(
    circleId: string,
    envelopes: { recipient_device_id: string; ciphertext: string; key_epoch: number }[],
  ) {
    return request<{ delivered: number }>('POST', '/v1/key-envelopes', {
      circle_id: circleId,
      envelopes,
    });
  },
  consumeEnvelope(id: string) {
    return request<void>('POST', `/v1/key-envelopes/${id}/consume`);
  },
  rotateKey(circleId: string) {
    return request<{ key_epoch: number }>('POST', `/v1/circles/${circleId}/rotate-key`);
  },

  // Web Push (VAPID). The server relays OPAQUE sealed blobs to a circle's other
  // members and stores only the browser's push endpoint — never a plaintext
  // notification. See notifyCodec.ts for the payload format.
  /// Registers this browser's push subscription (from PushSubscription#toJSON).
  pushSubscribe(sub: { endpoint: string; p256dh: string; auth: string }) {
    return request<{ status: string }>('POST', '/v1/push/subscribe', sub);
  },
  pushUnsubscribe(endpoint: string) {
    return request<{ status: string }>('DELETE', '/v1/push/subscribe', { endpoint });
  },
  /// Asks the server to relay one sealed notification to the circle's OTHER
  /// members as a Web Push payload. `payloadEncB64` is base64 of
  /// sealFramed(json, K_c, "aul-notify:v1") — the server cannot read it. Returns
  /// 503 when the operator has not configured VAPID keys.
  notifyCircle(circleId: string, payloadEncB64: string) {
    return request<{ status: string; sent?: number }>('POST', `/v1/circles/${circleId}/notify`, {
      payload_enc: payloadEncB64,
    });
  },

  serverInfo() {
    return request<{
      e2ee: boolean;
      trusted_server_mode: boolean;
      public_origin: string;
      // Operator kill-switch for the opt-in retention features (arrival/ETA and
      // re-engagement). Older servers omit it; absence is treated as enabled (the
      // features still require a per-user opt-in that is OFF by default).
      retention_features_enabled?: boolean;
      // The VAPID application server public key (base64url) browsers need to
      // subscribe to Web Push. null — or absent, on an older server — means the
      // operator has not configured push: the background-notification opt-in is
      // hidden and nothing is relayed.
      vapid_public_key?: string | null;
    }>('GET', '/v1/server-info');
  },

  // public: the latest published client build for a platform. Throws ApiError
  // with status 404 ("no published version") when nothing is published yet.
  versionLatest(platform: 'android' | 'ios') {
    return request<AppVersion>('GET', `/v1/version/latest?platform=${platform}`);
  },
};
