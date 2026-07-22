import { beforeAll, describe, expect, it } from 'vitest';

import { initCrypto, randomCircleKey, sealFramed, toBase64 } from '../src/crypto/aulCrypto';
import { openProfile, sealProfile } from '../src/data/profileCodec';
import { memberDisplayName } from '../src/store/profiles';

beforeAll(async () => {
  await initCrypto();
});

describe('profileCodec', () => {
  it('round-trips a nickname + avatar under the same key', () => {
    const key = randomCircleKey();
    const avatar = 'data:image/jpeg;base64,/9j/AAAA';
    const b64 = sealProfile({ nick: 'Ata', avatar }, key);
    expect(openProfile(b64, [key])).toEqual({ nick: 'Ata', avatar });
  });

  it('omits the avatar key when none is set (keeps the blob small)', () => {
    const key = randomCircleKey();
    const withAvatar = sealProfile({ nick: 'Ata', avatar: 'data:image/jpeg;base64,/9j/AAAA' }, key);
    const noAvatar = sealProfile({ nick: 'Ata' }, key);
    expect(noAvatar.length).toBeLessThan(withAvatar.length);
    expect(openProfile(noAvatar, [key])).toEqual({ nick: 'Ata', avatar: undefined });
  });

  it('preserves an empty nickname (falls back to the email in the UI)', () => {
    const key = randomCircleKey();
    const b64 = sealProfile({ nick: '' }, key);
    expect(openProfile(b64, [key])).toEqual({ nick: '', avatar: undefined });
  });

  it('returns null when no key in the ring opens the profile', () => {
    const b64 = sealProfile({ nick: 'Ata' }, randomCircleKey());
    expect(openProfile(b64, [randomCircleKey()])).toBeNull();
  });

  it('opens across a rotation keyring (tries every key)', () => {
    const oldKey = randomCircleKey();
    const newKey = randomCircleKey();
    const b64 = sealProfile({ nick: 'Guler' }, oldKey);
    expect(openProfile(b64, [newKey, oldKey])?.nick).toBe('Guler');
  });

  it('never throws on malformed input', () => {
    expect(openProfile('not base64 !!!', [randomCircleKey()])).toBeNull();
    expect(openProfile('', [randomCircleKey()])).toBeNull();
  });

  it('rejects a blob sealed under a different associated data (domain separation)', () => {
    // A blob sealed with some other AD (e.g. a place's "aul-place:v1") must NOT
    // open as a profile, even with the correct key.
    const key = randomCircleKey();
    const wrongAd = new TextEncoder().encode('aul-place:v1');
    const b64 = toBase64(sealFramed(new TextEncoder().encode('{"nick":"Ata"}'), key, wrongAd));
    expect(openProfile(b64, [key])).toBeNull();
  });
});

describe('memberDisplayName', () => {
  const profiles = {
    ata: { nick: 'Ata', email: 'ata@example.com' },
    guler: { email: 'guler@example.com' }, // no nickname set
    blank: { nick: '   ', email: 'blank@example.com' }, // whitespace-only nickname
  };

  it('prefers the nickname, then the email', () => {
    expect(memberDisplayName(profiles, 'ata')).toBe('Ata');
    expect(memberDisplayName(profiles, 'guler')).toBe('guler@example.com');
  });

  it('treats a blank nickname as unset', () => {
    expect(memberDisplayName(profiles, 'blank')).toBe('blank@example.com');
  });

  it('falls back to a short user id when the profile is unknown', () => {
    // e.g. a member whose profile has not been decrypted into the store yet.
    expect(memberDisplayName(profiles, 'abcdef0123456789')).toBe('abcdef');
    expect(memberDisplayName({}, 'xyz')).toBe('xyz');
  });
});
