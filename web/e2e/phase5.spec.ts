import { expect, test } from '@playwright/test';

import { initCrypto } from '../src/crypto/aulCrypto';

// Phase-5 acceptance: encrypted places (with a geofence radius) and the SOS
// centre, driven entirely through the real UI against the real Go server. The
// place name + coordinates and the SOS payload are sealed in-browser with K_c;
// the server only ever relays ciphertext.

async function signInFreshCircle(page: import('@playwright/test').Page) {
  const email = `p5+${Date.now()}@example.com`;
  // "/" serves the public marketing landing to signed-out visitors (D-0041);
  // the auth form lives at /login.
  await page.goto('/login');
  await page.getByRole('button', { name: 'Create account' }).first().click();
  await page.getByPlaceholder('Email').fill(email);
  await page.getByPlaceholder('Password').fill('phase5-strong-pass');
  await page.getByRole('button', { name: 'Create account' }).last().click();
  page.once('dialog', (d) => d.accept('Family'));
  await page.getByRole('button', { name: 'Create a circle' }).click();
  await expect(page.getByTestId('map')).toHaveClass(/maplibregl-map/);
}

test('create an encrypted place with a geofence radius', async ({ page }) => {
  await initCrypto();
  await signInFreshCircle(page);

  await page.getByTitle('Places').click();
  await page.getByRole('button', { name: 'Add a place' }).click();
  await page.getByPlaceholder('Place name (e.g. Home)').fill('Home');

  // Click the map to set the centre (away from the side panels).
  await page.getByTestId('map').click({ position: { x: 520, y: 360 } });

  await page.getByRole('button', { name: 'Add place' }).click();

  // The place appears as a labelled pin on the map and in the list. `toContainText`,
  // not `toHaveText`: the pill also carries the owner's nickname on a second line
  // (from the place's created_by — server metadata; the NAME stays E2EE).
  await expect(page.locator('.aul-place')).toContainText('Home', { timeout: 10_000 });
  await expect(page.locator('li', { hasText: 'Home' }).first()).toBeVisible();
});

test('raise an SOS, see the banner, then resolve it', async ({ page }) => {
  await initCrypto();
  await signInFreshCircle(page);

  page.once('dialog', (d) => d.accept('need help now'));
  await page.getByTitle('Raise SOS').click();

  // The red SOS banner appears with the decrypted message.
  await expect(page.getByText('SOS · someone needs help')).toBeVisible({ timeout: 10_000 });
  await expect(page.getByText('need help now')).toBeVisible();

  // Resolving clears it.
  await page.getByRole('button', { name: 'Resolve' }).click();
  await expect(page.getByText('SOS · someone needs help')).toHaveCount(0, { timeout: 10_000 });
});
