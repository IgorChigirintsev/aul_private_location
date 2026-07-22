import { fromBase64, openFramed, pad, sealFramed, toBase64, unpad } from '../crypto/aulCrypto';
import type { Place, PlaceDTO, SosDTO, SosEvent } from './types';

/// Fixed padding block for place/SOS payloads. Padding BEFORE sealing hides the
/// plaintext length so a place name ("Mom's house" vs "Gym") or an SOS message
/// can't leak via ciphertext size. MUST match the reporter app (Dart PlaceCodec
/// padBlock) and the pinned cross-language vector.
export const PAD_BLOCK = 256;

/// Domain-separation associated data: binds each ciphertext to its field type so
/// a place blob can't be replayed as an SOS (or vice-versa). Must match the app.
const PLACE_AD = new TextEncoder().encode('aul-place:v1');
const SOS_AD = new TextEncoder().encode('aul-sos:v1');

/// On-the-wire place payload — terse keys (matches the Dart PlaceCodec schema):
/// n=name, lat/lng=centre, rad=geofence radius in metres.
interface PlacePayload {
  n: string;
  lat: number;
  lng: number;
  rad: number;
}

/// Seals a place into the single framed+padded ciphertext the server stores
/// (nonce||ct, base64). The server never sees any of these fields.
export function sealPlace(
  place: { name: string; lat: number; lng: number; radius: number },
  key: Uint8Array,
): string {
  const payload: PlacePayload = { n: place.name, lat: place.lat, lng: place.lng, rad: place.radius };
  const plain = pad(new TextEncoder().encode(JSON.stringify(payload)), PAD_BLOCK);
  return toBase64(sealFramed(plain, key, PLACE_AD));
}

/// Opens a place DTO, trying every key in the circle keyring (rotation-safe).
/// Returns null if no key opens it (e.g. sealed under a key this device lacks).
///
/// `created_by` rides along untouched: it is server metadata, never part of the
/// sealed blob, so it needs no key — the NAME is what stays E2EE.
export function openPlace(dto: PlaceDTO, keyring: Uint8Array[]): Place | null {
  const blob = fromBase64(dto.ciphertext);
  for (const key of keyring) {
    try {
      const plain = unpad(openFramed(blob, key, PLACE_AD), PAD_BLOCK);
      const p = JSON.parse(new TextDecoder().decode(plain)) as PlacePayload;
      return {
        id: dto.id,
        version: dto.version,
        name: p.n,
        lat: p.lat,
        lng: p.lng,
        radius: p.rad,
        createdBy: dto.created_by ?? null,
      };
    } catch {
      /* try the next key */
    }
  }
  return null;
}

/// On-the-wire SOS payload: optional last-known location + free-text message.
interface SosPayload {
  lat?: number;
  lng?: number;
  msg?: string;
  ts: number;
}

/// Seals an SOS payload under K_c into the single framed+padded ciphertext.
export function sealSos(payload: SosPayload, key: Uint8Array): string {
  const plain = pad(new TextEncoder().encode(JSON.stringify(payload)), PAD_BLOCK);
  return toBase64(sealFramed(plain, key, SOS_AD));
}

/// Opens an SOS DTO with the keyring. If no key opens it, the alert is STILL
/// returned (decrypted:false) from server metadata — a watcher must never miss an
/// SOS just because the payload can't be read.
export function openSos(dto: SosDTO, keyring: Uint8Array[]): SosEvent {
  const meta: SosEvent = { id: dto.id, deviceId: dto.device_id, createdAt: dto.created_at, decrypted: false };
  let blob: Uint8Array;
  try {
    blob = fromBase64(dto.ciphertext);
  } catch {
    return meta; // malformed ciphertext — still surface the alert from metadata
  }
  for (const key of keyring) {
    try {
      const plain = unpad(openFramed(blob, key, SOS_AD), PAD_BLOCK);
      const p = JSON.parse(new TextDecoder().decode(plain)) as SosPayload;
      return { ...meta, lat: p.lat, lng: p.lng, message: p.msg, ts: p.ts, decrypted: true };
    } catch {
      /* try the next key */
    }
  }
  return meta;
}
