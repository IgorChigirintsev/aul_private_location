import { useEffect } from 'react';

import { api } from './api';
import { requestFix, subscribeGeolocation, type GeoFix } from './geoSource';
import { pad, sealPing, toBase64 } from '../crypto/aulCrypto';
import type { FixPayload, PrecisionMode } from './types';

const PAD_BLOCK = 256; // matches the reporter's PingCodec padBlock (Dart: 256)
const MIN_INTERVAL_MS = 20_000; // post at most ~every 20 s on movement
const HEARTBEAT_MS = 30_000; // re-ask the platform every 30 s — the circle cadence
const CITY_GRID = 0.01; // ~1.1 km, matches the app's city coarsening

/// How much vaguer a fix may be than the one we already hold before we treat it
/// as noise rather than news, and how stale the sharp one must get before we take
/// the vague one anyway.
const MUCH_VAGUER = 2;
const SHARP_FIX_STALE_MS = 90_000;

/// Is this fix worth replacing what we already reported?
///
/// Browsers interleave a coarse network estimate with sharper ones — Chrome will
/// happily follow a 20 m Wi-Fi fix with a 3 km IP-level guess — and a cached
/// answer can arrive long after it was taken. Posting every fix as it lands makes
/// the marker jump blocks away and back for no new information. So: never go
/// backwards in time, and accept a much vaguer fix only once the sharp one is old
/// enough that staleness is the bigger lie.
export function supersedes(next: GeoFix, current: GeoFix | null): boolean {
  if (!current) return true;
  if (next.at <= current.at) return false; // same or older fix: nothing new
  const nextAcc = next.coords.accuracy ?? Number.POSITIVE_INFINITY;
  const currentAcc = current.coords.accuracy ?? Number.POSITIVE_INFINITY;
  if (nextAcc <= currentAcc * MUCH_VAGUER) return true;
  return next.at - current.at > SHARP_FIX_STALE_MS;
}

/// Both gates a fix must pass to be posted: "is this news?" and "not so fast".
///
/// They are here, together and pure, because their INTERACTION is the subtle
/// part: whatever this returns false for must leave `reported` untouched. Marking
/// a fix reported that we then throttled away would make the next identical fix
/// look like old news, and the marker would sit on a position we never actually
/// sent — the very freeze this module exists to avoid.
export function shouldPost(
  next: GeoFix,
  reported: GeoFix | null,
  sinceLastPostMs: number,
): boolean {
  return supersedes(next, reported) && sinceLastPostMs >= MIN_INTERVAL_MS;
}

async function batteryPct(): Promise<number | undefined> {
  try {
    const nav = navigator as Navigator & { getBattery?: () => Promise<{ level: number }> };
    if (!nav.getBattery) return undefined;
    const b = await nav.getBattery();
    return Math.round(b.level * 100);
  } catch {
    return undefined;
  }
}

const coarsen = (v: number): number => Math.round(v / CITY_GRID) * CITY_GRID;

function clientId(): string {
  try {
    return crypto.randomUUID();
  } catch {
    return `web-${Date.now()}-${Math.floor(Math.random() * 1e9)}`;
  }
}

/// Makes THIS browser a reporter: seals its geolocation under the circle key and
/// posts it as a ping, so the PC appears on the map as its own (web) device.
/// Fully E2EE — the plaintext coordinates never leave the browser. Honours the
/// circle precision mode (paused = no reporting; city = ~1 km grid + no
/// speed/heading, like the phone reporter). A denied geolocation permission just
/// means no PC marker; nothing is thrown.
///
/// The position comes from the tab's SHARED watch (geoSource), not a watch of its
/// own — the live-share reporter reads the same stream.
export function useWebReporter(
  circleId: string | null,
  circleKey: Uint8Array | null,
  mode: PrecisionMode,
): void {
  useEffect(() => {
    if (!circleId || !circleKey || mode === 'paused') return;

    let cancelled = false;
    let lastPost = 0;
    let reported: GeoFix | null = null;

    const send = async (geo: GeoFix) => {
      lastPost = Date.now();
      reported = geo;
      const coords = geo.coords;
      const city = mode === 'city';
      const fix: FixPayload = {
        lat: city ? coarsen(coords.latitude) : coords.latitude,
        lng: city ? coarsen(coords.longitude) : coords.longitude,
        acc: city ? Math.max(coords.accuracy ?? 0, 1000) : (coords.accuracy ?? undefined),
        spd: city ? undefined : (coords.speed ?? undefined),
        hdg: city ? undefined : (coords.heading ?? undefined),
        batt: await batteryPct(),
        // The moment the PLATFORM took this fix, not the moment we posted it.
        // These used to be Date.now(), which re-stamped a cached or minutes-old
        // fix as current — the map then said "just now" over a position the
        // browser had not re-measured since the tab opened.
        ts: geo.at,
        mode,
      };
      const plain = new TextEncoder().encode(JSON.stringify(fix)); // undefined fields drop out
      const { nonce, ciphertext } = sealPing(pad(plain, PAD_BLOCK), circleKey);
      try {
        await api.postPings([
          {
            circle_id: circleId,
            client_id: clientId(),
            nonce: toBase64(nonce),
            ciphertext: toBase64(ciphertext),
            captured_at: new Date(geo.at).toISOString(),
          },
        ]);
      } catch {
        /* transient — the next fix or heartbeat retries */
      }
    };

    const unsubscribe = subscribeGeolocation({
      highAccuracy: mode === 'precise',
      onFix: (geo) => {
        if (cancelled || !shouldPost(geo, reported, Date.now() - lastPost)) return;
        void send(geo); // the ONLY place `reported` is assigned — see shouldPost
      },
    });

    // Ask where we are again — do NOT re-post the last fix stamped "now". The
    // watch only fires on movement, so a device sitting still would otherwise
    // report its very first estimate forever, growing more confident-looking and
    // no less wrong. A re-ask lets the platform refine it; if it has nothing new,
    // `supersedes` drops the answer and the marker honestly keeps its old age.
    const heartbeat = window.setInterval(() => requestFix(30_000), HEARTBEAT_MS);

    return () => {
      cancelled = true;
      unsubscribe();
      window.clearInterval(heartbeat);
    };
  }, [circleId, circleKey, mode]);
}
