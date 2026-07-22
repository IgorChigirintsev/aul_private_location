import { afterEach, describe, expect, it, vi } from 'vitest';

import {
  __resetGeoSourceForTests,
  requestFix,
  subscribeGeolocation,
  type GeoFix,
} from '../src/data/geoSource';
import { shouldPost, supersedes } from '../src/data/webReporter';

/// The reporting side of "the map shows me where I am not".
///
/// The owner's only device is a desktop browser: no GPS, located from Wi-Fi, and
/// — crucially — SITTING STILL. Every bug below is invisible on a phone in a
/// pocket and permanent on a PC on a desk, which is why none of them were caught
/// until a real person looked at their own marker.

interface Call {
  ok: (p: GeolocationPosition) => void;
  opts: PositionOptions;
}

function stubGeolocation(): { watches: Call[]; oneShots: Call[] } {
  const watches: Call[] = [];
  const oneShots: Call[] = [];
  vi.stubGlobal('navigator', {
    geolocation: {
      watchPosition: (ok: Call['ok'], _err: unknown, opts: PositionOptions) => {
        watches.push({ ok, opts });
        return watches.length;
      },
      getCurrentPosition: (ok: Call['ok'], _err: unknown, opts: PositionOptions) => {
        oneShots.push({ ok, opts });
      },
      clearWatch: () => {},
    },
  });
  return { watches, oneShots };
}

function position(at: number, accuracy = 20): GeolocationPosition {
  return {
    coords: { latitude: 43.238, longitude: 76.889, accuracy } as GeolocationCoordinates,
    timestamp: at,
  } as GeolocationPosition;
}

function fix(at: number, accuracy: number): GeoFix {
  return { coords: { accuracy } as GeolocationCoordinates, at };
}

afterEach(() => {
  __resetGeoSourceForTests();
  vi.unstubAllGlobals();
});

describe('geoSource', () => {
  it('asks for high accuracy on the FIRST fix, not only in the watch', () => {
    const { watches, oneShots } = stubGeolocation();
    subscribeGeolocation({ highAccuracy: true, onFix: () => {} });

    // The regression: the immediate kick omitted enableHighAccuracy entirely, so
    // it defaulted to false. On a device that never moves, the watch never fires
    // again — that coarse first answer WAS the position, for the whole session.
    expect(watches[0].opts.enableHighAccuracy).toBe(true);
    expect(oneShots).toHaveLength(1);
    expect(oneShots[0].opts.enableHighAccuracy).toBe(true);
  });

  it('carries the platform fix time, not the time we happened to receive it', () => {
    const { watches } = stubGeolocation();
    const seen: GeoFix[] = [];
    subscribeGeolocation({ highAccuracy: true, onFix: (f) => seen.push(f) });

    const takenAt = Date.now() - 240_000; // a cached fix, four minutes old
    watches[0].ok(position(takenAt));

    // maximumAge lets the browser answer from cache. If the consumer stamps its
    // own clock on that, a four-minute-old position is published as "just now".
    expect(seen[0].at).toBe(takenAt);
  });

  it('re-asks on demand, which is the only way a stationary device improves', () => {
    const { oneShots } = stubGeolocation();
    subscribeGeolocation({ highAccuracy: true, onFix: () => {} });
    expect(oneShots).toHaveLength(1); // the kick

    requestFix(30_000);

    expect(oneShots).toHaveLength(2);
    expect(oneShots[1].opts.maximumAge).toBe(30_000);
    expect(oneShots[1].opts.enableHighAccuracy).toBe(true);
  });

  it('does not ask the platform for anything once nobody is listening', () => {
    const { oneShots } = stubGeolocation();
    const unsubscribe = subscribeGeolocation({ highAccuracy: true, onFix: () => {} });
    unsubscribe();

    requestFix();

    expect(oneShots).toHaveLength(1); // still just the kick: no zombie scanning
  });
});

describe('supersedes', () => {
  const now = 1_700_000_000_000;

  it('takes the first fix it is offered', () => {
    expect(supersedes(fix(now, 500), null)).toBe(true);
  });

  it('never goes backwards in time', () => {
    const held = fix(now, 20);
    expect(supersedes(fix(now - 1_000, 5), held)).toBe(false);
    expect(supersedes(fix(now, 5), held)).toBe(false); // same fix, re-delivered
  });

  it('accepts a sharper fix at once', () => {
    expect(supersedes(fix(now + 1_000, 15), fix(now, 900))).toBe(true);
  });

  it('rejects a much vaguer fix while the sharp one is still fresh', () => {
    // Chrome will follow a 20 m Wi-Fi fix with a kilometre-wide IP guess. Taking
    // it would throw the marker across town and back for no new information.
    expect(supersedes(fix(now + 5_000, 3_000), fix(now, 20))).toBe(false);
  });

  it('accepts a vaguer fix once the sharp one is stale enough to be the bigger lie', () => {
    expect(supersedes(fix(now + 120_000, 3_000), fix(now, 20))).toBe(true);
  });

  it('treats a missing accuracy as maximally vague rather than trustworthy', () => {
    const noAcc: GeoFix = { coords: {} as GeolocationCoordinates, at: now + 5_000 };
    expect(supersedes(noAcc, fix(now, 20))).toBe(false);
    // ...but anything measured beats nothing measured.
    expect(supersedes(fix(now + 5_000, 900), { coords: {} as GeolocationCoordinates, at: now })).toBe(true);
  });
});

describe('shouldPost — the two gates together', () => {
  const now = 1_700_000_000_000;

  it('posts news that is not too soon', () => {
    expect(shouldPost(fix(now + 30_000, 20), fix(now, 900), 30_000)).toBe(true);
  });

  it('holds a good fix back when we posted moments ago', () => {
    expect(shouldPost(fix(now + 1_000, 20), fix(now, 900), 3_000)).toBe(false);
  });

  it('rejects non-news even when the rate limit is wide open', () => {
    expect(shouldPost(fix(now - 1, 5), fix(now, 20), 600_000)).toBe(false);
  });

  /// The regression this function was extracted for. A fix that loses on the rate
  /// limit must not be recorded as reported, or the identical fix arriving later
  /// reads as old news and never goes out — the marker then sits at a position we
  /// never sent. The invariant is structural: `reported` is assigned only where a
  /// post actually happens, so a false here can never advance it.
  it('a throttled fix stays postable once the rate limit clears', () => {
    const reported = fix(now, 900);
    const arrived = fix(now + 1_000, 20);
    expect(shouldPost(arrived, reported, 3_000)).toBe(false);
    // Same fix, same `reported` (untouched, because we did not post) — later.
    expect(shouldPost(arrived, reported, 25_000)).toBe(true);
  });
});
