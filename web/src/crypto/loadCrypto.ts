/// Dynamically imports libsodium and initialises it.
///
/// Nothing here statically imports `aulCrypto` — that is the whole point: the
/// wasm bundle (and every module that pulls it) stays OUT of the entry chunk, so
/// the public landing renders without downloading ~1 MB of crypto it never uses.
///
/// Every route that touches crypto must await this first: `aulCrypto` throws if a
/// primitive runs before init. `initCrypto` is idempotent (`await sodium.ready`),
/// so awaiting it per-route costs nothing after the first load.
export async function loadCrypto(): Promise<void> {
  const { initCrypto } = await import('./aulCrypto');
  await initCrypto();
}
