import { beforeAll, describe, expect, it } from 'vitest';

import {
  MAX_NOTIFY_BYTES,
  NOTIFY_AD,
  openNotify,
  sealNotify,
  type NotifyPayload,
} from '../src/data/notifyCodec';
import {
  fromBase64,
  initCrypto,
  randomCircleKey,
  sealFramed,
  toBase64,
} from '../src/crypto/aulCrypto';

/// The background-push payload: the dashboard seals it under K_c, the server
/// relays the blob without being able to read it, and the service worker opens
/// it to build the notification text. The SW itself cannot be unit-tested here
/// (it needs a real ServiceWorkerGlobalScope + a push event); these tests pin the
/// format on both ends, which is the part the two share.
describe('notify payload', () => {
  beforeAll(async () => {
    await initCrypto();
  });

  const payload: NotifyPayload = { t: 'arrival', place: 'Home', who: 'Ann', ts: 1_700_000_000_000 };

  it('round-trips through seal → open', () => {
    const key = randomCircleKey();
    const opened = openNotify(sealNotify(payload, key), [key]);
    expect(opened).toEqual(payload);
  });

  it('round-trips a departure with non-ASCII text', () => {
    const key = randomCircleKey();
    const p: NotifyPayload = { t: 'departure', place: 'Школа 🎒', who: 'Боря', ts: Date.now() };
    expect(openNotify(sealNotify(p, key), [key])).toEqual(p);
  });

  it('opens with any key in the ring (rotation-safe)', () => {
    const older = randomCircleKey();
    const newer = randomCircleKey();
    const sealed = sealNotify(payload, older);
    // The SW hands over every key it holds, newest first or not — either opens.
    expect(openNotify(sealed, [newer, older])).toEqual(payload);
  });

  it('leaks nothing to the WRONG key — returns null, never throws', () => {
    const sealed = sealNotify(payload, randomCircleKey());
    expect(openNotify(sealed, [randomCircleKey()])).toBeNull();
    expect(openNotify(sealed, [])).toBeNull();
  });

  it('leaks nothing under the WRONG associated data (domain separation)', () => {
    const key = randomCircleKey();
    // Byte-identical plaintext + key, sealed as a *place* blob: the notify AD
    // must refuse it, so a place ciphertext can never be replayed as a push.
    const asPlace = toBase64(
      sealFramed(
        new TextEncoder().encode(JSON.stringify(payload)),
        key,
        new TextEncoder().encode('aul-place:v1'),
      ),
    );
    expect(openNotify(asPlace, [key])).toBeNull();

    // ...and the reverse: our blob does not open as anything but "aul-notify:v1".
    const sealed = sealNotify(payload, key);
    expect(openNotify(sealed, [key])).toEqual(payload); // sanity: the AD that DOES match
    expect(NOTIFY_AD).toEqual(new TextEncoder().encode('aul-notify:v1'));
  });

  it('never throws on malformed input', () => {
    const key = randomCircleKey();
    expect(openNotify('not base64 !!!', [key])).toBeNull();
    expect(openNotify('', [key])).toBeNull();
    expect(openNotify(toBase64(new Uint8Array(8)), [key])).toBeNull(); // shorter than a nonce
  });

  it('rejects an authentic blob whose plaintext is not a notify payload', () => {
    const key = randomCircleKey();
    const junk = toBase64(sealFramed(new TextEncoder().encode('{"t":"nope"}'), key, NOTIFY_AD));
    expect(openNotify(junk, [key])).toBeNull();
  });

  it('stays far under the 3 KiB relay limit, even for absurd input', () => {
    const key = randomCircleKey();
    const huge: NotifyPayload = {
      t: 'arrival',
      place: '🏠'.repeat(5_000),
      who: 'A'.repeat(50_000),
      ts: Date.now(),
    };
    const sealed = fromBase64(sealNotify(huge, key));
    expect(sealed.length).toBeLessThanOrEqual(MAX_NOTIFY_BYTES);
    // A realistic payload is an order of magnitude smaller than the budget.
    expect(fromBase64(sealNotify(payload, key)).length).toBeLessThan(200);
  });

  it('clamps the free-text fields without corrupting them', () => {
    const key = randomCircleKey();
    const opened = openNotify(
      sealNotify({ ...payload, who: '🐶'.repeat(100), place: 'x'.repeat(100) }, key),
      [key],
    );
    // Truncated to 64 code points — and emoji survive as whole characters
    // (a naive .slice() would leave a lone surrogate half).
    expect([...(opened?.who ?? '')]).toHaveLength(64);
    expect(opened?.who).toBe('🐶'.repeat(64));
    expect(opened?.place).toBe('x'.repeat(64));
  });
});
