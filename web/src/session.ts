import { useQuery } from '@tanstack/react-query';

import { api } from './data/api';
import { keystore } from './data/keystore';
import { detectPlatform } from './data/platform';

/// `me()` doubles as the auth check: a 401 (thrown) means signed out.
export function useMe() {
  return useQuery({
    queryKey: ['me'],
    queryFn: () => api.me(),
    retry: false,
    staleTime: 60_000,
  });
}

/// Ensures a web identity keypair exists (weaker trust model — see THREAT_MODEL)
/// and returns its base64 public key to send to the server.
async function ensureIdentityPubkey(): Promise<string> {
  // Imported dynamically so `useMe` (which App needs on every route, including
  // the public landing) doesn't drag libsodium into the entry chunk.
  const { generateIdentityKeyPair, toBase64 } = await import('./crypto/aulCrypto');
  let id = await keystore.loadIdentity();
  if (!id) {
    const kp = generateIdentityKeyPair();
    await keystore.saveIdentity(kp.publicKey, kp.privateKey);
    id = kp;
  }
  return toBase64(id.publicKey);
}

export async function doRegister(email: string, password: string): Promise<void> {
  const res = await api.register(email, password, await ensureIdentityPubkey(), detectPlatform());
  if (res.device) await keystore.saveDeviceId(res.device.id);
}

export async function doLogin(email: string, password: string): Promise<void> {
  // Re-use the device this browser already owns (if any) so a repeat sign-in
  // adopts the existing device row instead of creating a duplicate — the map
  // draws one marker per device, so duplicates would show the same person twice.
  const deviceId = await keystore.loadDeviceId();
  const res = await api.login(email, password, await ensureIdentityPubkey(), deviceId, detectPlatform());
  if (res.device) await keystore.saveDeviceId(res.device.id);
}

export async function doLogout(): Promise<void> {
  try {
    await api.logout();
  } finally {
    await keystore.wipe();
  }
}
