import { useQuery } from '@tanstack/react-query';

import { api } from './api';
import { msUntil } from './format';
import type { ShareSessionDTO } from './types';

/// One shared query key: the dialog, the "you are sharing" banner and the
/// reporter are all observers of the SAME list, so they can never disagree about
/// what is live.
export const SHARES_KEY = ['shares'] as const;

/// Offered durations. The server caps ttl_seconds at 3600 (60 min) — an hour of
/// live location to a stranger is already the outer edge of sensible, so there is
/// nothing longer to offer.
export const SHARE_TTL_CHOICES_S = [900, 1800, 3600] as const;
export const SHARE_TTL_DEFAULT_S = 900;

/// A session is live while it is neither revoked nor past its deadline. Both ends
/// matter: the server only drops a session from the list on its next fetch, so
/// the deadline has to be checked locally too.
export function isShareLive(session: ShareSessionDTO, now: number = Date.now()): boolean {
  return !session.revoked && msUntil(session.expires_at, now) > 0;
}

/// The caller's own unexpired sessions. `enabled` lets a passive observer (the
/// banner) read the cache without causing a fetch of its own — react-query runs
/// the query when ANY observer wants it.
export function useShareSessions(enabled: boolean) {
  return useQuery({
    queryKey: SHARES_KEY,
    queryFn: () => api.listShares(),
    enabled,
    refetchInterval: 30_000,
  });
}
