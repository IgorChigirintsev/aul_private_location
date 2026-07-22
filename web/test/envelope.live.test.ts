import { beforeAll, describe, expect, it } from 'vitest';

import {
  fromBase64,
  generateIdentityKeyPair,
  initCrypto,
  openSealed,
  randomCircleKey,
  sealToPublicKey,
  toBase64,
} from '../src/crypto/aulCrypto';

// Live validation of the Phase-4 key-envelope path against the real server:
// seal K_c to a device's identity public key → POST it → the server relays a box
// it cannot open → the device fetches it and opens it with its private key,
// recovering K_c. Skips if no server is reachable. Uses Bearer auth (node).
const SERVER = process.env.AUL_TEST_SERVER ?? 'http://127.0.0.1:8080';

let up = false;
try {
  up = (await fetch(`${SERVER}/healthz`)).ok;
} catch {
  up = false;
}

describe.runIf(up)('key envelope round-trip (live)', () => {
  beforeAll(async () => {
    await initCrypto();
  });

  it('recovers K_c sealed to a device identity key via a relayed envelope', async () => {
    const identity = generateIdentityKeyPair();
    const email = `envelope+${Date.now()}@example.com`;

    const reg = await fetch(`${SERVER}/v1/auth/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        email,
        password: 'envelope-strong-pass',
        platform: 'web',
        pubkey: toBase64(identity.publicKey),
      }),
    });
    expect(reg.ok).toBe(true);
    const auth = await reg.json();
    const token: string = auth.access_token;
    const deviceId: string = auth.device.id;
    const bearer = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };

    // Create a circle and its key.
    const circleRes = await fetch(`${SERVER}/v1/circles`, {
      method: 'POST',
      headers: bearer,
      body: JSON.stringify({ retention_days: 7 }),
    });
    const circle = await circleRes.json();
    const circleId: string = circle.id;
    const kc = randomCircleKey();

    // Seal K_c to this device's identity public key and post the envelope.
    const sealed = sealToPublicKey(kc, identity.publicKey);
    const post = await fetch(`${SERVER}/v1/key-envelopes`, {
      method: 'POST',
      headers: bearer,
      body: JSON.stringify({
        circle_id: circleId,
        envelopes: [
          { recipient_device_id: deviceId, ciphertext: toBase64(sealed), key_epoch: 1 },
        ],
      }),
    });
    expect(post.ok).toBe(true);
    expect((await post.json()).delivered).toBe(1);

    // Fetch the pending envelope and open it with the identity private key.
    const pendingRes = await fetch(`${SERVER}/v1/key-envelopes/pending`, { headers: bearer });
    const { envelopes } = await pendingRes.json();
    expect(envelopes.length).toBeGreaterThan(0);
    const env = envelopes[0];

    const recovered = openSealed(
      fromBase64(env.ciphertext),
      identity.publicKey,
      identity.privateKey,
    );
    expect(recovered).toEqual(kc); // K_c travelled sealed; the server never saw it

    // Consume it.
    const consume = await fetch(`${SERVER}/v1/key-envelopes/${env.id}/consume`, {
      method: 'POST',
      headers: bearer,
    });
    expect(consume.ok).toBe(true);
  });
});
