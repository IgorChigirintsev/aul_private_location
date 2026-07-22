import { describe, expect, it } from 'vitest';

import { vapidKeyToBytes } from '../src/data/push';

/// The VAPID application server key is the one place where a byte-level slip is
/// invisible until a real browser refuses to subscribe: PushManager wants the raw
/// 65-byte uncompressed P-256 point, while the server publishes it as base64url.
describe('vapidKeyToBytes', () => {
  /// A representative VAPID public key: 0x04 || X || Y, base64url, unpadded.
  const raw = new Uint8Array(65);
  raw[0] = 0x04;
  for (let i = 1; i < 65; i++) raw[i] = i * 3;
  const b64url = btoa(String.fromCharCode(...raw))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');

  it('decodes an unpadded base64url key to the 65 raw bytes', () => {
    const out = vapidKeyToBytes(b64url);
    expect(out.length).toBe(65); // subscribe() throws on any other length
    expect(out).toEqual(raw);
  });

  it('tolerates padding', () => {
    const padded = b64url + '='.repeat((4 - (b64url.length % 4)) % 4);
    expect(vapidKeyToBytes(padded)).toEqual(raw);
  });

  it('decodes the URL-safe alphabet (- and _), not just standard base64', () => {
    // 0xfb 0xff 0xbf encodes to "+/+/" in standard base64 and "-_-_" in URL-safe:
    // a decoder that forgot the swap would throw or return the wrong bytes.
    expect(vapidKeyToBytes('-_-_')).toEqual(new Uint8Array([0xfb, 0xff, 0xbf]));
  });
});
