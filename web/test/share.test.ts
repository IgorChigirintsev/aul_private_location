import { beforeAll, describe, expect, it } from 'vitest';

import {
  fromBase64,
  fromBase64Url,
  initCrypto,
  randomCircleKey,
  toBase64,
  toBase64Url,
  CIRCLE_KEY_BYTES,
} from '../src/crypto/aulCrypto';
import { openShareFix, sealShareFix } from '../src/data/shareCodec';
import { formatCountdown, msUntil } from '../src/data/format';
import type { ShareFix } from '../src/data/types';

// NOTE ON SCOPE: the viewer page (features/ShareView.tsx) and its map are not
// unit-tested here. This suite runs in the `node` environment with no DOM, and
// the page's substance is a maplibre canvas plus browser focus/visibility events
// — neither of which jsdom reproduces faithfully enough for the test to mean
// anything. What IS testable is everything the page's correctness rests on: the
// seal/open round-trip under K_share (including that a wrong key leaks nothing),
// the fragment encoding that carries K_share, and the expiry/countdown helper
// that decides when the share goes dark. Those are covered below; driving the
// page itself belongs in the Playwright suite.

beforeAll(async () => {
  await initCrypto();
});

const fix: ShareFix = { lat: 43.238949, lng: 76.889709, acc: 12.5, ts: 1_760_000_000_000 };

describe('live-share position codec (K_share)', () => {
  it('round-trips a fix through seal → open with the session key', () => {
    const kShare = randomCircleKey();
    const sealed = sealShareFix(fix, kShare);
    expect(openShareFix(sealed.nonce, sealed.ciphertext, kShare)).toEqual(fix);
  });

  it('stamps captured_at from the fix timestamp', () => {
    const sealed = sealShareFix(fix, randomCircleKey());
    expect(sealed.captured_at).toBe(new Date(fix.ts).toISOString());
  });

  it('pads every position to one fixed size, whatever the coordinates', () => {
    const kShare = randomCircleKey();
    const tiny = sealShareFix({ lat: 0, lng: 0, ts: 1 }, kShare);
    const big = sealShareFix({ lat: -33.868821, lng: 151.209296, acc: 1234.5678, ts: 1_760_000_000_000 }, kShare);
    // Same ciphertext length ⇒ the blob's size tells the server nothing.
    expect(tiny.ciphertext.length).toBe(big.ciphertext.length);
  });

  it('leaks NOTHING to a wrong key — no partial plaintext, no throw', () => {
    const sealed = sealShareFix(fix, randomCircleKey());
    const wrong = randomCircleKey();
    expect(openShareFix(sealed.nonce, sealed.ciphertext, wrong)).toBeNull();
    // The circle key must not open a share either: the whole point is that a
    // share is sealed under its own per-session key.
    expect(openShareFix(sealed.nonce, sealed.ciphertext, randomCircleKey())).toBeNull();
  });

  it('rejects a tampered ciphertext (AEAD fails closed)', () => {
    const kShare = randomCircleKey();
    const sealed = sealShareFix(fix, kShare);
    const bytes = fromBase64(sealed.ciphertext);
    bytes[0] ^= 0xff; // flip a byte of the sealed coordinates
    expect(openShareFix(sealed.nonce, toBase64(bytes), kShare)).toBeNull();
  });

  it('returns null for garbage instead of throwing into the viewer', () => {
    expect(openShareFix('not-base64!!', 'also-garbage!!', randomCircleKey())).toBeNull();
  });
});

describe('K_share link fragment (base64url)', () => {
  it('round-trips a generated key through the fragment encoding', () => {
    const kShare = randomCircleKey();
    const fragment = toBase64Url(kShare);
    expect(fragment).toMatch(/^[A-Za-z0-9_-]+$/); // URL-safe, unpadded — survives a `#`
    expect(fragment).not.toContain('=');
    expect(fromBase64Url(fragment)).toEqual(kShare);
  });

  it('generates a 32-byte key, and a fresh one every time', () => {
    const a = randomCircleKey();
    const b = randomCircleKey();
    expect(a.length).toBe(CIRCLE_KEY_BYTES);
    expect(toBase64Url(a)).not.toBe(toBase64Url(b));
  });

  it('survives the full link → fragment → key path a viewer takes', () => {
    const kShare = randomCircleKey();
    const link = `https://aul.app/s/2f1c8a4e-0000-4000-8000-000000000000#${toBase64Url(kShare)}`;
    const fragment = new URL(link).hash.replace(/^#/, '');
    const recovered = fromBase64Url(fragment);
    expect(recovered).toEqual(kShare);
    // …and that recovered key really does open the sharer's position.
    const sealed = sealShareFix(fix, kShare);
    expect(openShareFix(sealed.nonce, sealed.ciphertext, recovered)).toEqual(fix);
  });
});

describe('countdown / expiry helper', () => {
  const now = Date.parse('2026-07-15T12:00:00.000Z');
  const at = (iso: string) => msUntil(iso, now);

  it('counts down to a future deadline', () => {
    expect(at('2026-07-15T12:15:00.000Z')).toBe(15 * 60_000);
    expect(at('2026-07-15T12:00:01.000Z')).toBe(1000);
  });

  it('floors at zero once the deadline passes (never negative)', () => {
    expect(at('2026-07-15T12:00:00.000Z')).toBe(0);
    expect(at('2026-07-15T11:59:59.000Z')).toBe(0);
    expect(at('2025-01-01T00:00:00.000Z')).toBe(0);
  });

  it('treats a missing or unparseable deadline as expired (fails CLOSED)', () => {
    // This drives whether a live location stays on screen: garbage must stop the
    // share, never extend it.
    expect(at('')).toBe(0);
    expect(at('tomorrow-ish')).toBe(0);
    expect(msUntil(null, now)).toBe(0);
    expect(msUntil(undefined, now)).toBe(0);
  });

  it('formats mm:ss, rolling over to h:mm:ss past an hour', () => {
    expect(formatCountdown(0)).toBe('00:00');
    expect(formatCountdown(9_000)).toBe('00:09');
    expect(formatCountdown(60_000)).toBe('01:00');
    expect(formatCountdown(15 * 60_000)).toBe('15:00');
    expect(formatCountdown(59 * 60_000 + 59_000)).toBe('59:59');
    expect(formatCountdown(60 * 60_000)).toBe('1:00:00'); // the 60-min maximum
  });

  it('never renders a negative countdown', () => {
    expect(formatCountdown(-5_000)).toBe('00:00');
  });

  it('rounds up, so the last second reads 00:01 rather than 00:00', () => {
    expect(formatCountdown(1)).toBe('00:01');
    expect(formatCountdown(999)).toBe('00:01');
  });
});
