import { describe, expect, it } from 'vitest';

import i18n from '../src/i18n';
import {
  ACCURACY_MIN_DRAW_M,
  ACCURACY_POOR_M,
  accuracyParts,
  formatAccuracy,
  isPoorAccuracy,
  isUsableAccuracy,
  shouldDrawAccuracy,
} from '../src/map/accuracy';

/// The catalogs are bundled, so a fixed `t` per language needs no async init and
/// exercises the SAME path the panel uses (members.accuracy + common.unit.*) —
/// a missing or renamed key fails here rather than showing "members.accuracy".
const en = i18n.getFixedT('en');
const ru = i18n.getFixedT('ru');

describe('isUsableAccuracy', () => {
  it('accepts a present, finite, positive radius', () => {
    expect(isUsableAccuracy(5)).toBe(true);
    expect(isUsableAccuracy(0.5)).toBe(true);
    expect(isUsableAccuracy(1500)).toBe(true);
  });

  it('rejects absent or nonsensical values rather than treating them as certainty', () => {
    expect(isUsableAccuracy(undefined)).toBe(false);
    expect(isUsableAccuracy(null)).toBe(false);
    expect(isUsableAccuracy(0)).toBe(false);
    expect(isUsableAccuracy(-10)).toBe(false);
    expect(isUsableAccuracy(NaN)).toBe(false);
    expect(isUsableAccuracy(Infinity)).toBe(false);
  });
});

describe('shouldDrawAccuracy', () => {
  it('skips a fix with NO reported accuracy — we cannot claim a radius we were not told', () => {
    expect(shouldDrawAccuracy(undefined)).toBe(false);
    expect(shouldDrawAccuracy(null)).toBe(false);
  });

  it('skips a tiny accuracy: sub-pixel noise the dot already tells the truth about', () => {
    expect(shouldDrawAccuracy(5)).toBe(false);
    expect(shouldDrawAccuracy(20)).toBe(false);
    expect(shouldDrawAccuracy(ACCURACY_MIN_DRAW_M - 0.1)).toBe(false);
  });

  it('draws from the threshold up — the Wi-Fi-grade fixes this exists for', () => {
    expect(shouldDrawAccuracy(ACCURACY_MIN_DRAW_M)).toBe(true);
    expect(shouldDrawAccuracy(60)).toBe(true);
    expect(shouldDrawAccuracy(500)).toBe(true);
  });
});

describe('isPoorAccuracy', () => {
  it('is quiet for a fix that is merely imperfect', () => {
    expect(isPoorAccuracy(undefined)).toBe(false);
    expect(isPoorAccuracy(30)).toBe(false);
    expect(isPoorAccuracy(ACCURACY_POOR_M)).toBe(false);
  });

  it('speaks up only past the threshold', () => {
    expect(isPoorAccuracy(ACCURACY_POOR_M + 1)).toBe(true);
    expect(isPoorAccuracy(800)).toBe(true);
  });
});

describe('accuracyParts', () => {
  it('reports whole metres below a kilometre — no false precision on a guess', () => {
    expect(accuracyParts(40, 'en')).toEqual({ value: '40', unit: 'm' });
    expect(accuracyParts(39.6, 'en')).toEqual({ value: '40', unit: 'm' });
    expect(accuracyParts(999, 'ru')).toEqual({ value: '999', unit: 'm' });
  });

  it('switches to kilometres, one decimal, in the locale notation', () => {
    expect(accuracyParts(1200, 'en')).toEqual({ value: '1.2', unit: 'km' });
    expect(accuracyParts(1200, 'ru')).toEqual({ value: '1,2', unit: 'km' });
    expect(accuracyParts(12345, 'en')).toEqual({ value: '12.3', unit: 'km' });
  });

  it('lets the ROUNDED metres pick the unit, so 999.6 m is not "1000 m"', () => {
    expect(accuracyParts(999.6, 'en')).toEqual({ value: '1', unit: 'km' });
  });
});

describe('formatAccuracy', () => {
  it('formats metres in both catalogs', () => {
    expect(formatAccuracy(40, 'en', en)).toBe('±40 m');
    expect(formatAccuracy(40, 'ru', ru)).toBe('±40 м');
  });

  it('formats kilometres in both catalogs, with the locale decimal separator', () => {
    expect(formatAccuracy(1200, 'en', en)).toBe('±1.2 km');
    expect(formatAccuracy(1200, 'ru', ru)).toBe('±1,2 км');
  });
});
