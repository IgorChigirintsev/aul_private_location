import { fromBase64, openFramed, sealFramed, toBase64 } from '../crypto/aulCrypto';

/// Domain-separation associated data for a background-push notification blob, so
/// a notify ciphertext can't be replayed as a place/SOS/profile (or vice-versa).
/// Same mechanism as places' "aul-place:v1" (D-0034). Both ends of this format
/// live in this repo: the dashboard seals (GeofenceFeed), the service worker
/// opens (src/sw.ts).
export const NOTIFY_AD = new TextEncoder().encode('aul-notify:v1');

/// Hard ceiling the server enforces on POST /v1/circles/{id}/notify: 3 KiB of
/// DECODED payload (Web Push itself only guarantees ~4 KiB). We stay far below
/// it by clamping the two free-text fields — see MAX_FIELD_CHARS.
export const MAX_NOTIFY_BYTES = 3 * 1024;

/// Free-text fields (a place name, a member's nickname) come from user input and
/// have no length limit of their own, so clamp them before sealing: a pathological
/// 50 KB nickname must not blow the payload budget (and would be unreadable in a
/// notification anyway). Generous enough that real names/places survive intact.
const MAX_FIELD_CHARS = 64;

/// The plaintext of a background notification. Terse and small on purpose: the
/// blob is relayed by the server as the opaque Web Push payload, so every byte
/// counts against MAX_NOTIFY_BYTES.
///   t     — what happened ('arrival' | 'departure')
///   place — the place name (plaintext; the server never sees it)
///   who   — the member's nickname, falling back to their email
///   ts    — epoch ms of the transition
export interface NotifyPayload {
  t: 'arrival' | 'departure';
  place: string;
  who: string;
  ts: number;
}

/// Truncates to MAX_FIELD_CHARS *code points* (not UTF-16 units), so clamping
/// never splits a surrogate pair (an emoji nickname) into a lone half.
function clamp(s: string): string {
  const cps = [...s];
  return cps.length <= MAX_FIELD_CHARS ? s : cps.slice(0, MAX_FIELD_CHARS).join('');
}

/// Seals a notification under K_c into the base64 blob the server relays.
/// Throws if the result would exceed MAX_NOTIFY_BYTES (it cannot with clamped
/// fields — the check is a belt-and-braces guard against a future field being
/// added without a budget).
export function sealNotify(payload: NotifyPayload, key: Uint8Array): string {
  const small: NotifyPayload = {
    t: payload.t,
    place: clamp(payload.place),
    who: clamp(payload.who),
    ts: payload.ts,
  };
  const plain = new TextEncoder().encode(JSON.stringify(small));
  const sealed = sealFramed(plain, key, NOTIFY_AD);
  if (sealed.length > MAX_NOTIFY_BYTES) {
    throw new Error(`notify payload too large: ${sealed.length} > ${MAX_NOTIFY_BYTES} bytes`);
  }
  return toBase64(sealed);
}

/// Opens a relayed notify blob, trying every key it is given (every circle's
/// whole keyring — the push carries no circle id, and rotation means a circle
/// has several). Never throws: returns null when the input is malformed, when no
/// key opens it (a circle this device has no key for), or when the plaintext
/// isn't a well-formed payload. Callers show a generic notification on null —
/// they must never leak anything about an undecryptable push.
export function openNotify(b64: string, keys: Uint8Array[]): NotifyPayload | null {
  let blob: Uint8Array;
  try {
    blob = fromBase64(b64);
  } catch {
    return null;
  }
  for (const key of keys) {
    try {
      const plain = openFramed(blob, key, NOTIFY_AD);
      const p: unknown = JSON.parse(new TextDecoder().decode(plain));
      if (isNotifyPayload(p)) return { t: p.t, place: clamp(p.place), who: clamp(p.who), ts: p.ts };
      return null; // authentic but malformed — no other key can do better
    } catch {
      /* wrong key, wrong AD, or corrupt — try the next key */
    }
  }
  return null;
}

function isNotifyPayload(p: unknown): p is NotifyPayload {
  if (p === null || typeof p !== 'object') return false;
  const o = p as Record<string, unknown>;
  return (
    (o.t === 'arrival' || o.t === 'departure') &&
    typeof o.place === 'string' &&
    typeof o.who === 'string' &&
    typeof o.ts === 'number'
  );
}
