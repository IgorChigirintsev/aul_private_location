import { fromBase64, openFramed, sealFramed, toBase64 } from '../crypto/aulCrypto';

/// Domain-separation associated data for a member's per-circle profile blob,
/// so a profile ciphertext can't be replayed as a place/SOS (or vice-versa).
/// Same mechanism as places' "aul-place:v1" (D-0034).
export const PROFILE_AD = new TextEncoder().encode('aul-profile:v1');

/// A decrypted member profile. Both fields optional — an empty nick falls back
/// to the email, and a missing avatar falls back to the first letter.
export interface Profile {
  nick?: string;
  avatar?: string;
}

/// Seals a profile under K_c into the base64 blob the server relays. `nick` is
/// always present in the JSON (may be an empty string); `avatar` is only added
/// when set, so a profile with no picture stays small.
export function sealProfile(profile: { nick: string; avatar?: string }, key: Uint8Array): string {
  const payload = { nick: profile.nick, ...(profile.avatar ? { avatar: profile.avatar } : {}) };
  const plain = new TextEncoder().encode(JSON.stringify(payload));
  return toBase64(sealFramed(plain, key, PROFILE_AD));
}

/// Opens a profile blob, trying every key in the circle keyring (rotation-safe).
/// Never throws: returns null if the input is malformed or no key opens it.
export function openProfile(b64: string, keyring: Uint8Array[]): Profile | null {
  let blob: Uint8Array;
  try {
    blob = fromBase64(b64);
  } catch {
    return null;
  }
  for (const key of keyring) {
    try {
      const plain = openFramed(blob, key, PROFILE_AD);
      const p = JSON.parse(new TextDecoder().decode(plain)) as Profile;
      return { nick: p.nick, avatar: p.avatar };
    } catch {
      /* try the next key */
    }
  }
  return null;
}
