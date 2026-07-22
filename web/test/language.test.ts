import { describe, expect, it } from 'vitest';

import { nearestLanguage } from '../src/i18n';

/// We ship exactly two languages. A device set to something else must land on
/// whichever is actually READABLE there — a Ukrainian or Kazakh phone should get
/// Russian, not English, which is what a flat `fallbackLng: 'en'` used to do.
describe('nearestLanguage', () => {
  it('keeps the two languages we ship (region tags included)', () => {
    expect(nearestLanguage('en')).toBe('en');
    expect(nearestLanguage('ru')).toBe('ru');
    expect(nearestLanguage('ru-RU')).toBe('ru');
    expect(nearestLanguage('en-GB')).toBe('en');
    expect(nearestLanguage('RU')).toBe('ru'); // case-insensitive
  });

  it('sends Cyrillic / post-Soviet locales to Russian', () => {
    for (const code of [
      'uk', 'uk-UA', 'be', 'kk', 'ky', 'uz', 'tg', 'tk',
      'az', 'hy', 'ka', 'mn', 'bg', 'sr', 'mk',
    ]) {
      expect(nearestLanguage(code), code).toBe('ru');
    }
  });

  it('falls back to English for everything else', () => {
    for (const code of ['de', 'fr', 'es', 'zh-CN', 'ja', 'tr', 'pl', 'ar', 'pt-BR']) {
      expect(nearestLanguage(code), code).toBe('en');
    }
  });

  it('handles a missing/empty language without throwing', () => {
    expect(nearestLanguage(undefined)).toBe('en');
    expect(nearestLanguage('')).toBe('en');
  });
});
