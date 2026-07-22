import { describe, expect, it } from 'vitest';

import { STALE_MS, isStale } from '../src/data/freshness';

/// The honesty gate for a location-SAFETY app: past this age a fix must stop
/// looking live (dimmed marker, "stale" badge, dropped from geofence presence).
/// The boundary is the whole point — one minute either side flips whether a
/// viewer is trusting a position that can no longer be refreshed.
describe('isStale — position freshness boundary', () => {
  const now = 1_700_000_000_000;

  it('a just-captured fix is fresh', () => {
    expect(isStale(now, now)).toBe(false);
  });

  it('a fix one millisecond under the threshold is still fresh', () => {
    expect(isStale(now - (STALE_MS - 1), now)).toBe(false);
  });

  it('a fix exactly at the threshold is stale (inclusive boundary)', () => {
    expect(isStale(now - STALE_MS, now)).toBe(true);
  });

  it('a fix well past the threshold is stale', () => {
    expect(isStale(now - (STALE_MS + 60_000), now)).toBe(true);
  });

  it('falls back to the current clock when `now` is omitted', () => {
    expect(isStale(Date.now() - (STALE_MS + 60_000))).toBe(true);
    expect(isStale(Date.now())).toBe(false);
  });

  it('shares the 15-minute window with the geofence freshness notion', () => {
    expect(STALE_MS).toBe(15 * 60 * 1000);
  });
});
