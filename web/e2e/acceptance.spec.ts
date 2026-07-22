import { expect, test } from '@playwright/test';

import { initCrypto, pad, sealPing, toBase64 } from '../src/crypto/aulCrypto';

// Phase-3 acceptance: "a watcher sees the reporter move in real time".
// The whole flow runs in a real browser against the real Go server: register →
// create a circle (K_c generated in-browser) → post two encrypted pings → the
// WebSocket delivers them → the browser decrypts K_c and the marker appears and
// MOVES. Pings are sealed here with the K_c we read out of the browser's
// IndexedDB, and posted with the browser's own cookies.

test('watcher sees an encrypted reporter position appear and move live', async ({ page }) => {
  await initCrypto();
  const email = `watcher+${Date.now()}@example.com`;

  // Guard the basemap against CSP regressions: MapLibre fetches the style,
  // tiles, glyphs and sprites from the OpenFreeMap origin. A prior bug shipped a
  // CSP with `connect-src 'self'` that silently blocked all of them — the marker
  // overlay still rendered (it's a DOM layer), so only watching the tile
  // requests catches a blank map.
  //
  // An ABORT is not a block, and must not count: the camera flies from z1.5 to
  // z14 on the first fix, and MapLibre cancels the z7/z9 tiles it requested on the
  // way as soon as it no longer needs them. That is the library working correctly.
  // Counting those made this guard fail whenever the tile server answered slower
  // than the flight — a false alarm about a real risk, which is the kind of test
  // that gets muted rather than heeded. A CSP block never looks like this (it
  // arrives as ERR_BLOCKED_BY_*), and would also sink the tileOk poll below.
  const tileFailures: string[] = [];
  let tileOk = 0;
  page.on('requestfailed', (req) => {
    if (!req.url().includes('tiles.openfreemap.org')) return;
    const err = req.failure()?.errorText ?? 'failed';
    if (err.includes('ERR_ABORTED')) return;
    tileFailures.push(`${req.url()} — ${err}`);
  });
  page.on('response', (res) => {
    if (res.url().includes('tiles.openfreemap.org') && res.ok()) tileOk += 1;
  });

  // "/" serves the public marketing landing to signed-out visitors (D-0041);
  // the auth form lives at /login.
  await page.goto('/login');
  await page.getByRole('button', { name: 'Create account' }).first().click();
  await page.getByPlaceholder('Email').fill(email);
  await page.getByPlaceholder('Password').fill('watcher-strong-pass');
  await page.getByRole('button', { name: 'Create account' }).last().click();

  // Create a circle (a window.prompt handles the name).
  page.once('dialog', (d) => d.accept('Family'));
  await page.getByRole('button', { name: 'Create a circle' }).click();

  // The live map mounts (MapLibre attaches to the container).
  await expect(page.getByTestId('map')).toHaveClass(/maplibregl-map/);

  // ...and it has real size. A 0-height container renders nothing even when the
  // style/tiles load fine — maplibre-gl.css's unlayered `.maplibregl-map{position:
  // relative}` can beat Tailwind's `@layer` `absolute` and collapse it. Assert a
  // genuine box so a blank map can't pass again (see MapView).
  const mapBox = await page.getByTestId('map').boundingBox();
  expect(mapBox, 'map container has no bounding box').not.toBeNull();
  expect(mapBox!.height, 'map container collapsed to ~0 height').toBeGreaterThan(200);
  expect(mapBox!.width, 'map container collapsed to ~0 width').toBeGreaterThan(200);

  // Read K_c + circle id out of IndexedDB.
  const secret = await page.evaluate(
    () =>
      new Promise<{ id: string; key: number[] }>((resolve, reject) => {
        const req = indexedDB.open('aul', 1);
        req.onsuccess = () => {
          const store = req.result.transaction('keys', 'readonly').objectStore('keys');
          const keysReq = store.getAllKeys();
          keysReq.onsuccess = () => {
            const name = keysReq.result.map(String).find((k) => k.startsWith('circle:'));
            if (!name) return reject(new Error('no circle key'));
            const g = store.get(name);
            g.onsuccess = () => {
              // Stored value is a keyring (Uint8Array[]); use the newest key.
              const ring = g.result as Uint8Array[];
              const key = ring[ring.length - 1];
              resolve({ id: name.slice('circle:'.length), key: Array.from(key) });
            };
          };
        };
        req.onerror = () => reject(req.error);
      }),
  );
  const circleKey = new Uint8Array(secret.key);

  const postPing = async (lat: number, lng: number) => {
    const fix = { lat, lng, batt: 88, ts: Date.now(), mode: 'precise' };
    const plain = pad(new TextEncoder().encode(JSON.stringify(fix)), 256);
    const { nonce, ciphertext } = sealPing(plain, circleKey);
    const res = await page.context().request.post('/v1/pings/batch', {
      data: {
        pings: [
          {
            circle_id: secret.id,
            client_id: crypto.randomUUID(),
            nonce: toBase64(nonce),
            ciphertext: toBase64(ciphertext),
            captured_at: new Date().toISOString(),
          },
        ],
      },
    });
    expect(res.ok()).toBeTruthy();
  };

  // First position → a marker appears (WS delivered + decrypted client-side).
  await postPing(43.238949, 76.889709);
  const marker = page.locator('.aul-marker');
  await expect(marker).toHaveCount(1);
  const box1 = await marker.boundingBox();

  // Second, clearly different position → the SAME marker moves.
  await postPing(43.25, 76.95);
  await expect
    .poll(async () => {
      const b = await marker.boundingBox();
      return b && box1 ? Math.hypot(b.x - box1.x, b.y - box1.y) : 0;
    }, { timeout: 15_000 })
    .toBeGreaterThan(5);

  // The basemap must have actually loaded — the CSP must allow the tiles origin.
  await expect.poll(() => tileOk, { timeout: 15_000 }).toBeGreaterThan(0);
  expect(tileFailures, `map tiles were blocked:\n${tileFailures.join('\n')}`).toHaveLength(0);
});
