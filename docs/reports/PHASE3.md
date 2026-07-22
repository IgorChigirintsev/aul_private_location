# Phase 3 report — Web dashboard

**Status: complete.** The live E2EE family map works end‑to‑end in a real
browser — including the full production path (Go server serving the embedded
bundle with the strict CSP active). Acceptance criterion met and proven with an
automated browser test.

## Acceptance criterion

> "A watcher sees the reporter move in real time."

**Met, proven in a real browser (Playwright + Chromium).** The test registers a
watcher → creates a circle (K_c generated in‑browser, stored in IndexedDB) →
posts an **encrypted** ping → the WebSocket delivers it → the browser **decrypts
it client‑side with K_c** and a marker appears on the map → a second ping at a
new location **moves the marker**. It passes both against the Vite dev server and
against the **Go server serving the embedded build with CSP enforced** — the real
production configuration.

## What was built

React 18/19 + TypeScript + Vite, TanStack Query, Zustand, Tailwind v4, MapLibre
GL, libsodium‑wrappers, PWA.

- **E2EE in the browser** — `aulCrypto.ts` (libsodium): XChaCha20‑Poly1305 ping
  decryption, X25519 identity, sealed key envelopes, padding; safety‑code via Web
  Crypto SHA‑256. **Three‑way interop proven**: `vitest` verifies the JS
  reproduces every Go/Dart safety‑code vector and decrypts/re‑encrypts Go's
  XChaCha20 ciphertext byte‑identically (`/vectors/crypto-vectors.json`).
  Completes the "seal in Dart, open in JS and Go" requirement.
- **Live map** — MapLibre GL with OpenFreeMap tiles; member markers are DOM
  elements with a battery ring, accuracy halo, and a pulse on fresh updates, and
  interpolate to new positions over ~1 s (respecting `prefers-reduced-motion`).
- **Realtime** — a WebSocket client decrypts ping events into a Zustand positions
  store (newest‑capture wins, out‑of‑order safe); 30 s latest‑pings poll fallback.
- **Auth** — httpOnly‑cookie sessions (nothing sensitive in JS) with transparent
  refresh; register/sign‑in that provisions a web X25519 identity key.
- **Circles & invites** — create a circle (K_c on device, encrypted name), an
  **invite flow with a shareable link + QR** where K_c rides in the URL fragment
  (never sent to the server), and a **join page** that reads the fragment.
- **Dashboard** — full‑screen map, members panel (battery, "updated N min ago",
  precision), one‑tap **"Who can see me"**, precision precise/city/paused.
- **PWA** — manifest + service worker (app‑shell cache; API/WS explicitly never
  cached), theme‑colored, installable.
- **Served by the Go binary** via `embed.FS` (`make web`), strict CSP
  (`script-src 'self' 'wasm-unsafe-eval'`, tiles origin allow‑listed).

## Quality

- **6 unit tests** pass (`npm test`): crypto cross‑vectors + realtime decrypt
  pipeline (movement over time, wrong‑key rejection).
- **Playwright acceptance** passes (dev + Go‑embedded prod path).
- `oxlint` clean, `tsc` + `vite build` clean (PWA SW + manifest generated).
- Web CI job (lint → test → build) added to `.github/workflows/ci.yml`.

## Security review

An adversarial multi‑agent review (crypto/key handling + web appsec: XSS, CSP,
CSRF, WebSocket origin, secret storage) returned **zero confirmed findings**. The
reviewers verified: K_c and the private key never reach the server; K_c travels
only in the invite URL fragment; cookie auth keeps no secret in JS; the
`innerHTML` in the marker builder is not injectable (its only interpolation is a
single character derived from a server UUID); the CSP is not over‑permissive.

Two findings were **dismissed** on verification — both about map tiles — but they
surfaced a real (non‑security) UX gap: the deploy shipped `TILES_ORIGIN` empty,
so the strict CSP blocked OpenFreeMap and the **basemap rendered blank by
default**. Fixed by defaulting `TILES_ORIGIN=https://tiles.openfreemap.org` (the
chosen default provider per D‑0018), with docs pointing self‑hosters to their own
tiles for zero third‑party requests.

## Known debts (see `docs/TODO.md`)

Bespoke warm MapLibre style (positron used now); history timeline + place editor
+ SOS center + account‑security page (Phase 5/7); marketing landing page (Phase
6); Web Push (VAPID) wiring; code‑splitting the 1.8 MB bundle (MapLibre +
libsodium); device→member marker labelling (server doesn't expose the mapping).

## Try it

```sh
cd server && make web && make run      # Go serves the real dashboard on :8080
# or dev with hot reload:
cd web && npm run dev                   # :5173, proxies to the server (run it with
                                        # PUBLIC_ORIGIN=http://localhost:5173)
```

## Next: Phase 4 — E2EE hardening across the stack
Key envelopes + rotation, safety‑code verification UI, places/geofences
encryption — building on the crypto foundations already cross‑tested here.
