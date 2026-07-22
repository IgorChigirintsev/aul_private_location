export type PrecisionMode = 'precise' | 'city' | 'paused';

export interface UserDTO {
  id: string;
  email: string;
}

/// The device the server resolved (or created) for this sign-in. Its `id` is
/// persisted client-side and echoed back on the next login so the same browser
/// keeps ONE device instead of minting a new row each re-auth.
export interface AuthDeviceDTO {
  id: string;
  platform: string;
  has_pubkey: boolean;
}

export interface AuthResult {
  user: UserDTO;
  device?: AuthDeviceDTO;
}

export interface CircleSummary {
  id: string;
  name_enc: string | null;
  retention_days: number;
  key_epoch: number;
  role: 'owner' | 'member' | 'guardian';
  precision_mode: PrecisionMode;
  created_at: string;
}

export interface MemberDTO {
  user_id: string;
  email: string;
  role: string;
  precision_mode: PrecisionMode;
  joined_at: string;
  /// The member's per-circle profile (nickname + avatar) sealed under K_c, or
  /// null if none set. base64 of sealFramed(json, K_c, "aul-profile:v1"). The
  /// server only ever relays this ciphertext — it never sees the plaintext.
  profile_enc?: string | null;
}

export interface RemotePing {
  id: string;
  circle_id: string;
  device_id: string;
  nonce: string; // base64
  ciphertext: string; // base64
  captured_at: string;
}

export interface InviteDTO {
  id: string;
  circle_id: string;
  role: string;
  max_uses: number;
  uses: number;
  expires_at: string;
  status: string;
}

/// Decrypted ping payload (what the reporter sealed).
export interface FixPayload {
  lat: number;
  lng: number;
  acc?: number;
  spd?: number;
  hdg?: number;
  batt?: number;
  ts: number;
  mode: PrecisionMode;
}

/// A member's current position on the map (decrypted client-side).
export interface MemberPosition {
  deviceId: string;
  lat: number;
  lng: number;
  accuracy?: number;
  battery?: number;
  /// Last-known ground speed in metres/second (from the sealed fix), used only
  /// for the client-side ETA estimate. Absent when the reporter sent no speed.
  speed?: number;
  mode: PrecisionMode;
  capturedAt: number;
  updatedAt: number;
}

/// A place as the server stores it: one opaque framed+padded ciphertext blob
/// (name + coordinates + radius sealed under K_c) plus concurrency metadata.
export interface PlaceDTO {
  id: string;
  ciphertext: string; // base64 sealFramed(pad(json))
  version: number;
  updated_at: string;
  /// The member who created the place. Server metadata — it is NOT part of the
  /// sealed blob, so the server knows who added a place but still never learns
  /// its name or coordinates. Absent on an older server.
  created_by?: string | null;
}

/// A decrypted place (client-side only — never sent to the server).
export interface Place {
  id: string;
  version: number;
  name: string;
  lat: number;
  lng: number;
  radius: number; // metres (geofence radius)
  /// User id of the member who created it (from PlaceDTO.created_by), resolved
  /// to a nickname through the profiles store for display.
  createdBy?: string | null;
}

/// The caller's own mutes in one circle (GET/PUT /v1/circles/{id}/mutes). The PUT
/// replaces the whole set, so both fields are always the complete desired state.
///
/// A mute is enforced SERVER-side: the server skips muted recipients when fanning
/// out /notify, so this genuinely stops the notifications reaching you rather
/// than merely hiding them once delivered.
export interface MutesDTO {
  /// Mute the whole circle: no member of it can notify this account.
  circle_muted: boolean;
  /// Individually muted members (user ids) within the circle.
  muted_user_ids: string[];
}

/// An SOS event as the server stores it (opaque ciphertext + metadata).
export interface SosDTO {
  id: string;
  circle_id: string;
  device_id?: string;
  ciphertext: string;
  created_at: string;
  resolved_at?: string;
}

/// A decrypted SOS event. `name`/coords may be absent if no key opened it — the
/// alert is still surfaced from metadata so a watcher is never left unaware.
export interface SosEvent {
  id: string;
  deviceId?: string;
  createdAt: string;
  lat?: number;
  lng?: number;
  message?: string;
  ts?: number;
  decrypted: boolean;
}

/// A published client build, as returned by GET /v1/version/latest.
/// `apk_url` and `sha256` may be empty strings if a build exists but no APK has
/// been attached yet. A 404 means no active version is published for the platform.
export interface AppVersion {
  version_code: number;
  version_name: string;
  apk_url: string;
  sha256: string;
  changelog: string;
  min_supported: number;
}

/// A live-share session as its OWNER sees it (GET /v1/share lists mine, unexpired).
/// The server knows only that the session exists and when it dies — never K_share,
/// and never a coordinate.
export interface ShareSessionDTO {
  id: string;
  created_at: string;
  expires_at: string;
  /// True once a viewer has opened the link: the server bound it to that one
  /// device (httpOnly cookie), and every other device now gets 403.
  viewer_bound: boolean;
  revoked: boolean;
}

/// The single latest sealed position of a live-share session (upserted by the
/// sharer, served to the bound viewer). Sealed under K_share — opaque to the server.
export interface SharePositionDTO {
  nonce: string; // base64
  ciphertext: string; // base64
  captured_at: string;
}

/// The PUBLIC view of a share session (GET /v1/share/{id}, no auth). `position`
/// is null until the sharer's browser has posted its first fix.
export interface SharePublicDTO {
  expires_at: string;
  position: SharePositionDTO | null;
}

/// Decrypted live-share payload. Deliberately narrower than FixPayload: a
/// stranger with a share link gets a point and nothing else — no battery, no
/// speed/heading, no precision mode.
export interface ShareFix {
  lat: number;
  lng: number;
  acc?: number;
  ts: number;
}

/// Realtime event envelope from /v1/realtime.
export interface RealtimeEvent {
  type: 'welcome' | 'ping' | 'sos' | 'sos_resolved' | 'place_updated' | 'member_changed' | 'precision_mode' | 'unsubscribed';
  circle_id?: string;
  payload?: unknown;
  circles?: string[];
}
