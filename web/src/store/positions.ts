import { create } from 'zustand';

import type { MemberPosition } from '../data/types';

interface PositionsState {
  /// Latest decrypted position per device.
  positions: Record<string, MemberPosition>;
  upsert: (p: MemberPosition) => void;
  bulk: (ps: MemberPosition[]) => void;
  reset: () => void;
}

/// Holds every circle member's most recent decrypted position. Only newer
/// captures overwrite older ones (out-of-order WS/poll delivery is safe).
export const usePositions = create<PositionsState>((set) => ({
  positions: {},
  upsert: (p) =>
    set((state) => {
      const existing = state.positions[p.deviceId];
      if (existing && existing.capturedAt >= p.capturedAt) return state;
      return { positions: { ...state.positions, [p.deviceId]: p } };
    }),
  bulk: (ps) =>
    set((state) => {
      const next = { ...state.positions };
      for (const p of ps) {
        const existing = next[p.deviceId];
        if (!existing || existing.capturedAt < p.capturedAt) next[p.deviceId] = p;
      }
      return { positions: next };
    }),
  reset: () => set({ positions: {} }),
}));
