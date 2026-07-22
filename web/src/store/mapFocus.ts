import { create } from 'zustand';

/// One-shot map commands driven from the UI (member rows, map buttons). `seq`
/// and `north` are monotonic counters that bump on each request, so repeating the
/// SAME command still re-fires (the map compares against the previous counter —
/// an unchanged value would otherwise be a no-op).
///   - focus:      fly + zoom to a coordinate (tap a member; "recenter on me")
///   - resetNorth: rotate the map so north is at the top of the screen
interface MapFocusState {
  target: { lng: number; lat: number } | null;
  seq: number;
  north: number;
  focus: (lng: number, lat: number) => void;
  resetNorth: () => void;
}

export const useMapFocus = create<MapFocusState>((set) => ({
  target: null,
  seq: 0,
  north: 0,
  focus: (lng, lat) => set((s) => ({ target: { lng, lat }, seq: s.seq + 1 })),
  resetNorth: () => set((s) => ({ north: s.north + 1 })),
}));
