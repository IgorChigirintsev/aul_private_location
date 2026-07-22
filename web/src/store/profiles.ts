import { create } from 'zustand';

/// A member's decrypted per-circle profile, keyed by user id. `email` is always
/// kept as the fallback for the name (and its first letter for the avatar) where
/// no nickname/avatar is set.
export interface StoredProfile {
  nick?: string;
  avatar?: string;
  email: string;
  /// The member's CURRENT sharing mode (server metadata, not from a ping). A
  /// paused member stops reporting, so their last marker would otherwise sit on
  /// the map looking live forever — the map greys it out using this instead.
  precisionMode?: 'precise' | 'city' | 'paused';
}

/// The name to show for a member: their nickname, else their email, else a short
/// user id — the same fallback chain the members list uses. Pure, so panels that
/// only have a user id label members consistently.
export function memberDisplayName(
  profiles: Record<string, StoredProfile>,
  userId: string,
): string {
  const p = profiles[userId];
  return p?.nick?.trim() || p?.email || userId.slice(0, 6);
}

interface ProfilesState {
  profiles: Record<string, StoredProfile>;
  setProfiles: (list: (StoredProfile & { userId: string })[]) => void;
}

export const useProfiles = create<ProfilesState>((set) => ({
  profiles: {},
  setProfiles: (list) =>
    set({
      profiles: Object.fromEntries(
        list.map((p) => [
          p.userId,
          { nick: p.nick, avatar: p.avatar, email: p.email, precisionMode: p.precisionMode },
        ]),
      ),
    }),
}));
