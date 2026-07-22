import { fromBase64, openPing, pad, sealPing, toBase64, unpad } from '../crypto/aulCrypto';
import type { ShareFix, SharePositionDTO } from './types';

/// Same 256-byte block as the circle ping codec: every sealed position is one
/// fixed-size blob, so its length leaks nothing about the coordinates.
const PAD_BLOCK = 256;

/// Seals a live-share position under K_share — the per-session key that exists
/// only in the sharer's browser and the link fragment. Byte-for-byte the circle
/// ping layout (pad → XChaCha20-Poly1305 → base64), just under a different key,
/// so the server sees the same opaque shape it always does.
export function sealShareFix(fix: ShareFix, key: Uint8Array): SharePositionDTO {
  const plain = new TextEncoder().encode(JSON.stringify(fix));
  const { nonce, ciphertext } = sealPing(pad(plain, PAD_BLOCK), key);
  return {
    nonce: toBase64(nonce),
    ciphertext: toBase64(ciphertext),
    captured_at: new Date(fix.ts).toISOString(),
  };
}

/// Opens a sealed position with K_share from the link fragment. Returns null —
/// never a partial result — for a wrong key, a corrupt blob or a payload that
/// isn't a coordinate: the AEAD tag fails closed, so a viewer with the wrong key
/// learns nothing at all.
export function openShareFix(nonce: string, ciphertext: string, key: Uint8Array): ShareFix | null {
  try {
    const plain = unpad(openPing(fromBase64(nonce), fromBase64(ciphertext), key), PAD_BLOCK);
    const fix = JSON.parse(new TextDecoder().decode(plain)) as ShareFix;
    if (!Number.isFinite(fix?.lat) || !Number.isFinite(fix?.lng)) return null;
    return fix;
  } catch {
    return null;
  }
}
