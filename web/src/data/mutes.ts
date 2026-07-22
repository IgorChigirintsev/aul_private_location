import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';

import { api } from './api';
import type { MutesDTO } from './types';

/// The "nothing muted" state, and the fallback whenever the mute set cannot be
/// read (older server without the endpoint, offline). Failing OPEN is the honest
/// default here: an unreadable mute set must never be rendered as "muted", which
/// would tell the user notifications are stopped when they are not.
export const NO_MUTES: MutesDTO = { circle_muted: false, muted_user_ids: [] };

/// The caller's own mutes in one circle. `retry: false` because a server without
/// the endpoint yet answers 404 — one attempt, then fall back to NO_MUTES.
export function useMutes(circleId: string | null | undefined) {
  return useQuery({
    queryKey: ['mutes', circleId],
    queryFn: () => api.circleMutes(circleId!),
    enabled: !!circleId,
    retry: false,
  });
}

/// Replaces the caller's whole mute set for a circle. The PUT is a REPLACE, so
/// every caller must pass the complete desired state — hence the helpers below
/// rather than open-coded spreads at each call site.
export function useSetMutes(circleId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (next: MutesDTO) => api.setCircleMutes(circleId, next),
    // Seed the cache from the server's echo, so the switch settles on what was
    // actually stored rather than on what we hoped it stored.
    onSuccess: (data) => qc.setQueryData(['mutes', circleId], data),
  });
}

/// The full mute set with the whole-circle flag flipped.
export function withCircleMuted(current: MutesDTO, muted: boolean): MutesDTO {
  return { circle_muted: muted, muted_user_ids: current.muted_user_ids };
}

/// The full mute set with one member added/removed. Idempotent, and it never
/// duplicates a user id.
export function withMemberMuted(current: MutesDTO, userId: string, muted: boolean): MutesDTO {
  const others = current.muted_user_ids.filter((id) => id !== userId);
  return {
    circle_muted: current.circle_muted,
    muted_user_ids: muted ? [...others, userId] : others,
  };
}
