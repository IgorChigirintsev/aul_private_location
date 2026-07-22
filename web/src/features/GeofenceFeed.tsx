import { useEffect, useRef, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { Trans, useTranslation } from 'react-i18next';
import type { TFunction } from 'i18next';
import { LogIn, LogOut, MapPin, Navigation } from 'lucide-react';

import { usePositions } from '../store/positions';
import { usePlaces } from '../store/places';
import { useDevices } from '../store/devices';
import { memberDisplayName, useProfiles } from '../store/profiles';
import { api } from '../data/api';
import { sealNotify } from '../data/notifyCodec';
import {
  GeofenceTracker,
  nearestEta,
  type EtaEstimate,
  type GeofenceTransition,
} from '../data/geofence';
import { useRetentionFeatures } from '../data/retention';
import { isStale } from '../data/freshness';
import type { UserDTO } from '../data/types';

interface Presence {
  deviceId: string;
  placeId: string;
  placeName: string;
}

interface EtaRow extends EtaEstimate {
  deviceId: string;
}

// Positions older than the shared staleness threshold (data/freshness.ts) no
// longer tell us where the device is, so they must not count as being inside a
// place (otherwise an offline/paused device would appear stuck at home forever).
// The same threshold dims the map marker and flags the members-list row.

const shortId = (id: string) => id.slice(0, 6);

/// Live geofence panel, computed entirely client-side from decrypted member
/// positions vs decrypted places (D-0035 — the server never sees coordinates).
/// Shows who is currently inside a place and a short arrive/depart feed. When the
/// arrival feature is active it also estimates a rough ETA for members on the
/// move and fires a browser notification on each arrival (only while this tab is
/// open — the closed-tab case is background Web Push, below).
///
/// This component is also the SENDER of background notifications: when one of MY
/// devices crosses a geofence, this client — the only one that can — seals
/// "who/where/when" under K_c and hands the blob to the server to relay as a Web
/// Push payload to the circle's other members. Watchers never send: otherwise
/// every open dashboard would relay the same arrival.
export function GeofenceFeed({
  circleId,
  circleKey,
}: {
  circleId: string;
  circleKey: Uint8Array | null;
}) {
  const { t, i18n } = useTranslation();
  const qc = useQueryClient();
  const trackerRef = useRef(new GeofenceTracker(30));
  const [events, setEvents] = useState<GeofenceTransition[]>([]);
  const [presence, setPresence] = useState<Presence[]>([]);
  const [etas, setEtas] = useState<EtaRow[]>([]);

  // Formats an ETA in seconds as a compact "~N min" / "~N h M min" label.
  const fmtEta = (seconds: number): string => {
    const m = Math.round(seconds / 60);
    if (m < 1) return t('geofence.eta.lessMin');
    if (m < 60) return t('geofence.eta.min', { count: m });
    const h = Math.floor(m / 60);
    const rem = m % 60;
    return rem ? t('geofence.eta.hourMin', { h, rem }) : t('geofence.eta.hour', { h });
  };

  const { arrivalActive, serverEnabled } = useRetentionFeatures();
  // Read the latest opt-in state inside the recompute closure without
  // re-subscribing the store on every toggle.
  const arrivalRef = useRef(arrivalActive);
  arrivalRef.current = arrivalActive;
  // Same for the translator: keep the latest `t` reachable from the effect's
  // long-lived recompute closure without re-running the effect.
  const tRef = useRef(t);
  tRef.current = t;
  // Ditto for everything the background relay needs. The operator kill-switch
  // gates it (same feature as the arrival alerts), but a member's own alert
  // opt-in must NOT: that pref says whether *they* want to be notified, and
  // using it here would silently deprive everyone else of their alerts.
  const relayRef = useRef<RelayContext>({ circleId, circleKey, enabled: serverEnabled });
  relayRef.current = {
    circleId,
    circleKey,
    enabled: serverEnabled,
    myUserId: qc.getQueryData<UserDTO>(['me'])?.id,
  };

  useEffect(() => {
    // "Whoever is already at a place" is seeded inside the tracker now, per
    // (device, place) pair — see GeofenceTracker. This used to be a `seeded`
    // boolean here, and it was wrong twice over: `setEvents` sat OUTSIDE it, so
    // every reload still drew phantom "arrived at Home" rows; and one flag for the
    // whole feed could not cover a device that first appears LATER — a laptop
    // whose position had gone stale relayed a real "arrived home" to the whole
    // circle the moment it reported again, about a place it had never left.
    //
    // A fresh tracker per circle: inside-state from the circle we just left must
    // not surface as transitions here.
    trackerRef.current = new GeofenceTracker(30);
    setEvents([]);

    const recompute = () => {
      const now = Date.now();
      // Only reason about devices with a recent fix; stale ones age out of
      // presence (and out of the tracker's inside-set, without a phantom exit).
      const positions = Object.values(usePositions.getState().positions).filter(
        (p) => !isStale(p.capturedAt, now),
      );
      const places = Object.values(usePlaces.getState().places);
      const transitions = trackerRef.current.update(positions, places, now);
      // Every transition the tracker returns is now genuinely news, so the feed,
      // the local alert and the relay all act on the same set — no gate to get
      // wrong, and no way for the rendered rows to disagree with what was sent.
      if (transitions.length > 0) {
        const newest = [...transitions].reverse(); // most-recent first; pure (no mutation of `transitions`)
        setEvents((prev) => [...newest, ...prev].slice(0, 8));
        if (arrivalRef.current) notifyArrivals(transitions, tRef.current);
        void relayOwnTransitions(transitions, relayRef.current);
      }

      const nowInside: Presence[] = [];
      const insideIds = new Set<string>();
      for (const pos of positions) {
        for (const id of trackerRef.current.insidePlaceIds(pos.deviceId)) {
          const place = places.find((p) => p.id === id);
          if (place) {
            nowInside.push({ deviceId: pos.deviceId, placeId: place.id, placeName: place.name });
            insideIds.add(pos.deviceId);
          }
        }
      }
      setPresence(nowInside);

      // ETA: a rough estimate for members who are moving and not already inside
      // a place. Only shown when the arrival feature is active.
      if (arrivalRef.current) {
        const rows: EtaRow[] = [];
        for (const pos of positions) {
          if (insideIds.has(pos.deviceId)) continue;
          const eta = nearestEta(pos, places);
          if (eta) rows.push({ deviceId: pos.deviceId, ...eta });
        }
        rows.sort((a, b) => a.seconds - b.seconds);
        setEtas(rows.slice(0, 5));
      } else {
        setEtas([]);
      }
    };

    recompute();
    const unsubP = usePositions.subscribe(recompute);
    const unsubPl = usePlaces.subscribe(recompute);
    // Re-evaluate periodically so freshness ages out even with no store change.
    const timer = setInterval(recompute, 30_000);
    return () => {
      unsubP();
      unsubPl();
      clearInterval(timer);
    };
  }, [circleId]);

  if (presence.length === 0 && events.length === 0 && etas.length === 0) return null;

  return (
    <div className="border-t border-black/5 px-4 py-3">
      <h3 className="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-ink-soft">
        <MapPin size={13} /> {t('geofence.atPlaces')}
      </h3>
      {presence.length > 0 ? (
        <ul className="mt-1.5 space-y-1">
          {presence.map((p) => (
            <li key={`${p.deviceId}:${p.placeId}`} className="text-sm">
              <Trans
                i18nKey="geofence.presenceRow"
                values={{ id: shortId(p.deviceId), place: p.placeName }}
                components={{
                  id: <span className="font-mono text-xs text-ink-soft" />,
                  place: <strong className="text-primary" />,
                }}
              />
            </li>
          ))}
        </ul>
      ) : (
        <p className="mt-1 text-sm text-ink-soft">{t('geofence.nobody')}</p>
      )}

      {etas.length > 0 && (
        <ul className="mt-2 space-y-0.5">
          {etas.map((e) => (
            <li key={`eta-${e.deviceId}-${e.placeId}`} className="flex items-center gap-1.5 text-xs text-ink-soft">
              <Navigation size={12} className="text-accent" />
              <span className="font-mono">{shortId(e.deviceId)}</span>
              {' → '}
              <span className="font-medium">{e.placeName}</span>
              <span className="ml-auto">~{fmtEta(e.seconds)}</span>
            </li>
          ))}
        </ul>
      )}

      {events.length > 0 && (
        <ul className="mt-2 space-y-0.5">
          {events.map((e, i) => (
            <li key={`${e.at}-${e.placeId}-${i}`} className="flex items-center gap-1.5 text-xs text-ink-soft">
              {e.kind === 'enter' ? <LogIn size={12} className="text-primary" /> : <LogOut size={12} />}
              <Trans
                i18nKey={e.kind === 'enter' ? 'geofence.eventEnter' : 'geofence.eventExit'}
                values={{ id: shortId(e.deviceId), place: e.placeName }}
                components={{ id: <span className="font-mono" />, place: <span className="font-medium" /> }}
              />
              <span className="ml-auto">{new Date(e.at).toLocaleTimeString(i18n.language)}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

interface RelayContext {
  circleId: string;
  circleKey: Uint8Array | null;
  /// The operator's kill-switch for the arrival feature.
  enabled: boolean;
  myUserId?: string;
}

/// Announces MY OWN geofence transitions to the circle's other members as
/// background Web Push, so their alert arrives even with their tab closed.
///
/// Only the mover announces (a watcher's client ignores everyone else's
/// transitions): otherwise every open dashboard would relay the same arrival.
/// The payload is sealed under K_c before it is handed over — the server relays
/// bytes it cannot read (it learns only that this circle had *an* event). Two of
/// my own browsers open at once do relay twice; the receiving service worker
/// collapses those by notification tag.
///
/// Best-effort by design: offline, a 503 (push not configured) or any other
/// failure is swallowed. A missed notification is not worth an error in the UI.
async function relayOwnTransitions(
  transitions: GeofenceTransition[],
  ctx: RelayContext,
): Promise<void> {
  const { circleId, circleKey, enabled, myUserId } = ctx;
  if (!enabled || !circleKey || !myUserId) return;
  const devices = useDevices.getState().devices;
  const who = memberDisplayName(useProfiles.getState().profiles, myUserId);
  for (const tr of transitions) {
    if (devices[tr.deviceId]?.userId !== myUserId) continue; // someone else's device
    try {
      const payload = sealNotify(
        {
          t: tr.kind === 'enter' ? 'arrival' : 'departure',
          place: tr.placeName,
          who,
          ts: tr.at,
        },
        circleKey,
      );
      await api.notifyCircle(circleId, payload);
    } catch {
      /* offline / push disabled server-side / rate-limited — nothing to retry */
    }
  }
}

/// Fires a browser notification for each arrival. Best-effort: silently no-ops
/// when the API is unavailable or permission has not been granted.
function notifyArrivals(transitions: GeofenceTransition[], t: TFunction): void {
  if (typeof Notification === 'undefined' || Notification.permission !== 'granted') return;
  for (const tr of transitions) {
    if (tr.kind !== 'enter') continue;
    try {
      // Title stays the brand name "Aul" (untranslated); body is localized.
      new Notification('Aul', {
        body: t('geofence.notify.arrived', { name: shortId(tr.deviceId), place: tr.placeName }),
      });
    } catch {
      /* some browsers require a ServiceWorkerRegistration to notify — ignore */
    }
  }
}
