import { expect, test, type Page } from '@playwright/test';

import { initCrypto, randomCircleKey, toBase64Url } from '../src/crypto/aulCrypto';
import { sealShareFix } from '../src/data/shareCodec';

// The public live-share viewer, driven in a real browser.
//
// GET /v1/share/:id is stubbed on purpose, so this spec is hermetic (no Go
// server, no account) and can assert the states a real server makes awkward to
// reach on demand: 403 bound-elsewhere, 410 expired, a wrong key in the
// fragment. The positions are sealed here with the SAME codec the sharer's
// reporter uses, so the decrypt path is the real one.
//
// This is the viewer coverage the vitest suite cannot give: the page is a
// maplibre canvas plus focus/visibility behaviour, neither of which survives the
// node/jsdom environment (see test/share.test.ts).

const ID = '2f1c8a4e-0000-4000-8000-000000000000';

async function stub(page: Page, status: number, body: unknown) {
  await page.route('**/v1/share/**', (route) =>
    route.fulfill({
      status,
      contentType: 'application/json',
      body: JSON.stringify(body),
    }),
  );
}

const future = () => new Date(Date.now() + 15 * 60_000).toISOString();

test('viewer decrypts K_share from the fragment and shows one marker', async ({ page }) => {
  await initCrypto();
  const kShare = randomCircleKey();
  const position = sealShareFix({ lat: 43.238949, lng: 76.889709, acc: 10, ts: Date.now() }, kShare);
  await stub(page, 200, { expires_at: future(), position });

  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(e.message));

  await page.goto(`/s/${ID}#${toBase64Url(kShare)}`);

  await expect(page.getByTestId('share-map')).toBeVisible();
  await expect(page.locator('.aul-marker')).toHaveCount(1);
  await expect(page.getByText('Live location')).toBeVisible();
  await expect(page.getByText(/Ends in \d\d:\d\d/)).toBeVisible();
  await expect(page.getByText('The map hides when this tab loses focus.').first()).toBeVisible();
  expect(errors).toEqual([]);
});

test('blur blacks the page out; focus restores it', async ({ page }) => {
  await initCrypto();
  const kShare = randomCircleKey();
  const position = sealShareFix({ lat: 43.2, lng: 76.8, ts: Date.now() }, kShare);
  await stub(page, 200, { expires_at: future(), position });
  await page.goto(`/s/${ID}#${toBase64Url(kShare)}`);
  await expect(page.getByTestId('share-map')).toBeVisible();

  const overlay = page.locator('div[aria-hidden].bg-black');
  await expect(overlay).toHaveCount(0);
  await page.evaluate(() => window.dispatchEvent(new Event('blur')));
  await expect(overlay).toBeVisible();
  await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await expect(overlay).toHaveCount(0);
});

test('waiting for the first position', async ({ page }) => {
  await initCrypto();
  await stub(page, 200, { expires_at: future(), position: null });
  await page.goto(`/s/${ID}#${toBase64Url(randomCircleKey())}`);
  await expect(page.getByText('Waiting for the first position')).toBeVisible();
  await expect(page.getByTestId('share-map')).toHaveCount(0);
});

test('403 — already bound to another device', async ({ page }) => {
  await initCrypto();
  await stub(page, 403, { error: { code: 'forbidden', message: 'bound elsewhere' } });
  await page.goto(`/s/${ID}#${toBase64Url(randomCircleKey())}`);
  await expect(page.getByText('This link is open somewhere else')).toBeVisible();
  await expect(page.getByTestId('share-map')).toHaveCount(0);
});

test('410 — expired/revoked shows the final screen and stops polling', async ({ page }) => {
  await initCrypto();
  let calls = 0;
  await page.route('**/v1/share/**', (route) => {
    calls += 1;
    return route.fulfill({
      status: 410,
      contentType: 'application/json',
      body: JSON.stringify({ error: { code: 'gone', message: 'expired' } }),
    });
  });
  await page.goto(`/s/${ID}#${toBase64Url(randomCircleKey())}`);
  await expect(page.getByText('This link has expired')).toBeVisible();
  await expect(page.getByTestId('share-map')).toHaveCount(0);
  const after = calls;
  await page.waitForTimeout(12_000); // longer than the 10 s poll
  expect(calls).toBe(after); // polling really stopped
});

test('404 — unknown link', async ({ page }) => {
  await initCrypto();
  await stub(page, 404, { error: { code: 'not_found', message: 'nope' } });
  await page.goto(`/s/${ID}#${toBase64Url(randomCircleKey())}`);
  await expect(page.getByText("This link doesn't exist")).toBeVisible();
});

test('missing fragment — clear error, no map', async ({ page }) => {
  await initCrypto();
  await stub(page, 200, { expires_at: future(), position: null });
  await page.goto(`/s/${ID}`);
  await expect(page.getByText('This link is missing its key')).toBeVisible();
  await expect(page.getByTestId('share-map')).toHaveCount(0);
});

test('wrong key in the fragment — no location leaks', async ({ page }) => {
  await initCrypto();
  const position = sealShareFix({ lat: 43.2, lng: 76.8, ts: Date.now() }, randomCircleKey());
  await stub(page, 200, { expires_at: future(), position });
  await page.goto(`/s/${ID}#${toBase64Url(randomCircleKey())}`); // a DIFFERENT key
  await expect(page.getByText("This link's key doesn't fit")).toBeVisible();
  await expect(page.getByTestId('share-map')).toHaveCount(0);
});

test('the deadline passing ends the share client-side, with no server help', async ({ page }) => {
  await initCrypto();
  const kShare = randomCircleKey();
  const position = sealShareFix({ lat: 43.2, lng: 76.8, ts: Date.now() }, kShare);
  // Already 3 s from the end; the server keeps happily serving the position.
  await stub(page, 200, { expires_at: new Date(Date.now() + 3_000).toISOString(), position });
  await page.goto(`/s/${ID}#${toBase64Url(kShare)}`);
  await expect(page.getByTestId('share-map')).toBeVisible();
  await expect(page.getByText('This link has expired')).toBeVisible({ timeout: 10_000 });
  await expect(page.getByTestId('share-map')).toHaveCount(0);
});
