import { create } from 'zustand';

import type { Place } from '../data/types';

interface PlacesState {
  /// Decrypted places for the selected circle, keyed by id.
  places: Record<string, Place>;
  setAll: (ps: Place[]) => void;
  reset: () => void;
}

/// Holds the decrypted places of the selected circle. Refilled from the server
/// list on load and on every `place_updated` realtime nudge (the payloadless
/// event just means "re-fetch"). Delete converges by absence from the new list.
export const usePlaces = create<PlacesState>((set) => ({
  places: {},
  setAll: (ps) =>
    set(() => {
      const next: Record<string, Place> = {};
      for (const p of ps) next[p.id] = p;
      return { places: next };
    }),
  reset: () => set({ places: {} }),
}));
