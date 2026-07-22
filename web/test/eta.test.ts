import { describe, expect, it } from 'vitest';

import {
  arrivalNotices,
  distanceMeters,
  estimateEta,
  nearestEta,
  type GeofenceTransition,
} from '../src/data/geofence';
import type { Place } from '../src/data/types';

const gym: Place = { id: 'gym', version: 1, name: 'Gym', lat: 43.21, lng: 76.8, radius: 100 };
const home: Place = { id: 'home', version: 1, name: 'Home', lat: 43.2, lng: 76.8, radius: 100 };

describe('estimateEta', () => {
  it('estimates time to the geofence edge from distance and speed', () => {
    // ~1.11 km north of Gym's centre; edge is radius (100 m) closer.
    const pos = { lat: 43.2, lng: 76.8, speed: 10 };
    const eta = estimateEta(pos, gym);
    expect(eta).not.toBeNull();
    const expectedEdge = distanceMeters(43.2, 76.8, 43.21, 76.8) - gym.radius;
    expect(eta!.distanceMeters).toBeCloseTo(expectedEdge, 3);
    expect(eta!.seconds).toBeCloseTo(expectedEdge / 10, 3);
    expect(eta!.placeId).toBe('gym');
    expect(eta!.placeName).toBe('Gym');
  });

  it('returns null when the speed is unknown or below the stationary threshold', () => {
    expect(estimateEta({ lat: 43.2, lng: 76.8 }, gym)).toBeNull();
    expect(estimateEta({ lat: 43.2, lng: 76.8, speed: 0.1 }, gym)).toBeNull();
  });

  it('returns null when already inside the geofence', () => {
    // Standing at the centre, moving fast, but distance-to-edge is negative.
    expect(estimateEta({ lat: 43.21, lng: 76.8, speed: 5 }, gym)).toBeNull();
  });

  it('returns null when the ETA exceeds the cap', () => {
    // Crawling toward a far place → ETA beyond maxSeconds.
    expect(estimateEta({ lat: 43.2, lng: 76.8, speed: 0.6 }, gym, { maxSeconds: 10 })).toBeNull();
  });
});

describe('nearestEta', () => {
  it('picks the place with the smallest ETA', () => {
    // ~220 m south of Home (outside its geofence) and moving: Home's edge is
    // much nearer than Gym's, so Home wins even though Gym is listed first.
    const pos = { lat: 43.198, lng: 76.8, speed: 5 };
    const eta = nearestEta(pos, [gym, home]);
    expect(eta?.placeId).toBe('home');
  });

  it('returns null when no place yields a usable ETA', () => {
    expect(nearestEta({ lat: 43.2, lng: 76.8 }, [gym, home])).toBeNull();
  });
});

describe('arrivalNotices', () => {
  const enter: GeofenceTransition = {
    deviceId: 'device-abcdef123',
    placeId: 'home',
    placeName: 'Home',
    kind: 'enter',
    at: 1,
  };
  const exit: GeofenceTransition = { ...enter, kind: 'exit' };

  it('produces one notice per arrival and ignores departures', () => {
    const notices = arrivalNotices([enter, exit]);
    expect(notices).toHaveLength(1);
    expect(notices[0]).toMatchObject({
      deviceId: 'device-abcdef123',
      placeId: 'home',
      title: 'Aul',
      body: 'device arrived at Home', // default label = first 6 chars
    });
  });

  it('honours a custom device label', () => {
    const notices = arrivalNotices([enter], () => 'Mom');
    expect(notices[0].body).toBe('Mom arrived at Home');
  });
});
