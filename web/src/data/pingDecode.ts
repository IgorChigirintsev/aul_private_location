import { fromBase64, openPing, unpad } from '../crypto/aulCrypto';
import type { FixPayload, MemberPosition, RemotePing } from './types';

/// Must match the reporter's PingCodec padBlock (Dart: 256).
const PAD_BLOCK = 256;

/// Decrypts a sealed ping into its plaintext fix, trying each key in the circle
/// keyring (rotation-safe — history sealed under an old key still opens). Throws
/// if no key works.
export function decryptPing(ping: RemotePing, keyring: Uint8Array[]): FixPayload {
  const nonce = fromBase64(ping.nonce);
  const ct = fromBase64(ping.ciphertext);
  for (const key of keyring) {
    try {
      const plain = unpad(openPing(nonce, ct, key), PAD_BLOCK);
      return JSON.parse(new TextDecoder().decode(plain)) as FixPayload;
    } catch {
      /* try the next key */
    }
  }
  throw new Error('no circle key opened this ping');
}

/// Decrypts a ping into a map-ready MemberPosition (returns null on failure).
export function pingToPosition(ping: RemotePing, keyring: Uint8Array[]): MemberPosition | null {
  try {
    const fix = decryptPing(ping, keyring);
    return {
      deviceId: ping.device_id,
      lat: fix.lat,
      lng: fix.lng,
      accuracy: fix.acc,
      battery: fix.batt,
      speed: fix.spd,
      mode: fix.mode,
      capturedAt: fix.ts,
      updatedAt: Date.now(),
    };
  } catch {
    return null; // no key opened it — skip silently
  }
}
