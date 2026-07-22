import { expect, test } from '@playwright/test';

// "The map shows me where I am not."
//
// The owner reported his PC marker sitting a couple of blocks away. A desktop has
// no GPS — the browser locates it from Wi-Fi — but the bugs underneath were ours,
// and they are invisible to a unit test because they live in what the app asks
// the PLATFORM for. So this drives a real Chromium with a real permission grant
// and records the actual option bags handed to the real geolocation API.
//
// The regression under test: the immediate one-shot fix omitted
// `enableHighAccuracy`, defaulting it to false. `watchPosition` only fires on
// MOVEMENT, so on a device sitting on a desk that coarse first answer was not
// merely first — it was the only fix of the entire session, and the marker could
// never refine itself no matter how long you waited.

interface GeoCall {
  kind: 'watch' | 'oneShot';
  enableHighAccuracy: boolean | undefined;
  maximumAge: number | undefined;
}

declare global {
  interface Window {
    __geoCalls: GeoCall[];
  }
}

test('a stationary browser asks for its best accuracy, and keeps asking', async ({
  page,
  context,
}) => {
  await context.grantPermissions(['geolocation']);
  // Almaty, with a deliberately vague ±350 m — a plausible Wi-Fi fix, and the
  // shape of the owner's complaint.
  await context.setGeolocation({ latitude: 43.2389, longitude: 76.8897, accuracy: 350 });

  // Record every request the app makes of the platform, before any app code runs.
  await page.addInitScript(() => {
    window.__geoCalls = [];
    const geo = navigator.geolocation;
    const realWatch = geo.watchPosition.bind(geo);
    const realOnce = geo.getCurrentPosition.bind(geo);
    geo.watchPosition = (ok, err, opts) => {
      window.__geoCalls.push({
        kind: 'watch',
        enableHighAccuracy: opts?.enableHighAccuracy,
        maximumAge: opts?.maximumAge,
      });
      return realWatch(ok, err, opts);
    };
    geo.getCurrentPosition = (ok, err, opts) => {
      window.__geoCalls.push({
        kind: 'oneShot',
        enableHighAccuracy: opts?.enableHighAccuracy,
        maximumAge: opts?.maximumAge,
      });
      return realOnce(ok, err, opts);
    };
  });

  const email = `geo+${Date.now()}@example.com`;
  await page.goto('/login');
  await page.getByRole('button', { name: 'Create account' }).first().click();
  await page.getByPlaceholder('Email').fill(email);
  await page.getByPlaceholder('Password').fill('geo-strong-pass');
  await page.getByRole('button', { name: 'Create account' }).last().click();

  await page.getByRole('button', { name: 'Create a circle' }).click();
  await expect(page.getByTestId('map')).toHaveClass(/maplibregl-map/);

  // A fresh circle defaults to precise, so the reporter must ask for the sharpest
  // fix the platform can give — on BOTH calls.
  await expect
    .poll(async () => (await page.evaluate(() => window.__geoCalls)).length, {
      message: 'the reporter never asked the platform for a position',
      timeout: 20_000,
    })
    .toBeGreaterThan(0);

  const calls = await page.evaluate(() => window.__geoCalls);
  const oneShots = calls.filter((c) => c.kind === 'oneShot');
  const watches = calls.filter((c) => c.kind === 'watch');

  expect(watches.length, 'the shared watch should be opened once').toBeGreaterThan(0);
  expect(watches[0].enableHighAccuracy).toBe(true);

  // The bug: this used to be `undefined` (⇒ false) while the watch beside it asked
  // for true. On a desk, this call's answer is the marker, forever.
  expect(oneShots.length, 'a stationary device needs an immediate one-shot fix').toBeGreaterThan(0);
  expect(
    oneShots[0].enableHighAccuracy,
    'the first fix — the only one a motionless PC ever gets — was asked at low accuracy',
  ).toBe(true);

  // The marker lands where the platform said we are, ±350 m and all.
  await expect(page.locator('.aul-marker')).toHaveCount(1);
});
