import { useEffect, useMemo, useRef } from 'react';

import { api } from './api';
import { requestFix, subscribeGeolocation, type GeoFix } from './geoSource';
import { sealShareFix } from './shareCodec';
import { isShareLive, useShareSessions } from './shares';
import { useShareKeys } from '../store/shareKeys';
import { fromBase64Url } from '../crypto/aulCrypto';
import type { ShareFix, ShareSessionDTO } from './types';

/// How often a live session's position is refreshed. A watcher opened this link
/// to meet someone, so the dot must feel live: 10 s, matching the viewer's poll
/// (ShareView POLL_MS) so the two compose to a ~10 s effective refresh rather
/// than stacking. Faster than the circle's 30 s — a share is a deliberate, brief,
/// high-attention act; the circle is the always-on background one.
const PING_MS = 10_000;

interface Target {
  id: string;
  key: Uint8Array;
  expiresAt: string;
}

/// Feeds every live-share session this browser can actually feed.
///
/// While ≥1 of the caller's sessions is live AND its K_share is on this device,
/// the current position is sealed under that session's OWN key and PUT to it on a
/// timer. The plaintext never leaves the browser and the circle key is not
/// involved at all: a share viewer decrypts with K_share and therefore sees this
/// one person, and only until the deadline.
///
/// Position comes from the tab's shared watch (geoSource) — the circle reporter
/// is reading the same stream, so sharing costs no extra sensor.
///
/// Returns the live sessions, so the dashboard can admit on screen that a share
/// is running.
export function useShareReporter(): ShareSessionDTO[] {
  const keys = useShareKeys((s) => s.keys);
  const keepOnly = useShareKeys((s) => s.keepOnly);

  // No key on this device means nothing here could feed a session even if one
  // existed — so don't poll the list at all for the many users who never share.
  const hasKeys = Object.keys(keys).length > 0;
  const sessions = useShareSessions(hasKeys);

  // The server drops expired sessions from the list, so a successful fetch is
  // also the signal to forget the keys of everything that has died.
  const data = sessions.data;
  useEffect(() => {
    if (!data) return;
    keepOnly(data.filter((s) => isShareLive(s)).map((s) => s.id));
  }, [data, keepOnly]);

  const live = useMemo(() => (data ?? []).filter((s) => isShareLive(s)), [data]);

  const targets = useMemo(
    () =>
      live.flatMap((s): Target[] => {
        const encoded = keys[s.id];
        if (!encoded) return []; // created in another browser — its key isn't here
        try {
          return [{ id: s.id, key: fromBase64Url(encoded), expiresAt: s.expires_at }];
        } catch {
          return []; // corrupt entry — the prune below will clear it out
        }
      }),
    [live, keys],
  );

  // Read through a ref so adding/dropping a session doesn't tear down the watch.
  const targetsRef = useRef<Target[]>(targets);
  targetsRef.current = targets;
  const active = targets.length > 0;

  useEffect(() => {
    if (!active) return;
    let cancelled = false;
    let geo: GeoFix | null = null;
    let posted = false;

    const send = async () => {
      if (cancelled || !geo) return;
      posted = true;
      const now = Date.now();
      const fix: ShareFix = {
        lat: geo.coords.latitude,
        lng: geo.coords.longitude,
        acc: geo.coords.accuracy ?? undefined,
        // The platform's fix time, not ours: this tick re-sends the last known
        // position whether or not it is new, and a viewer meeting up with someone
        // must be able to see that the dot is four minutes old rather than live.
        ts: geo.at,
      };
      for (const target of targetsRef.current) {
        // Re-check the deadline here, not just at render: the list refreshes
        // every 30 s, and not one position may go out after a session's end.
        if (Date.parse(target.expiresAt) <= now) continue;
        try {
          await api.putSharePing(target.id, sealShareFix(fix, target.key));
        } catch {
          /* transient — the next tick retries */
        }
      }
    };

    const unsubscribe = subscribeGeolocation({
      highAccuracy: true, // a live share is for meeting someone — a city grid is useless
      onFix: (next) => {
        geo = next;
        if (!posted) void send(); // first fix: don't make the viewer wait a full tick
      },
    });
    // Re-ask before re-sending: the watch only fires on movement, so someone
    // sharing from a desk would otherwise pin the viewer to their first estimate
    // for the whole session.
    const timer = window.setInterval(() => {
      requestFix(30_000);
      void send();
    }, PING_MS);

    return () => {
      cancelled = true;
      unsubscribe();
      window.clearInterval(timer);
    };
  }, [active]);

  return live;
}
