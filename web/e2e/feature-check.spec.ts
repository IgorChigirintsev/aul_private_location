import { expect, test } from '@playwright/test';

import { initCrypto, pad, sealPing, toBase64 } from '../src/crypto/aulCrypto';

// Runtime verification of four user-requested features that the existing e2e
// suite does not cover directly:
//   1) the SOS raiser's MAP MARKER turns red + pulses for everyone (phase5 only
//      checks the banner);
//   3) the mobile web shows a Google-Maps-style slide-up member sheet;
//   4) the two map buttons — "North up" (reset bearing) and "Centre on me".
// All driven through the real browser + the real Go server (isolated :8099).

type Secret = { id: string; key: Uint8Array };

async function signInFreshCircle(page: import('@playwright/test').Page) {
  const email = `fc+${Date.now()}+${Math.floor(performance.now())}@example.com`;
  await page.goto('/login');
  await page.getByRole('button', { name: 'Create account' }).first().click();
  await page.getByPlaceholder('Email').fill(email);
  await page.getByPlaceholder('Password').fill('feature-check-pass');
  await page.getByRole('button', { name: 'Create account' }).last().click();
  page.once('dialog', (d) => d.accept('Family'));
  await page.getByRole('button', { name: 'Create a circle' }).click();
  await expect(page.getByTestId('map')).toHaveClass(/maplibregl-map/);
}

async function readSecret(page: import('@playwright/test').Page): Promise<Secret> {
  const s = await page.evaluate(
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
              const ring = g.result as Uint8Array[];
              const key = ring[ring.length - 1];
              resolve({ id: name.slice('circle:'.length), key: Array.from(key) });
            };
          };
        };
        req.onerror = () => reject(req.error);
      }),
  );
  return { id: s.id, key: new Uint8Array(s.key) };
}

async function postPing(page: import('@playwright/test').Page, s: Secret, lat: number, lng: number) {
  const fix = { lat, lng, batt: 88, ts: Date.now(), mode: 'precise' };
  const plain = pad(new TextEncoder().encode(JSON.stringify(fix)), 256);
  const { nonce, ciphertext } = sealPing(plain, s.key);
  const res = await page.context().request.post('/v1/pings/batch', {
    data: {
      pings: [
        {
          circle_id: s.id,
          client_id: crypto.randomUUID(),
          nonce: toBase64(nonce),
          ciphertext: toBase64(ciphertext),
          captured_at: new Date().toISOString(),
        },
      ],
    },
  });
  expect(res.ok()).toBeTruthy();
}

test('feature 1: SOS raiser marker turns red and pulses for everyone', async ({ page }) => {
  await initCrypto();
  await signInFreshCircle(page);
  const secret = await readSecret(page);

  // A marker for my own device must exist first.
  await postPing(page, secret, 43.238949, 76.889709);
  const marker = page.locator('.aul-marker');
  await expect(marker).toHaveCount(1);

  // Raise an SOS through the real UI (sealed under K_c; server stamps my device).
  page.once('dialog', (d) => d.accept('need help now'));
  await page.getByTitle('Raise SOS').click();

  // The marker must gain the SOS class...
  await expect(marker).toHaveClass(/aul-marker--sos/, { timeout: 10_000 });

  // ...and the ring must actually be running the red pulse animation (a class
  // with no animation would pass the check above but look dead).
  const anim = await marker.locator('.aul-marker__ring').evaluate(
    (el) => getComputedStyle(el).animationName,
  );
  expect(anim).toContain('aul-sos-pulse');
});

test('feature 4: "North up" resets bearing and "Centre on me" flies to my marker', async ({ page }) => {
  await initCrypto();
  await signInFreshCircle(page);
  const secret = await readSecret(page);
  await postPing(page, secret, 43.238949, 76.889709);
  await expect(page.locator('.aul-marker')).toHaveCount(1);

  // Rotate + pan the map away from my marker.
  await page.evaluate(() => {
    const m = (window as unknown as { __aulMap: any }).__aulMap;
    m.setBearing(42);
    m.jumpTo({ center: [0, 0], zoom: 3 });
  });
  expect(await page.evaluate(() => (window as any).__aulMap.getBearing())).toBeCloseTo(42, 0);

  // "North up" → bearing eases back to 0.
  await page.getByRole('button', { name: 'North up' }).click();
  await expect
    .poll(() => page.evaluate(() => Math.abs((window as any).__aulMap.getBearing())), { timeout: 10_000 })
    .toBeLessThan(1);

  // "Centre on me" → map flies to my ping location.
  await page.getByRole('button', { name: 'Centre on me' }).click();
  await expect
    .poll(
      () =>
        page.evaluate(() => {
          const c = (window as any).__aulMap.getCenter();
          return Math.hypot(c.lng - 76.889709, c.lat - 43.238949);
        }),
      { timeout: 10_000 },
    )
    .toBeLessThan(0.05);
});

test('feature 3: mobile viewport shows a slide-up member sheet (not the desktop dock)', async ({ page }) => {
  await initCrypto();
  await page.setViewportSize({ width: 390, height: 844 }); // iPhone-ish, < 767px
  await signInFreshCircle(page);

  // The Google-Maps-style bottom sheet has a draggable grab handle.
  const handle = page.getByRole('button', { name: 'Resize panel' });
  await expect(handle).toBeVisible();

  // The sheet is docked to the bottom edge of the viewport (a bottom sheet, not
  // a left rail): its top must sit well below the top of the screen at rest.
  const sheet = page.locator('aside.rounded-t-2xl');
  const box = await sheet.boundingBox();
  expect(box, 'bottom sheet has no box').not.toBeNull();
  expect(box!.y, 'sheet should rest near the bottom, not fill the screen').toBeGreaterThan(300);

  // Tapping the handle expands it (peek -> half): it should grow taller.
  const h0 = box!.height;
  await handle.click();
  await expect
    .poll(async () => (await sheet.boundingBox())!.height, { timeout: 5_000 })
    .toBeGreaterThan(h0 + 40);
});

test('feature 3 (desktop): the same panel docks left, with no drag handle', async ({ page }) => {
  await initCrypto();
  await page.setViewportSize({ width: 1280, height: 900 });
  await signInFreshCircle(page);
  // No mobile grab handle on desktop.
  await expect(page.getByRole('button', { name: 'Resize panel' })).toHaveCount(0);
});

test('desktop members panel hugs its content, not the full viewport height', async ({ page }) => {
  await initCrypto();
  await page.setViewportSize({ width: 1280, height: 900 });
  await signInFreshCircle(page);
  const secret = await readSecret(page);
  await postPing(page, secret, 43.238949, 76.889709); // exactly one member on the map
  await expect(page.locator('.aul-marker')).toHaveCount(1);

  const aside = page.locator('aside').filter({ has: page.getByRole('heading', { name: 'People' }) });
  await expect(aside).toBeVisible();
  const box = await aside.boundingBox();
  expect(box, 'members panel has no box').not.toBeNull();
  // With a single member the panel must be far shorter than the 900px viewport —
  // the old `top-16 bottom-3` box was ~820px tall regardless of content.
  expect(box!.height, 'panel should hug content, not fill the viewport').toBeLessThan(480);
});
