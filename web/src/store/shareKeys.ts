import { create } from 'zustand';

/// K_share for every live-share session THIS browser created, base64url — the
/// exact encoding the link fragment carries.
///
/// The server has never seen these keys and never will: they are what decrypts
/// the shared position, and the whole point of the design is that only the link
/// holds them. They live here (localStorage) for one reason — a reload must keep
/// feeding a session that is still running, and the key cannot be re-fetched from
/// anywhere. Lose this store and the session is simply unfeedable (revoke it).
///
/// Entries are pruned as soon as a session stops being live, so a dead session's
/// key does not linger on disk.
const STORAGE_KEY = 'aul.share.keys.v1';

interface ShareKeysState {
  /// sessionId → base64url(K_share)
  keys: Record<string, string>;
  add: (id: string, keyB64Url: string) => void;
  forget: (id: string) => void;
  /// Drops every key whose session is no longer live. Call ONLY with a list from
  /// a successful fetch — pruning on a failed one would throw away the keys of
  /// perfectly live sessions.
  keepOnly: (liveIds: string[]) => void;
}

function load(): Record<string, string> {
  try {
    if (typeof localStorage === 'undefined') return {};
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw) as unknown;
    if (!parsed || typeof parsed !== 'object') return {};
    const out: Record<string, string> = {};
    for (const [id, key] of Object.entries(parsed as Record<string, unknown>)) {
      if (typeof key === 'string' && key.length > 0) out[id] = key;
    }
    return out;
  } catch {
    return {};
  }
}

function persist(keys: Record<string, string>): void {
  try {
    if (typeof localStorage === 'undefined') return;
    localStorage.setItem(STORAGE_KEY, JSON.stringify(keys));
  } catch {
    /* storage unavailable (private mode / disabled) — keep in-memory only */
  }
}

export const useShareKeys = create<ShareKeysState>((set) => ({
  keys: load(),
  add: (id, keyB64Url) =>
    set((state) => {
      const keys = { ...state.keys, [id]: keyB64Url };
      persist(keys);
      return { keys };
    }),
  forget: (id) =>
    set((state) => {
      if (!(id in state.keys)) return state;
      const keys = { ...state.keys };
      delete keys[id];
      persist(keys);
      return { keys };
    }),
  keepOnly: (liveIds) =>
    set((state) => {
      const live = new Set(liveIds);
      const keys: Record<string, string> = {};
      for (const [id, key] of Object.entries(state.keys)) {
        if (live.has(id)) keys[id] = key;
      }
      if (Object.keys(keys).length === Object.keys(state.keys).length) return state;
      persist(keys);
      return { keys };
    }),
}));
