import { describe, expect, it } from 'vitest';

import en from '../src/i18n/locales/en.json';
import ru from '../src/i18n/locales/ru.json';

type Catalog = Record<string, unknown>;

/// Flattens a nested catalog into dotted leaf-key paths ("landing.hero.subtitle").
function leafKeys(obj: Catalog, prefix = ''): string[] {
  const out: string[] = [];
  for (const [k, v] of Object.entries(obj)) {
    const path = prefix ? `${prefix}.${k}` : k;
    if (v !== null && typeof v === 'object' && !Array.isArray(v)) {
      out.push(...leafKeys(v as Catalog, path));
    } else {
      out.push(path);
    }
  }
  return out;
}

describe('i18n catalogs', () => {
  it('en.json and ru.json have the EXACT same key set', () => {
    const enKeys = new Set(leafKeys(en as Catalog));
    const ruKeys = new Set(leafKeys(ru as Catalog));
    const missingInRu = [...enKeys].filter((k) => !ruKeys.has(k)).sort();
    const extraInRu = [...ruKeys].filter((k) => !enKeys.has(k)).sort();
    // Empty arrays make any mismatch print the offending keys.
    expect(missingInRu).toEqual([]);
    expect(extraInRu).toEqual([]);
    expect(ruKeys.size).toBe(enKeys.size);
  });

  it('every leaf is a non-empty string in both catalogs', () => {
    for (const [name, cat] of [
      ['en', en],
      ['ru', ru],
    ] as const) {
      const walk = (obj: Catalog, prefix = '') => {
        for (const [k, v] of Object.entries(obj)) {
          const path = `${name}:${prefix ? `${prefix}.` : ''}${k}`;
          if (v !== null && typeof v === 'object' && !Array.isArray(v)) {
            walk(v as Catalog, prefix ? `${prefix}.${k}` : k);
          } else {
            expect(typeof v, path).toBe('string');
            expect((v as string).length, path).toBeGreaterThan(0);
          }
        }
      };
      walk(cat as Catalog);
    }
  });
});
