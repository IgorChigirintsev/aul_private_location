/// Shared staleness threshold for decrypted positions.
///
/// A location-SAFETY app must never present an old fix as if it were current: an
/// offline or paused device would otherwise sit on the map forever with a
/// fresh-looking "N min ago". Past this age we stop treating a position as
/// live — the map marker dims and the members list flags it — and the geofence
/// logic already drops it from "who is inside a place".
///
/// This is the single source of truth: GeofenceFeed's inside-a-place freshness,
/// the members list badge and the map marker all read the SAME number, so they
/// can never disagree about whether a member's position is still trustworthy.
export const STALE_MS = 15 * 60 * 1000;

/// True when a fix captured at [capturedAt] is older than the staleness
/// threshold as of [now]. Presentation-only: staleness is inferred purely from
/// the already-decrypted capture time vs the clock — nothing new is fetched or
/// decrypted. At exactly the threshold a fix is considered stale (boundary is
/// inclusive), matching GeofenceFeed's `age < STALE_MS` freshness test.
export function isStale(capturedAt: number, now: number = Date.now()): boolean {
  return now - capturedAt >= STALE_MS;
}
