import { create } from 'zustand';

/// Per-user, per-device opt-ins for the retention features. ALL default to
/// false: nothing is enabled until the user explicitly chooses in (anti-stalking
/// — every user is opted OUT by default). Persisted to localStorage so the choice
/// survives reloads; it never leaves the device.
export interface Prefs {
  arrivalEnabled: boolean;
  /// Background Web Push (works with the tab closed). Mirrors the real browser
  /// subscription, which is the source of truth — this flag only remembers the
  /// user's intent so the toggle renders correctly on reload.
  pushEnabled: boolean;
}

interface PrefsState extends Prefs {
  setArrivalEnabled: (v: boolean) => void;
  setPushEnabled: (v: boolean) => void;
}

const STORAGE_KEY = 'aul.prefs.v1';

function load(): Prefs {
  const fallback: Prefs = { arrivalEnabled: false, pushEnabled: false };
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return fallback;
    const parsed = JSON.parse(raw) as Partial<Prefs>;
    // A previously stored `digestEnabled` is simply not read: the feature is gone,
    // and the next write drops it from storage.
    return {
      arrivalEnabled: parsed.arrivalEnabled === true,
      pushEnabled: parsed.pushEnabled === true,
    };
  } catch {
    return fallback;
  }
}

function persist(p: Prefs): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(p));
  } catch {
    /* storage unavailable (private mode / disabled) — keep in-memory only */
  }
}

export const usePrefs = create<PrefsState>((set, get) => {
  /// Writes one flag through to localStorage alongside the current value of the
  /// others (the store IS the in-memory copy, so read it back for the rest).
  const update = (patch: Partial<Prefs>) =>
    set(() => {
      const { arrivalEnabled, pushEnabled } = get();
      persist({ arrivalEnabled, pushEnabled, ...patch });
      return patch;
    });

  return {
    ...load(),
    setArrivalEnabled: (v) => update({ arrivalEnabled: v }),
    setPushEnabled: (v) => update({ pushEnabled: v }),
  };
});
