import { create } from 'zustand';

interface ConnectionState {
  /// Whether the realtime WebSocket is currently connected.
  ///
  /// Client-INFERRED: an offline or unreachable server cannot announce its own
  /// offline-ness, so this is driven from the socket's own open/close events
  /// (see RealtimeClient.onStatus), not from any server message. Optimistically
  /// `true` until a real drop is observed, so we never flash the "paused" banner
  /// on first paint or when no realtime subscription is active.
  online: boolean;
  /// When the realtime link most recently dropped (epoch ms), or null while
  /// connected. Frozen at the FIRST moment of an outage — a later failed
  /// reconnect must NOT reset it — so the offline banner can honestly say
  /// "last connected N ago" and the viewer knows how stale the map may be.
  lastOnlineAt: number | null;
  setOnline: (online: boolean) => void;
}

/// Live-connection health for the dashboard. When this flips to `false` the
/// dashboard shows a small, honest "Live updates paused" banner, so a viewer is
/// never left trusting a last-known position that can no longer be refreshed.
export const useConnection = create<ConnectionState>((set) => ({
  online: true,
  lastOnlineAt: null,
  setOnline: (online) =>
    set((s) => ({
      online,
      // Stamp the drop only on the true→false transition; keep it across repeated
      // reconnect failures; clear it the instant we're back.
      lastOnlineAt: online ? null : s.online ? Date.now() : s.lastOnlineAt,
    })),
}));
