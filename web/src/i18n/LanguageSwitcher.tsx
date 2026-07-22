import { useTranslation } from 'react-i18next';

import { SUPPORTED_LANGUAGES, type Lang } from './index';

const SHORT: Record<Lang, string> = { en: 'EN', ru: 'RU' };

/// Compact EN / RU segmented control. Persists the choice to localStorage (via
/// the i18next language detector's cache) and updates <html lang> on change.
export function LanguageSwitcher({ className = '' }: { className?: string }) {
  const { i18n, t } = useTranslation();
  const active = i18n.resolvedLanguage ?? i18n.language;

  return (
    <div
      className={`inline-flex shrink-0 rounded-full border border-line p-0.5 text-xs ${className}`}
      role="group"
      aria-label={t('language.label')}
    >
      {SUPPORTED_LANGUAGES.map((lng) => (
        <button
          key={lng}
          type="button"
          aria-pressed={active === lng}
          aria-label={t(`language.${lng}`)}
          onClick={() => void i18n.changeLanguage(lng)}
          className={`rounded-full px-2.5 py-1 font-semibold transition-colors ${
            active === lng ? 'bg-primary text-white' : 'text-ink-soft hover:text-ink'
          }`}
        >
          {SHORT[lng]}
        </button>
      ))}
    </div>
  );
}
