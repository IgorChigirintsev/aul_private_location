import { create } from 'zustand';

/// Per-device info used by the map: the platform (to tag web devices with a
/// "PC" badge) and the owning user id (to resolve the member's profile —
/// nickname + avatar — for the marker).
export interface DeviceInfo {
  platform: string;
  userId: string;
}

interface DevicesState {
  devices: Record<string, DeviceInfo>;
  setDevices: (devices: { id: string; platform: string; user_id: string }[]) => void;
}

export const useDevices = create<DevicesState>((set) => ({
  devices: {},
  setDevices: (devices) =>
    set({
      devices: Object.fromEntries(
        devices.map((d) => [d.id, { platform: d.platform, userId: d.user_id }]),
      ),
    }),
}));
