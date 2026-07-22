import { expect, test } from '@playwright/test';

// Does the encryption actually hold?
//
// Not "do the crypto unit tests pass" — those test the primitives. This asks the
// only question a user cares about: when a real browser reports a real position
// to the real server, does the coordinate, or the key that opens it, ever leave
// the machine?
//
// Method: pin an unmistakable coordinate, capture every byte the page sends — URL,
// headers, body — then read the vault (IndexedDB `aul`/`keys`) and search all that
// captured traffic for each secret by name.
//
// Two properties make this proof honest rather than decorative:
//
//   1. The marker must appear. Otherwise we would only be proving that a broken
//      app leaks nothing, which is trivially true of an app that does nothing.
//   2. The device's PUBLIC key must be found IN the traffic. It is supposed to go
//      to the server — that is what a public key is for (THREAT_MODEL §3: the
//      server relays sealed boxes to it). Asserting it is present proves the
//      search itself works, so "K_c was not found" cannot be a false negative
//      from a broken probe. A first draft of this test flagged that public key as
//      a leak; the fix is to know which secrets are secret.

const LAT = 12.345678;
const LNG = 98.765432;

interface Vault {
  circleKeys: string[];
  publicKey: string | null;
  privateKey: string | null;
}

test('no coordinate and no secret key ever leave the browser', async ({ page, context }) => {
  await context.grantPermissions(['geolocation']);
  await context.setGeolocation({ latitude: LAT, longitude: LNG, accuracy: 12 });

  const sent: { url: string; method: string; body: string; headers: string }[] = [];
  page.on('request', (req) => {
    sent.push({
      url: req.url(),
      method: req.method(),
      body: req.postData() ?? '',
      headers: JSON.stringify(req.headers()),
    });
  });

  const email = `e2ee+${Date.now()}@example.com`;
  await page.goto('/login');
  await page.getByRole('button', { name: 'Create account' }).first().click();
  await page.getByPlaceholder('Email').fill(email);
  await page.getByPlaceholder('Password').fill('e2ee-strong-pass');
  await page.getByRole('button', { name: 'Create account' }).last().click();
  page.once('dialog', (d) => d.accept('Family'));
  await page.getByRole('button', { name: 'Create a circle' }).click();

  // The app must actually work: a marker means a ping was sealed, posted, served
  // back, and decrypted into these very coordinates.
  await expect(page.getByTestId('map')).toHaveClass(/maplibregl-map/);
  await expect(page.locator('.aul-marker')).toHaveCount(1);
  await expect
    .poll(() => sent.filter((s) => s.url.includes('/v1/pings')).length, { timeout: 20_000 })
    .toBeGreaterThan(0);

  // The vault, read by the store's own key names — not by "anything 32 bytes long".
  const vault: Vault = await page.evaluate(async () => {
    const b64 = (v: unknown): string | null => {
      if (!(v instanceof Uint8Array)) return null;
      return btoa(String.fromCharCode(...v));
    };
    const db = await new Promise<IDBDatabase>((res, rej) => {
      const r = indexedDB.open('aul');
      r.onsuccess = () => res(r.result);
      r.onerror = () => rej(r.error);
    });
    const tx = db.transaction('keys', 'readonly');
    const store = tx.objectStore('keys');
    const names = await new Promise<IDBValidKey[]>((res) => {
      const r = store.getAllKeys();
      r.onsuccess = () => res(r.result);
    });
    const values = await new Promise<unknown[]>((res) => {
      const r = store.getAll();
      r.onsuccess = () => res(r.result as unknown[]);
    });
    const out: Vault = { circleKeys: [], publicKey: null, privateKey: null };
    names.forEach((name, i) => {
      const v = values[i];
      if (String(name).startsWith('circle:')) {
        // A ring of keys — rotation keeps the old ones to read old ciphertext.
        for (const k of (v as Uint8Array[]) ?? []) {
          const s = b64(k);
          if (s) out.circleKeys.push(s);
        }
      } else if (String(name) === 'identity') {
        const id = v as { publicKey?: Uint8Array; privateKey?: Uint8Array };
        out.publicKey = b64(id.publicKey);
        out.privateKey = b64(id.privateKey);
      }
    });
    db.close();
    return out;
  });

  expect(vault.circleKeys.length, 'no circle key in the vault — the probe is broken').toBeGreaterThan(0);
  expect(vault.privateKey, 'no identity key in the vault — the probe is broken').toBeTruthy();

  const haystack = sent.map((s) => `${s.url}\n${s.headers}\n${s.body}`).join('\n');
  const seen = (needle: string): boolean => {
    if (haystack.includes(needle)) return true;
    // An invite carries K_c url-safely; check that spelling too.
    return haystack.includes(needle.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''));
  };

  // The control: this one is SUPPOSED to be out there. If it is not, the search
  // is broken and every "not found" below would be worthless.
  expect(
    seen(vault.publicKey!),
    'the device public key was NOT in the captured traffic — the search is broken, so this test proves nothing',
  ).toBe(true);

  // The actual claims.
  expect(seen(vault.privateKey!), 'THE DEVICE PRIVATE KEY LEFT THE BROWSER').toBe(false);
  for (const k of vault.circleKeys) {
    expect(seen(k), 'THE CIRCLE KEY LEFT THE BROWSER').toBe(false);
  }

  // The coordinate, in the shapes JSON would render it.
  for (const needle of [String(LAT), String(LNG), LAT.toFixed(4), LNG.toFixed(4)]) {
    const leak = sent.find((s) => `${s.url}${s.body}`.includes(needle));
    expect(
      leak,
      `PLAINTEXT COORDINATE "${needle}" left the browser: ${leak?.method} ${leak?.url}`,
    ).toBeUndefined();
  }

  // The ping we did send must be opaque: nonce + ciphertext and nothing else.
  const pings = sent.filter((s) => s.url.includes('/v1/pings'));
  const body = JSON.parse(pings[0].body) as {
    pings: { nonce: string; ciphertext: string; lat?: unknown; lng?: unknown }[];
  };
  const ping = body.pings[0];
  expect(ping.nonce).toBeTruthy();
  expect(ping.ciphertext).toBeTruthy();
  expect(ping.lat, 'a ping must not carry a coordinate field at all').toBeUndefined();
  expect(ping.lng).toBeUndefined();
  expect(
    Buffer.from(ping.ciphertext, 'base64').toString('latin1').includes(String(LAT)),
    'the "ciphertext" contains the plaintext',
  ).toBe(false);

  console.log(
    `E2EE PROOF: ${sent.length} requests captured, ${pings.length} ping(s) posted.\n` +
      `  circle keys in vault: ${vault.circleKeys.length} — none found in traffic\n` +
      `  identity private key — not found in traffic\n` +
      `  identity public key — found (as designed: it is how the server addresses sealed boxes to us)\n` +
      `  ciphertext sample: ${ping.ciphertext.slice(0, 44)}…`,
  );
});
