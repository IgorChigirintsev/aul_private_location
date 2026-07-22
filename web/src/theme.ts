/// The user's colour-theme choice. "system" follows the OS (the default, and what
/// the app did before there was a switch); "light"/"dark" pin it.
///
/// Applied by stamping `<html data-theme="...">`: the CSS in index.css keys the
/// dark palette off BOTH `prefers-color-scheme` (when the attribute is absent or
/// not "light") and an explicit `data-theme="dark"`. So "system" just removes the
/// attribute and lets the media query decide — no JS needed to track the OS, and
/// no flash of the wrong theme before this module runs.
export type Theme = 'system' | 'light' | 'dark';

export const THEMES: readonly Theme[] = ['system', 'light', 'dark'] as const;

const STORAGE_KEY = 'aul.theme';

function isTheme(v: unknown): v is Theme {
  return v === 'system' || v === 'light' || v === 'dark';
}

/// The persisted choice, or "system" when unset/unreadable (private mode).
export function loadTheme(): Theme {
  try {
    const v = localStorage.getItem(STORAGE_KEY);
    if (isTheme(v)) return v;
  } catch {
    /* storage blocked — fall through to the system default */
  }
  return 'system';
}

/// Stamps the choice onto <html>. "system" removes the attribute so the
/// prefers-color-scheme rules take over.
export function applyTheme(theme: Theme): void {
  const el = document.documentElement;
  if (theme === 'system') el.removeAttribute('data-theme');
  else el.setAttribute('data-theme', theme);
}

/// Persists and applies in one step — what the switcher calls.
export function setTheme(theme: Theme): void {
  try {
    localStorage.setItem(STORAGE_KEY, theme);
  } catch {
    /* storage blocked — the choice still applies for this page load */
  }
  applyTheme(theme);
}
