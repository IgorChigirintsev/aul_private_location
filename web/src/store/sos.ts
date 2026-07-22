import { create } from 'zustand';

import type { SosEvent } from '../data/types';

interface SosState {
  /// Active (unresolved) SOS events for the selected circle, keyed by id.
  active: Record<string, SosEvent>;
  setAll: (events: SosEvent[]) => void;
  reconcile: (serverEvents: SosEvent[], now: number, graceMs?: number) => void;
  add: (event: SosEvent) => void;
  remove: (id: string) => void;
  reset: () => void;
}

/// Tracks live SOS alerts. Seeded from GET /sos and updated by the realtime
/// `sos` (add) / `sos_resolved` (remove) events, so the SOS banner reflects the
/// current emergency state without a refetch.
export const useSos = create<SosState>((set) => ({
  active: {},
  setAll: (events) =>
    set(() => {
      const next: Record<string, SosEvent> = {};
      for (const e of events) next[e.id] = e;
      return { active: next };
    }),
  /// Merge a server poll's active set with local state WITHOUT dropping a
  /// realtime-added alert the (possibly in-flight) poll missed. A locally-active
  /// alert absent from the server set is kept only if it was created within
  /// `graceMs` (a poll/realtime race); older ones absent from the server are
  /// treated as resolved and removed. Never hides a live emergency for a poll
  /// interval (the MEDIUM the review flagged).
  reconcile: (serverEvents, now, graceMs = 15_000) =>
    set((state) => {
      const next: Record<string, SosEvent> = {};
      for (const e of serverEvents) next[e.id] = e;
      for (const [id, e] of Object.entries(state.active)) {
        if (!(id in next) && now - Date.parse(e.createdAt) < graceMs) next[id] = e;
      }
      return { active: next };
    }),
  add: (event) => set((state) => ({ active: { ...state.active, [event.id]: event } })),
  remove: (id) =>
    set((state) => {
      if (!(id in state.active)) return state;
      const next = { ...state.active };
      delete next[id];
      return { active: next };
    }),
  reset: () => set({ active: {} }),
}));
