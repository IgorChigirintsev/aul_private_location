import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Monitor, Moon, Sun } from 'lucide-react';

import { loadTheme, setTheme, THEMES, type Theme } from '../theme';

const ICON = { system: Monitor, light: Sun, dark: Moon } as const;

/// Compact System / Light / Dark segmented control, mirroring LanguageSwitcher.
/// The choice lives outside React (it is a document-level attribute), so the
/// active state is seeded from storage and tracked locally.
export function ThemeSwitcher({ className = '' }: { className?: string }) {
  const { t } = useTranslation();
  const [active, setActive] = useState<Theme>(loadTheme);

  return (
    <div
      className={`inline-flex shrink-0 rounded-full border border-line p-0.5 text-xs ${className}`}
      role="group"
      aria-label={t('theme.label')}
    >
      {THEMES.map((th) => {
        const Icon = ICON[th];
        return (
          <button
            key={th}
            type="button"
            aria-pressed={active === th}
            aria-label={t(`theme.${th}`)}
            title={t(`theme.${th}`)}
            onClick={() => {
              setTheme(th);
              setActive(th);
            }}
            className={`grid h-6 w-8 place-items-center rounded-full transition-colors ${
              active === th ? 'bg-primary text-white' : 'text-ink-soft hover:text-ink'
            }`}
          >
            <Icon size={13} />
          </button>
        );
      })}
    </div>
  );
}
