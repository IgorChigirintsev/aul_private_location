import { create } from 'zustand';

/// A place being drawn on the map (add/edit flow). While `active`, a map click
/// sets the centre and the radius slider updates `radius`; MapView renders a live
/// draft circle. `editId` is set when editing an existing place.
interface MapDraftState {
  active: boolean;
  editId: string | null;
  center: { lat: number; lng: number } | null;
  radius: number; // metres
  begin: (opts?: { editId?: string; center?: { lat: number; lng: number }; radius?: number }) => void;
  setCenter: (c: { lat: number; lng: number }) => void;
  setRadius: (r: number) => void;
  cancel: () => void;
}

export const useMapDraft = create<MapDraftState>((set) => ({
  active: false,
  editId: null,
  center: null,
  radius: 150,
  begin: (opts) =>
    set({
      active: true,
      editId: opts?.editId ?? null,
      center: opts?.center ?? null,
      radius: opts?.radius ?? 150,
    }),
  setCenter: (c) => set({ center: c }),
  setRadius: (r) => set({ radius: r }),
  cancel: () => set({ active: false, editId: null, center: null, radius: 150 }),
}));
