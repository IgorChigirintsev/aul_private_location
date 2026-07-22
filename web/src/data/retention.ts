import { useQuery } from '@tanstack/react-query';

import { api } from './api';
import { usePrefs } from '../store/prefs';

/// Whether the operator has left the retention features enabled. This is a
/// kill-switch: the features stay available unless the server explicitly says
/// false (an older server that omits the field is treated as enabled — the
/// per-user opt-in, OFF by default, still gates activation).
export function serverRetentionEnabled(
  info: { retention_features_enabled?: boolean } | undefined,
): boolean {
  return info?.retention_features_enabled !== false;
}

/// Cached read of GET /v1/server-info. Long stale time — this rarely changes and
/// several components gate on it, so we avoid refetch storms. Not `useMe`, so it
/// is safe to call under Home's loading gate.
export function useServerInfo() {
  return useQuery({
    queryKey: ['serverInfo'],
    queryFn: () => api.serverInfo(),
    staleTime: 5 * 60_000,
    retry: false,
  });
}

/// The effective state of each retention feature: active only when the operator
/// has it enabled AND the user has opted in. Both must be true.
export function useRetentionFeatures() {
  const info = useServerInfo();
  const arrivalEnabled = usePrefs((s) => s.arrivalEnabled);
  const serverEnabled = serverRetentionEnabled(info.data);
  return {
    serverEnabled,
    arrivalActive: serverEnabled && arrivalEnabled,
  };
}
