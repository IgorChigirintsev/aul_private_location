import type { MemberPosition, Place } from './types';

/// Great-circle distance in metres (haversine). Must match the reporter's
/// geofence engine so enter/exit agree across clients.
export function distanceMeters(aLat: number, aLng: number, bLat: number, bLng: number): number {
  const R = 6_371_000;
  const toRad = (x: number) => (x * Math.PI) / 180;
  const dLat = toRad(bLat - aLat);
  const dLng = toRad(bLng - aLng);
  const lat1 = toRad(aLat);
  const lat2 = toRad(bLat);
  const h =
    Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

export interface GeofenceTransition {
  deviceId: string;
  placeId: string;
  placeName: string;
  kind: 'enter' | 'exit';
  at: number;
}

/// Computes geofence enter/exit from decrypted member positions vs decrypted
/// places, entirely client-side (the server never sees coordinates — D-0035).
///
/// Hysteresis: a device is "inside" when it comes within the radius, and stays
/// inside until it moves beyond radius + margin. This band stops a device
/// hovering near the edge from flapping enter/exit on GPS jitter.
/// **The first look at a (device, place) pair is STATE, not news.** Finding
/// someone already at home is not an arrival. The rule lives here, not in the
/// caller, because only this class knows which pairs it has already seen: a
/// caller-side "have we seeded yet?" flag cannot express it. Seeding is per PAIR,
/// so one flag for the whole feed announces a false arrival for every pair that
/// first appears after it closes -- a device back from a stale patch, or a place
/// created while you stand in it. That bug was real and it relayed: leave a laptop
/// at home overnight, reload, and the circle is told you arrived somewhere you
/// never left.
export class GeofenceTracker {
  private inside = new Set<string>();
  /// Pairs evaluated at least once. Membership means "we know where this device
  /// stands relative to this place", so a change is genuinely a change.
  private seen = new Set<string>();

  constructor(private readonly hysteresisM = 30) {}

  /// NUL joins the two ids: it cannot occur inside a UUID, so the key is
  /// unambiguous. Written as an escape on purpose -- it used to be a literal NUL
  /// byte typed into the source, which made the file `data` rather than text to
  /// every tool that looked at it, and left the separator invisible in a diff.
  private static key(deviceId: string, placeId: string): string {
    return `${deviceId}\0${placeId}`;
  }

  private static placeOf(key: string): string {
    return key.slice(key.indexOf('\0') + 1);
  }

  /// Feeds the latest positions + places and returns the transitions that just
  /// occurred. Keys for deleted places are pruned (no phantom "exit").
  update(positions: MemberPosition[], places: Place[], now: number): GeofenceTransition[] {
    const events: GeofenceTransition[] = [];

    for (const pos of positions) {
      for (const place of places) {
        const key = GeofenceTracker.key(pos.deviceId, place.id);
        const d = distanceMeters(pos.lat, pos.lng, place.lat, place.lng);
        const wasInside = this.inside.has(key);
        const isInside = wasInside ? d <= place.radius + this.hysteresisM : d <= place.radius;
        const firstLook = !this.seen.has(key);
        this.seen.add(key);
        if (isInside) this.inside.add(key);
        else this.inside.delete(key);
        if (firstLook) continue; // where they already were is not something that happened
        if (isInside && !wasInside) {
          events.push({ deviceId: pos.deviceId, placeId: place.id, placeName: place.name, kind: 'enter', at: now });
        } else if (!isInside && wasInside) {
          events.push({ deviceId: pos.deviceId, placeId: place.id, placeName: place.name, kind: 'exit', at: now });
        }
      }
    }

    // Prune by PLACE only: a deleted fence has no state worth keeping, and
    // dropping it emits no spurious exit.
    //
    // Deliberately NOT pruned when a device merely goes quiet. The caller filters
    // stale positions out, and forgetting a quiet device would make its return a
    // first look -- silent, so a real arrival is missed -- or, once it is seen
    // again, an "arrival" at a place it never left. Keeping the state means a
    // device that comes back where it was says nothing, and one that comes back
    // elsewhere exits, which is what actually happened.
    const livePlaces = new Set(places.map((p) => p.id));
    for (const key of [...this.inside]) {
      if (!livePlaces.has(GeofenceTracker.placeOf(key))) this.inside.delete(key);
    }
    for (const key of [...this.seen]) {
      if (!livePlaces.has(GeofenceTracker.placeOf(key))) this.seen.delete(key);
    }
    return events;
  }

  /// Ids of places a device is currently inside.
  insidePlaceIds(deviceId: string): string[] {
    const prefix = `${deviceId}\0`;
    const out: string[] = [];
    for (const key of this.inside) {
      if (key.startsWith(prefix)) out.push(key.slice(prefix.length));
    }
    return out;
  }
}

export interface EtaEstimate {
  placeId: string;
  placeName: string;
  /// Straight-line distance to the geofence edge, in metres.
  distanceMeters: number;
  /// Rough time-to-arrival in seconds (distance-to-edge / last-known speed).
  seconds: number;
}

/// Rough client-side ETA for a member heading toward a place: straight-line
/// distance to the geofence edge divided by the last-known ground speed. This is
/// a deliberately crude estimate (no routing, no heading) computed entirely from
/// already-decrypted data — the server never sees coordinates or speed.
///
/// Returns null when there is nothing sensible to show: the speed is unknown or
/// below `minSpeedMps` (treated as stationary), the member is already inside the
/// geofence, or the ETA exceeds `maxSeconds` (too far/slow to be useful).
export function estimateEta(
  pos: { lat: number; lng: number; speed?: number },
  place: Place,
  opts: { minSpeedMps?: number; maxSeconds?: number } = {},
): EtaEstimate | null {
  const minSpeed = opts.minSpeedMps ?? 0.5; // ~1.8 km/h — below this, "not moving"
  const maxSeconds = opts.maxSeconds ?? 3 * 60 * 60; // cap at 3 h
  const speed = pos.speed;
  if (speed == null || speed < minSpeed) return null;
  const toEdge = distanceMeters(pos.lat, pos.lng, place.lat, place.lng) - place.radius;
  if (toEdge <= 0) return null; // already within the geofence
  const seconds = toEdge / speed;
  if (seconds > maxSeconds) return null;
  return { placeId: place.id, placeName: place.name, distanceMeters: toEdge, seconds };
}

/// Picks the single nearest place a moving member has a usable ETA to, so the
/// feed can show one "on the way" line per member. Returns null when none apply.
export function nearestEta(
  pos: { lat: number; lng: number; speed?: number },
  places: Place[],
  opts?: { minSpeedMps?: number; maxSeconds?: number },
): EtaEstimate | null {
  let best: EtaEstimate | null = null;
  for (const place of places) {
    const eta = estimateEta(pos, place, opts);
    if (eta && (!best || eta.seconds < best.seconds)) best = eta;
  }
  return best;
}

export interface ArrivalNotice {
  deviceId: string;
  placeId: string;
  title: string;
  body: string;
}

/// Maps geofence transitions to the arrival notifications we should surface.
/// Only `enter` transitions produce a notice ("X arrived at <place>"); exits are
/// ignored. Kept pure so the notify decision is unit-testable without the
/// browser Notification API.
export function arrivalNotices(
  transitions: GeofenceTransition[],
  label: (deviceId: string) => string = (id) => id.slice(0, 6),
): ArrivalNotice[] {
  return transitions
    .filter((t) => t.kind === 'enter')
    .map((t) => ({
      deviceId: t.deviceId,
      placeId: t.placeId,
      title: 'Aul',
      body: `${label(t.deviceId)} arrived at ${t.placeName}`,
    }));
}
