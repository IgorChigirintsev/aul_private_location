import { beforeAll, describe, expect, it } from 'vitest';

import { initCrypto, randomCircleKey } from '../src/crypto/aulCrypto';
import { GeofenceTracker, distanceMeters } from '../src/data/geofence';
import { openPlace, sealPlace, openSos, sealSos } from '../src/data/placeCodec';
import type { MemberPosition, Place, PlaceDTO, SosDTO } from '../src/data/types';

beforeAll(async () => {
  await initCrypto();
});

describe('placeCodec', () => {
  it('round-trips a place through seal/open under the same key', () => {
    const key = randomCircleKey();
    const ct = sealPlace({ name: "Mom's house", lat: 43.238949, lng: 76.889709, radius: 150 }, key);
    const dto: PlaceDTO = { id: 'p1', ciphertext: ct, version: 1, updated_at: '' };
    const place = openPlace(dto, [key]);
    expect(place).not.toBeNull();
    expect(place).toMatchObject({ id: 'p1', version: 1, name: "Mom's house", radius: 150 });
    expect(place!.lat).toBeCloseTo(43.238949, 6);
    expect(place!.lng).toBeCloseTo(76.889709, 6);
  });

  it('hides name length: different names produce equal-length ciphertext (padded)', () => {
    const key = randomCircleKey();
    const a = sealPlace({ name: 'Gym', lat: 1, lng: 2, radius: 100 }, key);
    const b = sealPlace({ name: 'A very long place name indeed', lat: 1, lng: 2, radius: 100 }, key);
    expect(a.length).toBe(b.length);
  });

  it('returns null when no key in the ring opens the place', () => {
    const ct = sealPlace({ name: 'Home', lat: 0, lng: 0, radius: 50 }, randomCircleKey());
    const dto: PlaceDTO = { id: 'p2', ciphertext: ct, version: 1, updated_at: '' };
    expect(openPlace(dto, [randomCircleKey()])).toBeNull();
  });

  it('opens a place across a rotation keyring (tries every key)', () => {
    const oldKey = randomCircleKey();
    const newKey = randomCircleKey();
    const ct = sealPlace({ name: 'School', lat: 5, lng: 6, radius: 200 }, oldKey);
    const dto: PlaceDTO = { id: 'p3', ciphertext: ct, version: 2, updated_at: '' };
    // Keyring holds new key first, old key later — still opens.
    expect(openPlace(dto, [newKey, oldKey])?.name).toBe('School');
  });

  it('SOS: round-trips, and surfaces metadata even when undecryptable', () => {
    const key = randomCircleKey();
    const ct = sealSos({ lat: 40.7, lng: -74, msg: 'help', ts: 1234 }, key);
    const dto: SosDTO = { id: 's1', circle_id: 'c', device_id: 'd', ciphertext: ct, created_at: 'now' };
    const ok = openSos(dto, [key]);
    expect(ok).toMatchObject({ id: 's1', message: 'help', ts: 1234, decrypted: true });

    const blind = openSos(dto, [randomCircleKey()]);
    expect(blind).toMatchObject({ id: 's1', deviceId: 'd', decrypted: false });
    expect(blind.message).toBeUndefined();
  });
});

describe('geofence', () => {
  it('distanceMeters is ~0 for identical points and grows with separation', () => {
    expect(distanceMeters(43.2, 76.8, 43.2, 76.8)).toBeLessThan(1);
    // ~0.01 deg latitude ≈ 1.11 km.
    expect(distanceMeters(43.2, 76.8, 43.21, 76.8)).toBeGreaterThan(1000);
    expect(distanceMeters(43.2, 76.8, 43.21, 76.8)).toBeLessThan(1200);
  });

  const place: Place = { id: 'home', version: 1, name: 'Home', lat: 43.2, lng: 76.8, radius: 100 };
  const posAt = (lat: number, lng: number): MemberPosition => ({
    deviceId: 'dev1',
    lat,
    lng,
    mode: 'precise',
    capturedAt: 1,
    updatedAt: 1,
  });

  it('emits enter then exit with hysteresis (no flapping at the edge)', () => {
    const t = new GeofenceTracker(30);
    // Far away → no event.
    expect(t.update([posAt(43.25, 76.85)], [place], 1)).toEqual([]);
    // Move inside the radius → enter.
    const enter = t.update([posAt(43.2, 76.8)], [place], 2);
    expect(enter).toHaveLength(1);
    expect(enter[0]).toMatchObject({ kind: 'enter', placeId: 'home', deviceId: 'dev1' });
    expect(t.insidePlaceIds('dev1')).toEqual(['home']);

    // Nudge just past the radius but within the hysteresis band → NO exit.
    // ~110m north of centre (radius 100, margin 30 → exit only beyond 130m).
    const jitter = t.update([posAt(43.201, 76.8)], [place], 3);
    expect(jitter).toEqual([]);
    expect(t.insidePlaceIds('dev1')).toEqual(['home']);

    // Move clearly out (beyond radius+margin) → exit.
    const exit = t.update([posAt(43.25, 76.85)], [place], 4);
    expect(exit).toHaveLength(1);
    expect(exit[0]).toMatchObject({ kind: 'exit', placeId: 'home' });
    expect(t.insidePlaceIds('dev1')).toEqual([]);
  });

  it('prunes inside-state for a deleted place without emitting a spurious exit', () => {
    const t = new GeofenceTracker(30);
    t.update([posAt(43.2, 76.8)], [place], 1); // enter
    expect(t.insidePlaceIds('dev1')).toEqual(['home']);
    // Place removed from the set → state pruned, no exit event.
    expect(t.update([posAt(43.2, 76.8)], [], 2)).toEqual([]);
    expect(t.insidePlaceIds('dev1')).toEqual([]);
  });

  /// The first look at a pair is state, not news. Each of these was a real
  /// false "X arrived at Home" — and the last one did not just draw a row, it
  /// relayed a push to everyone in the circle.
  describe('a first sighting is never an arrival', () => {
    it('finding a device already inside announces nothing', () => {
      const t = new GeofenceTracker(30);
      expect(t.update([posAt(43.2, 76.8)], [place], 1)).toEqual([]);
      // ...but the state IS recorded, so the eventual departure is real.
      expect(t.insidePlaceIds('dev1')).toEqual(['home']);
      const exit = t.update([posAt(43.25, 76.85)], [place], 2);
      expect(exit).toHaveLength(1);
      expect(exit[0]).toMatchObject({ kind: 'exit' });
    });

    it('a device that appears LATER is seeded silently, not announced', () => {
      const t = new GeofenceTracker(30);
      const other = (id: string, lat: number, lng: number): MemberPosition => ({
        ...posAt(lat, lng),
        deviceId: id,
      });
      // Someone else's phone is seen first and moves in — a real arrival.
      t.update([other('phone', 43.25, 76.85)], [place], 1);
      expect(t.update([other('phone', 43.2, 76.8)], [place], 2)).toHaveLength(1);

      // NOW the laptop reports for the first time, sitting at home all along.
      // The old code had one global "seeded" flag, already closed by the phone,
      // so this relayed "you arrived at Home" to the entire circle.
      const events = t.update(
        [other('phone', 43.2, 76.8), other('laptop', 43.2, 76.8)],
        [place],
        3,
      );
      expect(events).toEqual([]);
      expect(t.insidePlaceIds('laptop')).toEqual(['home']);
    });

    it('a place created around a device that is already there announces nothing', () => {
      const t = new GeofenceTracker(30);
      t.update([posAt(43.2, 76.8)], [], 1); // no fences yet
      expect(t.update([posAt(43.2, 76.8)], [place], 2)).toEqual([]);
      expect(t.insidePlaceIds('dev1')).toEqual(['home']);
    });

    it('a device going quiet and coming back to the same place announces nothing', () => {
      const t = new GeofenceTracker(30);
      t.update([posAt(43.25, 76.85)], [place], 1); // seed: outside
      expect(t.update([posAt(43.2, 76.8)], [place], 2)).toHaveLength(1); // real arrival
      // Position goes stale — the caller filters it out entirely for a while.
      expect(t.update([], [place], 3)).toEqual([]);
      // It comes back, still at home. Nothing happened while it was quiet.
      expect(t.update([posAt(43.2, 76.8)], [place], 4)).toEqual([]);
    });

    /// A device that goes quiet must NOT be forgotten — which the test above
    /// cannot show, because a forgetful tracker also stays silent there (it just
    /// re-seeds). This is the case that separates them: quiet at home, back
    /// somewhere else. Remembering yields the exit that genuinely happened;
    /// forgetting swallows it and the circle never learns they left.
    it('a device that goes quiet and returns ELSEWHERE still reports the departure', () => {
      const t = new GeofenceTracker(30);
      t.update([posAt(43.25, 76.85)], [place], 1);
      expect(t.update([posAt(43.2, 76.8)], [place], 2)).toHaveLength(1); // arrived home
      expect(t.update([], [place], 3)).toEqual([]); // stale: filtered out by the caller
      const back = t.update([posAt(43.25, 76.85)], [place], 4); // reappears across town
      expect(back).toHaveLength(1);
      expect(back[0]).toMatchObject({ kind: 'exit', placeId: 'home' });
    });
  });
});
