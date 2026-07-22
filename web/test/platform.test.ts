import { afterEach, describe, expect, it, vi } from 'vitest';

import { detectPlatform } from '../src/data/platform';

describe('detectPlatform', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('trusts the structured userAgentData.mobile hint when present', () => {
    vi.stubGlobal('navigator', { userAgentData: { mobile: true }, userAgent: 'irrelevant' });
    expect(detectPlatform()).toBe('web-mobile');

    vi.stubGlobal('navigator', { userAgentData: { mobile: false }, userAgent: 'iPhone Mobile' });
    // The structured hint wins over the UA string, so a desktop that happens to
    // carry a mobile-looking UA is still classed desktop.
    expect(detectPlatform()).toBe('web');
  });

  it('falls back to a UA sniff when userAgentData is absent', () => {
    vi.stubGlobal('navigator', {
      userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Mobile/15E148',
    });
    expect(detectPlatform()).toBe('web-mobile');

    vi.stubGlobal('navigator', {
      userAgent: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36',
    });
    expect(detectPlatform()).toBe('web');
  });
});
