import { useEffect, useReducer } from 'react';
import { useTranslation } from 'react-i18next';

import { useConnection } from '../store/connection';

/// The honest, CLIENT-INFERRED offline signal. An offline or unreachable server
/// — very much including a self-hosted box that was switched off or went to sleep
/// — cannot announce its own offline-ness, so this is concluded from the one thing
/// the client can see for itself: whether ITS OWN realtime socket is up
/// (`useConnection.online`, driven by `RealtimeClient.onStatus`).
///
/// Beyond the generic "reconnecting…" line it adds the load-bearing part for a
/// SAFETY app: HOW STALE the map may be, as an explicit "last connected N ago"
/// age. Without it a viewer can sit trusting a last-known dot that reads a fresh
/// "3 min ago" while nothing has actually arrived for an hour — the single worst
/// failure mode for a location-safety product (SELF_HOST_DESIGN.md, critique #3).
export function OfflineBanner() {
  const { t } = useTranslation();
  const online = useConnection((s) => s.online);
  const lastOnlineAt = useConnection((s) => s.lastOnlineAt);

  // Advance the "N ago" age while we stay disconnected, even though no store
  // change arrives to re-render off (the socket is down — that's the point). Same
  // 30s cadence the members list uses.
  const [, tick] = useReducer((n: number) => n + 1, 0);
  useEffect(() => {
    if (online) return;
    const timer = setInterval(tick, 30_000);
    return () => clearInterval(timer);
  }, [online]);

  if (online) return null;

  const agoLabel = (ms: number): string => {
    const s = Math.round((Date.now() - ms) / 1000);
    if (s < 60) return t('members.ago.justNow');
    const m = Math.round(s / 60);
    if (m < 60) return t('members.ago.min', { count: m });
    return t('members.ago.hour', { count: Math.round(m / 60) });
  };

  return (
    <div
      role="status"
      aria-live="polite"
      className="pointer-events-auto inline-flex w-fit flex-col gap-0.5 rounded-2xl bg-accent/10 px-3 py-2 text-xs font-medium text-accent shadow-sm backdrop-blur"
    >
      <span className="inline-flex items-center gap-2">
        <span className="relative flex h-2 w-2 shrink-0">
          <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-accent opacity-60" />
          <span className="relative inline-flex h-2 w-2 rounded-full bg-accent" />
        </span>
        {t('dashboard.connection.paused')}
      </span>
      {lastOnlineAt != null && (
        <span className="pl-4 font-normal opacity-90">
          {t('dashboard.connection.stale', { ago: agoLabel(lastOnlineAt) })}
        </span>
      )}
    </div>
  );
}
