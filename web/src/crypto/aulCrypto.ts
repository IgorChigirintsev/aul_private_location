import _sodium from 'libsodium-wrappers';

/// Canonical 64-emoji alphabet — MUST match Go (safetycode.go) and Dart
/// (safety_code.dart) byte-for-byte.
export const SAFETY_ALPHABET: readonly string[] = [
  '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼',
  '🐨', '🐯', '🦁', '🐮', '🐷', '🐸', '🐵', '🐔',
  '🐧', '🐦', '🦆', '🦉', '🐴', '🦄', '🐝', '🐛',
  '🦋', '🐌', '🐞', '🐢', '🐍', '🐙', '🐠', '🐬',
  '🐳', '🐘', '🐫', '🐑', '🍎', '🍊', '🍋', '🍌',
  '🍉', '🍇', '🍓', '🍒', '🍑', '🍅', '🌽', '🥕',
  '🍔', '🍕', '🍩', '🍪', '🎂', '🍫', '🍭', '🌵',
  '🌲', '🌸', '🌻', '🌈', '🌙', '🔥', '🌊', '💧',
];

const SAFETY_DOMAIN = 'aul-safety-code:v1';
const SAFETY_LENGTH = 10;
export const CIRCLE_KEY_BYTES = 32;
export const NONCE_BYTES = 24;

export interface SafetyCode {
  emojis: string[];
  digest: Uint8Array;
  hexFallback: string;
}

let sodium: typeof _sodium | null = null;

/// Initializes libsodium. Call (and await) before any other function.
export async function initCrypto(): Promise<void> {
  await _sodium.ready;
  sodium = _sodium;
}

function s(): typeof _sodium {
  if (!sodium) throw new Error('crypto not initialized — await initCrypto() first');
  return sodium;
}

function compareBytes(a: Uint8Array, b: Uint8Array): number {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) {
    if (a[i] !== b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

/// Derives the canonical safety code from two 32-byte X25519 public keys.
/// Order-independent; mirrors the Go/Dart implementation exactly. Uses the Web
/// Crypto SHA-256 (standard, byte-identical across languages — see D-0022).
export async function computeSafetyCode(
  pubA: Uint8Array,
  pubB: Uint8Array,
): Promise<SafetyCode> {
  if (pubA.length !== 32 || pubB.length !== 32) {
    throw new Error('public key must be 32 bytes');
  }
  let low = pubA;
  let high = pubB;
  if (compareBytes(pubA, pubB) > 0) {
    low = pubB;
    high = pubA;
  }
  const domain = new TextEncoder().encode(SAFETY_DOMAIN);
  const input = new Uint8Array(domain.length + 1 + low.length + high.length);
  input.set(domain, 0);
  input[domain.length] = 0x00;
  input.set(low, domain.length + 1);
  input.set(high, domain.length + 1 + low.length);

  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', input));
  const emojis: string[] = [];
  for (let i = 0; i < SAFETY_LENGTH; i++) {
    emojis.push(SAFETY_ALPHABET[digest[i] % 64]);
  }
  const hex = toHex(digest.subarray(0, 8));
  const hexFallback = (hex.match(/.{1,4}/g) ?? []).join('-');
  return { emojis, digest, hexFallback };
}

/// Seals plaintext under a circle key with a fresh random nonce.
export function sealPing(
  plaintext: Uint8Array,
  key: Uint8Array,
): { nonce: Uint8Array; ciphertext: Uint8Array } {
  const nonce = s().randombytes_buf(NONCE_BYTES);
  const ciphertext = s().crypto_aead_xchacha20poly1305_ietf_encrypt(
    plaintext,
    null,
    null,
    nonce,
    key,
  );
  return { nonce, ciphertext };
}

/// Opens a sealed ping; throws on authentication failure.
export function openPing(nonce: Uint8Array, ciphertext: Uint8Array, key: Uint8Array): Uint8Array {
  return s().crypto_aead_xchacha20poly1305_ietf_decrypt(null, ciphertext, null, nonce, key);
}

/// Seals plaintext into a self-framed blob (nonce || ciphertext) — used for
/// single-blob fields like the circle name, places, and SOS. The optional
/// associated data [ad] provides domain separation (e.g. "aul-place:v1" vs
/// "aul-sos:v1") so a ciphertext of one type cannot be replayed as another; it
/// defaults to null (the circle-name layout, unchanged).
export function sealFramed(plaintext: Uint8Array, key: Uint8Array, ad: Uint8Array | null = null): Uint8Array {
  const nonce = s().randombytes_buf(NONCE_BYTES);
  const ciphertext = aeadEncrypt(plaintext, nonce, key, ad);
  const out = new Uint8Array(nonce.length + ciphertext.length);
  out.set(nonce, 0);
  out.set(ciphertext, nonce.length);
  return out;
}

/// Opens a self-framed blob produced by sealFramed. [ad] must match what was
/// used to seal (throws on mismatch — that's the domain-separation guarantee).
export function openFramed(framed: Uint8Array, key: Uint8Array, ad: Uint8Array | null = null): Uint8Array {
  return aeadDecrypt(framed.subarray(NONCE_BYTES), framed.subarray(0, NONCE_BYTES), key, ad);
}

export function randomCircleKey(): Uint8Array {
  return s().randombytes_buf(CIRCLE_KEY_BYTES);
}

/// XChaCha20 with explicit nonce + associated data (used by the cross-vector test).
export function aeadEncrypt(
  message: Uint8Array,
  nonce: Uint8Array,
  key: Uint8Array,
  ad: Uint8Array | null,
): Uint8Array {
  return s().crypto_aead_xchacha20poly1305_ietf_encrypt(message, ad, null, nonce, key);
}

export function aeadDecrypt(
  ciphertext: Uint8Array,
  nonce: Uint8Array,
  key: Uint8Array,
  ad: Uint8Array | null,
): Uint8Array {
  return s().crypto_aead_xchacha20poly1305_ietf_decrypt(null, ciphertext, ad, nonce, key);
}

/// Fixed-size padding (matches libsodium sodium_pad used by the reporter).
export function pad(buf: Uint8Array, blockSize: number): Uint8Array {
  return s().pad(buf, blockSize);
}
export function unpad(buf: Uint8Array, blockSize: number): Uint8Array {
  return s().unpad(buf, blockSize);
}

/// Generates a new X25519 identity keypair (web identity — see THREAT_MODEL).
export function generateIdentityKeyPair(): { publicKey: Uint8Array; privateKey: Uint8Array } {
  const kp = s().crypto_box_keypair();
  return { publicKey: kp.publicKey, privateKey: kp.privateKey };
}

/// Anonymously seals a message to a recipient's X25519 public key
/// (crypto_box_seal) — used to distribute K_c as a key envelope.
export function sealToPublicKey(message: Uint8Array, recipientPublicKey: Uint8Array): Uint8Array {
  return s().crypto_box_seal(message, recipientPublicKey);
}

/// Opens a sealed key envelope addressed to (publicKey, privateKey).
export function openSealed(
  sealed: Uint8Array,
  publicKey: Uint8Array,
  privateKey: Uint8Array,
): Uint8Array {
  return s().crypto_box_seal_open(sealed, publicKey, privateKey);
}

/// base64 helpers (standard, with padding — matches the server's blobs).
export function toBase64(bytes: Uint8Array): string {
  return s().to_base64(bytes, _sodium.base64_variants.ORIGINAL);
}
export function fromBase64(str: string): Uint8Array {
  return s().from_base64(str, _sodium.base64_variants.ORIGINAL);
}
/// URL-safe base64 without padding (invite fragment carries K_c this way).
export function fromBase64Url(str: string): Uint8Array {
  return s().from_base64(str, _sodium.base64_variants.URLSAFE_NO_PADDING);
}
/// URL-safe base64 without padding — the encoder for everything that rides in a
/// link fragment (the invite's K_c, a live share's K_share). Inverse of
/// fromBase64Url.
export function toBase64Url(bytes: Uint8Array): string {
  return s().to_base64(bytes, _sodium.base64_variants.URLSAFE_NO_PADDING);
}
