import { beforeAll, describe, expect, it } from 'vitest';

import { initCrypto, pad, randomCircleKey, sealPing, toBase64 } from '../src/crypto/aulCrypto';
import { pingToPosition } from '../src/data/pingDecode';
import { usePositions } from '../src/store/positions';
import type { FixPayload, RemotePing } from '../src/data/types';

function sealFix(fix: FixPayload, key: Uint8Array): RemotePing {
  const plain = pad(new TextEncoder().encode(JSON.stringify(fix)), 256);
  const { nonce, ciphertext } = sealPing(plain, key);
  return {
    id: crypto.randomUUID(),
    circle_id: 'c1',
    device_id: 'device-1',
    nonce: toBase64(nonce),
    ciphertext: toBase64(ciphertext),
    captured_at: new Date(fix.ts).toISOString(),
  };
}

beforeAll(async () => {
  await initCrypto();
});

describe('realtime decrypt pipeline (the "see movement" core)', () => {
  it('decrypts a sealed ping into a map position', () => {
    const key = randomCircleKey();
    const fix: FixPayload = { lat: 43.238949, lng: 76.889709, batt: 90, ts: Date.now(), mode: 'precise' };
    const pos = pingToPosition(sealFix(fix, key), [key]);
    expect(pos).not.toBeNull();
    expect(pos!.lat).toBeCloseTo(43.238949, 6);
    expect(pos!.lng).toBeCloseTo(76.889709, 6);
    expect(pos!.battery).toBe(90);
  });

  it('returns null for a ping sealed with a different circle key', () => {
    const key = randomCircleKey();
    const other = randomCircleKey();
    const ping = sealFix({ lat: 1, lng: 2, ts: Date.now(), mode: 'precise' }, key);
    expect(pingToPosition(ping, [other])).toBeNull();
  });

  it('store keeps only the newest capture per device (movement over time)', () => {
    const store = usePositions.getState();
    store.reset();
    const key = randomCircleKey();
    const t0 = Date.now();
    const p1 = pingToPosition(sealFix({ lat: 10, lng: 10, ts: t0, mode: 'precise' }, key), [key])!;
    const p2 = pingToPosition(sealFix({ lat: 11, lng: 11, ts: t0 + 5000, mode: 'precise' }, key), [key])!;
    store.upsert(p1);
    store.upsert(p2);
    // An out-of-order older ping must NOT roll the marker back.
    const stale = pingToPosition(sealFix({ lat: 9, lng: 9, ts: t0 - 5000, mode: 'precise' }, key), [key])!;
    store.upsert(stale);
    const cur = usePositions.getState().positions['device-1'];
    expect(cur.lat).toBe(11); // moved to the newest fix and stayed
  });
});
