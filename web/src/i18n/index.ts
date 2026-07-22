import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';
import LanguageDetector from 'i18next-browser-languagedetector';

import { keystore } from '../data/keystore';
import en from './locales/en.json';
import ru from './locales/ru.json';

/// The languages the dashboard ships with. Add a locale JSON + an entry here to
/// grow the list; the key-parity test keeps every catalog in lock-step.
export const SUPPORTED_LANGUAGES = ['en', 'ru'] as const;
export type Lang = (typeof SUPPORTED_LANGUAGES)[number];

/// localStorage key for the user's explicit choice. Detection order is:
/// explicit choice (localStorage) → navigator.language → nearest of our two.
const STORAGE_KEY = 'aul.lang';

/// Languages for which RUSSIAN is the nearer of the two we ship: Cyrillic-script
/// and post-Soviet locales, where Russian is far more likely to be readable than
/// English. A Ukrainian or Kazakh device should land on Russian, not English.
/// Everything else falls back to English.
const RU_NEAR = new Set([
  'uk', 'be', 'kk', 'ky', 'uz', 'tg', 'tk', 'az', 'hy', 'ka', 'mo', 'mn',
  'bg', 'sr', 'mk',
]);

/// Picks the closest shipped language for a detected code. Exported for tests.
export function nearestLanguage(code: string | undefined): Lang {
  const base = (code ?? '').toLowerCase().split('-')[0];
  if (base === 'ru') return 'ru';
  if (base === 'en') return 'en';
  return RU_NEAR.has(base) ? 'ru' : 'en';
}

// Resources are BUNDLED (imported above), not fetched over HTTP — so init is
// synchronous and there is never a loading/Suspense gate to flicker through.
void i18n
  .use(LanguageDetector)
  .use(initReactI18next)
  .init({
    resources: {
      en: { translation: en },
      ru: { translation: ru },
    },
    // Not a flat 'en': an unsupported language falls back to whichever of our two
    // is NEARER to it (see nearestLanguage) — Ukrainian lands on Russian.
    fallbackLng: (code?: string) => nearestLanguage(code),
    supportedLngs: [...SUPPORTED_LANGUAGES],
    nonExplicitSupportedLngs: true, // ru-RU → ru
    load: 'languageOnly',
    interpolation: { escapeValue: false }, // React already escapes output
    detection: {
      order: ['localStorage', 'navigator'],
      lookupLocalStorage: STORAGE_KEY,
      caches: ['localStorage'],
    },
    react: { useSuspense: false },
    initAsync: false, // synchronous init — bundled resources, no loading gate
  });

/// Keep the document's <html lang> in sync with the active language, for
/// accessibility and correct hyphenation/quotation rendering. The same hook
/// mirrors the choice into IndexedDB: the service worker shows background push
/// notifications and cannot read the localStorage where the choice lives, so
/// without this mirror it could only guess from the browser's own language.
function onLanguage(lng: string): void {
  const lang = (lng || 'en').split('-')[0];
  if (typeof document !== 'undefined') document.documentElement.lang = lang;
  if (typeof indexedDB === 'undefined') return; // node/jsdom tests — nothing to mirror to
  void keystore.saveUiLang(lang).catch(() => {
    /* best-effort: a missing mirror only costs the SW its language, nothing else */
  });
}
onLanguage(i18n.resolvedLanguage ?? i18n.language);
i18n.on('languageChanged', onLanguage);

export default i18n;
