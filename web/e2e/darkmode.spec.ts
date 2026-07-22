import { expect, test } from '@playwright/test';

// Dark mode is app-wide now (not only the marketing pages): overriding the
// `--color-*` tokens under `prefers-color-scheme: dark` re-tints every semantic
// utility. Guard that the app actually flips with the OS preference.
test('the whole app follows the OS dark preference', async ({ page }) => {
  await page.emulateMedia({ colorScheme: 'dark' });
  await page.goto('/login');
  const bg = await page.evaluate(
    () => getComputedStyle(document.body).backgroundColor,
  );
  // --color-bg dark = #131211 = rgb(19, 18, 17).
  expect(bg).toBe('rgb(19, 18, 17)');

  await page.emulateMedia({ colorScheme: 'light' });
  const bgLight = await page.evaluate(
    () => getComputedStyle(document.body).backgroundColor,
  );
  // --color-bg light = #faf7f2 = rgb(250, 247, 242).
  expect(bgLight).toBe('rgb(250, 247, 242)');
});

// The Settings switcher stamps <html data-theme>; "system" removes it. Pin that
// an explicit choice BEATS the OS preference in both directions.
test('an explicit theme choice overrides the OS preference', async ({ page }) => {
  const bg = () =>
    page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  const setAttr = (v: string | null) =>
    page.evaluate((val) => {
      if (val === null) document.documentElement.removeAttribute('data-theme');
      else document.documentElement.setAttribute('data-theme', val);
    }, v);

  await page.emulateMedia({ colorScheme: 'dark' });
  await page.goto('/login');

  // Forced light wins over an OS that says dark.
  await setAttr('light');
  expect(await bg()).toBe('rgb(250, 247, 242)');

  // Forced dark wins over an OS that says light.
  await page.emulateMedia({ colorScheme: 'light' });
  await setAttr('dark');
  expect(await bg()).toBe('rgb(19, 18, 17)');

  // Back to "system": the OS (light) decides again.
  await setAttr(null);
  expect(await bg()).toBe('rgb(250, 247, 242)');
});
