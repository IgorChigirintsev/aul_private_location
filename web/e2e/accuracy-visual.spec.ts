import { expect, test } from '@playwright/test';

// Does the accuracy circle actually get drawn — at the fix's true ground radius,
// beneath everything else? A unit test over a pure helper cannot say, and neither
// can a screenshot: the circle is a translucent haze over a basemap, and at some
// zooms it is genuinely ambiguous to the eye. So ask the map what it drew.

interface MapHandle {
  getStyle: () => { layers: { id: string }[] };
  getSource: (id: string) => { _data?: unknown } | undefined;
}

declare global {
  interface Window {
    __aulMap?: MapHandle;
  }
}

async function signInWithFix(
  page: import('@playwright/test').Page,
  context: import('@playwright/test').BrowserContext,
  accuracy: number,
): Promise<void> {
  await context.grantPermissions(['geolocation']);
  await context.setGeolocation({ latitude: 43.2389, longitude: 76.8897, accuracy });

  const email = `vis${accuracy}+${Date.now()}@example.com`;
  await page.goto('/login');
  await page.getByRole('button', { name: 'Create account' }).first().click();
  await page.getByPlaceholder('Email').fill(email);
  await page.getByPlaceholder('Password').fill('vis-strong-pass');
  await page.getByRole('button', { name: 'Create account' }).last().click();
  await page.getByRole('button', { name: 'Create a circle' }).click();

  await expect(page.getByTestId('map')).toHaveClass(/maplibregl-map/);
  await expect(page.locator('.aul-marker')).toHaveCount(1);
}

/// The rings MapLibre is actually holding for the accuracy source.
///
/// Reaches into `_data` because there is no public read-back of a GeoJSON
/// source's contents. MapLibre wraps it as `{ geojson: <FeatureCollection> }`;
/// the unwrapped shape is accepted too, so a version bump degrades into a plain
/// test failure rather than a silent "no circles found" — which is exactly the
/// false negative this probe chased for half an hour.
async function drawnRadiiM(page: import('@playwright/test').Page): Promise<number[]> {
  return page.evaluate(() => {
    const src = window.__aulMap?.getSource('accuracy') as { _data?: unknown } | undefined;
    const raw = src?._data as
      | { geojson?: { features?: unknown }; features?: unknown }
      | undefined;
    const data = (raw?.geojson ?? raw) as
      | { features: { geometry: { coordinates: number[][][] } }[] }
      | undefined;
    if (!data?.features) return [];
    return data.features.map((f) => {
      const lats = f.geometry.coordinates[0].map((c) => c[1]);
      return ((Math.max(...lats) - Math.min(...lats)) / 2) * 111_320;
    });
  });
}

test('a vague fix is drawn at its true ground radius, under everything else', async ({
  page,
  context,
}) => {
  await signInWithFix(page, context, 350);

  // The marker is a DOM overlay and can beat the style's `load` event, which is
  // where the sources and layers are added — so poll rather than assume.
  const layerIds = (): Promise<string[]> =>
    page.evaluate(() => {
      try {
        // getStyle() throws outright until the style has loaded.
        return window.__aulMap?.getStyle().layers.map((l) => l.id) ?? [];
      } catch {
        return [];
      }
    });
  await expect
    .poll(layerIds, { message: 'the accuracy layers never appeared', timeout: 20_000 })
    .toContain('accuracy-fill');

  const layers = await layerIds();
  expect(layers).toContain('accuracy-line');
  // Haze is context, not subject: it must sit under the geofences and the markers.
  expect(layers.indexOf('accuracy-fill')).toBeLessThan(layers.indexOf('geofence-fill'));

  await expect
    .poll(() => drawnRadiiM(page), {
      message: 'no accuracy circle was ever drawn for a ±350 m fix',
      timeout: 20_000,
    })
    .not.toHaveLength(0);

  const [radius] = await drawnRadiiM(page);
  // The circle must BE the measurement — not a decoration of a fixed size.
  expect(radius, `drew a ${Math.round(radius)} m circle for a 350 m fix`).toBeGreaterThan(300);
  expect(radius).toBeLessThan(400);

  await page.screenshot({ path: 'test-results/accuracy-350m.png' });
});

test('a sharp fix draws no circle at all', async ({ page, context }) => {
  await signInWithFix(page, context, 5);
  // Give it the same beat the vague case needed to post, decrypt and render.
  await page.waitForTimeout(6_000);

  // A 5 m ring is invisible under a 44 px marker; drawing it would only imply we
  // measured an area we did not. Nothing is the honest answer.
  expect(await drawnRadiiM(page)).toHaveLength(0);
  await page.screenshot({ path: 'test-results/accuracy-5m.png' });
});
