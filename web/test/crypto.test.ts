import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { beforeAll, describe, expect, it } from 'vitest';

import {
  aeadDecrypt,
  aeadEncrypt,
  computeSafetyCode,
  generateIdentityKeyPair,
  initCrypto,
  openFramed,
  openSealed,
  pad,
  sealToPublicKey,
  unpad,
} from '../src/crypto/aulCrypto';

const here = dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(
  readFileSync(join(here, '../../vectors/crypto-vectors.json'), 'utf8'),
) as {
  safety_code: {
    pub_a_hex: string;
    pub_b_hex: string;
    digest_hex: string;
    emojis: string[];
    hex_fallback: string;
  }[];
  aead_xchacha20poly1305_ietf: {
    key_hex: string;
    nonce_hex: string;
    plaintext_utf8: string;
    ad_hex: string;
    ciphertext_hex: string;
  }[];
  crypto_box_seal: {
    recipient_priv_hex: string;
    recipient_pub_hex: string;
    plaintext_hex: string;
    sealed_hex: string;
  }[];
  place_framed: {
    key_hex: string;
    nonce_hex: string;
    plaintext_utf8: string;
    ad_utf8: string;
    block: number;
    padded_hex: string;
    framed_hex: string;
  }[];
};

function fromHex(h: string): Uint8Array {
  if (!h) return new Uint8Array(0);
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.substr(i * 2, 2), 16);
  return out;
}
function toHex(b: Uint8Array): string {
  return Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
}

beforeAll(async () => {
  await initCrypto();
});

describe('cross-language crypto vectors (Go ⟷ Dart ⟷ JS)', () => {
  it('reproduces every Go/Dart safety code byte-for-byte', async () => {
    expect(vectors.safety_code.length).toBeGreaterThan(0);
    for (const v of vectors.safety_code) {
      const code = await computeSafetyCode(fromHex(v.pub_a_hex), fromHex(v.pub_b_hex));
      expect(code.emojis).toEqual(v.emojis);
      expect(code.hexFallback).toBe(v.hex_fallback);
      expect(toHex(code.digest)).toBe(v.digest_hex);
    }
  });

  it('decrypts Go XChaCha20 ciphertext and re-encrypts identically', () => {
    expect(vectors.aead_xchacha20poly1305_ietf.length).toBeGreaterThan(0);
    for (const v of vectors.aead_xchacha20poly1305_ietf) {
      const key = fromHex(v.key_hex);
      const nonce = fromHex(v.nonce_hex);
      const ct = fromHex(v.ciphertext_hex);
      const adBytes = fromHex(v.ad_hex);
      const ad = adBytes.length ? adBytes : null;
      const expected = new TextEncoder().encode(v.plaintext_utf8);

      // JS decrypts what Go sealed.
      expect(aeadDecrypt(ct, nonce, key, ad)).toEqual(expected);
      // JS re-encrypts to byte-identical ciphertext.
      expect(aeadEncrypt(expected, nonce, key, ad)).toEqual(ct);
    }
  });

  it('opens Go crypto_box_seal envelopes and round-trips its own', () => {
    expect(vectors.crypto_box_seal.length).toBeGreaterThan(0);
    for (const v of vectors.crypto_box_seal) {
      const pub = fromHex(v.recipient_pub_hex);
      const priv = fromHex(v.recipient_priv_hex);
      const sealed = fromHex(v.sealed_hex);
      // JS opens what Go sealed (Go → JS key-envelope interop).
      expect(toHex(openSealed(sealed, pub, priv))).toBe(v.plaintext_hex);
    }
    // JS seals to a fresh identity and opens it back.
    const id = generateIdentityKeyPair();
    const secret = new TextEncoder().encode('the-circle-key-K_c-material-here');
    const box = sealToPublicKey(secret, id.publicKey);
    expect(openSealed(box, id.publicKey, id.privateKey)).toEqual(secret);
  });

  it('reproduces the Go place padding + framing byte layout (place_framed)', () => {
    expect(vectors.place_framed.length).toBeGreaterThan(0);
    for (const v of vectors.place_framed) {
      const key = fromHex(v.key_hex);
      const ad = new TextEncoder().encode(v.ad_utf8);
      const plain = new TextEncoder().encode(v.plaintext_utf8);
      // pad() must be byte-identical to Go's sodium_pad.
      expect(toHex(pad(plain, v.block))).toBe(v.padded_hex);
      // Open Go's framed blob (nonce||ct) with the domain AD and unpad.
      const framed = fromHex(v.framed_hex);
      const opened = unpad(openFramed(framed, key, ad), v.block);
      expect(new TextDecoder().decode(opened)).toBe(v.plaintext_utf8);
      // Wrong AD must NOT open it (domain separation).
      expect(() => openFramed(framed, key, new TextEncoder().encode('aul-sos:v1'))).toThrow();
    }
  });

  it('safety code is order-independent', async () => {
    const a = new Uint8Array(32).fill(0x11);
    const b = new Uint8Array(32).fill(0xee);
    const ab = await computeSafetyCode(a, b);
    const ba = await computeSafetyCode(b, a);
    expect(ab.emojis).toEqual(ba.emojis);
  });
});
