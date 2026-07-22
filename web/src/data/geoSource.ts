/// ONE geolocation watch for the whole tab, shared by every consumer.
///
/// Two features want this browser's position at once — the circle reporter
/// (webReporter.ts) and the live-share reporter (shareReporter.ts). A second
/// `watchPosition` would mean a second GPS/Wi-Fi scan for the very same fix:
/// more battery, no more information. So consumers subscribe here instead. The
/// watch starts with the first subscriber and stops with the last, and runs at
/// high accuracy while ANY subscriber asks for it.
///
/// A denied permission is not an error here: the watch simply never fires, and
/// subscribers just never hear anything.

export interface GeoFix {
  coords: GeolocationCoordinates;
  /// When the PLATFORM determined this fix (epoch ms) — not when we received it.
  /// `maximumAge` lets the browser answer from cache, so a fix can arrive minutes
  /// after it was taken; a consumer that stamps `Date.now()` on it would report a
  /// stale position as current. Comes straight from `GeolocationPosition.timestamp`.
  at: number;
}

export interface GeoSubscription {
  onFix: (fix: GeoFix) => void;
  /// Ask the platform for its high-accuracy sensor (GPS).
  highAccuracy: boolean;
}

/// Only replay a cached fix to a newcomer if it is still recent; a stale point
/// posted as "live" is worse than a short wait for the real one.
const REPLAY_MAX_AGE_MS = 60_000;

const subs = new Set<GeoSubscription>();
let watchId: number | null = null;
let watchHighAccuracy = false;
let lastFix: GeoFix | null = null;

function available(): boolean {
  return typeof navigator !== 'undefined' && 'geolocation' in navigator;
}

function wantsHighAccuracy(): boolean {
  for (const sub of subs) {
    if (sub.highAccuracy) return true;
  }
  return false;
}

function onPosition(p: GeolocationPosition): void {
  lastFix = { coords: p.coords, at: p.timestamp };
  // Copy: a subscriber may unsubscribe from inside its own callback.
  for (const sub of [...subs]) sub.onFix(lastFix);
}

function startWatch(): void {
  if (!available() || subs.size === 0 || watchId !== null) return;
  watchHighAccuracy = wantsHighAccuracy();
  watchId = navigator.geolocation.watchPosition(onPosition, () => {}, {
    enableHighAccuracy: watchHighAccuracy,
    maximumAge: 15_000,
    timeout: 25_000,
  });
  // Kick a first fix out immediately — watchPosition alone can idle until the
  // device actually moves. This MUST ask for the same accuracy as the watch: it
  // used to omit the option (defaulting to false), so the first fix — the one a
  // stationary device then shows forever, because nothing moves to trigger the
  // watch again — was always the coarse network estimate, even in precise mode.
  requestFix(30_000);
}

function stopWatch(): void {
  if (watchId !== null && available()) navigator.geolocation.clearWatch(watchId);
  watchId = null;
}

/// Asks for one fix now, at whatever accuracy the current subscribers want, and
/// delivers it to all of them. `maxAgeMs` bounds how old a cached answer may be
/// (0 forces a fresh scan).
///
/// This exists because `watchPosition` fires on MOVEMENT: a desktop sitting on a
/// table produces exactly one fix, ever. Without a re-ask, its marker is pinned
/// to the first estimate for the whole session and can never refine itself —
/// which is precisely how a PC ends up shown a couple of blocks from where it is.
export function requestFix(maxAgeMs = 30_000): void {
  if (!available() || subs.size === 0) return;
  navigator.geolocation.getCurrentPosition(onPosition, () => {}, {
    enableHighAccuracy: wantsHighAccuracy(),
    maximumAge: maxAgeMs,
    timeout: 25_000,
  });
}

/// Subscribes to this tab's shared position stream. Returns the unsubscribe.
export function subscribeGeolocation(sub: GeoSubscription): () => void {
  subs.add(sub);
  if (watchId === null) {
    startWatch();
  } else if (watchHighAccuracy !== wantsHighAccuracy()) {
    stopWatch(); // re-open at the accuracy the current subscribers want
    startWatch();
  }
  if (lastFix && Date.now() - lastFix.at < REPLAY_MAX_AGE_MS) sub.onFix(lastFix);
  return () => {
    subs.delete(sub);
    if (subs.size === 0) {
      stopWatch();
    } else if (watchHighAccuracy !== wantsHighAccuracy()) {
      stopWatch();
      startWatch();
    }
  };
}

/// Test seam: drops the module's shared state between cases.
export function __resetGeoSourceForTests(): void {
  subs.clear();
  watchId = null;
  watchHighAccuracy = false;
  lastFix = null;
}
