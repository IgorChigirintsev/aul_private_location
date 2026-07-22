# Aul Web (MIT)

The Aul dashboard — a React + TypeScript + Vite PWA with a live, end-to-end
encrypted family map (MapLibre GL + OpenFreeMap). Location pings are decrypted
**in the browser** with the circle key; the server only ever sees ciphertext.

## Develop

```sh
npm install
npm run dev        # http://localhost:5173 (proxies /v1 + WebSocket to the server)
```

Run the Go server alongside it. Because the server's WebSocket enforces an
Origin allow-list, start it with the dev origin:

```sh
cd ../server && PUBLIC_ORIGIN=http://localhost:5173 make run
```

## Test

```sh
npm test            # vitest: crypto cross-vectors (Go↔Dart↔JS) + realtime pipeline
npm run lint        # oxlint
npm run build       # tsc + vite + PWA

# Browser acceptance (needs a running server + Chromium):
npx playwright install chromium
npx playwright test                                    # against the Vite dev server
PW_BASE_URL=http://localhost:8080 npx playwright test  # against the Go-served build
```

## Ship

The Go binary serves this app via `embed.FS`:

```sh
cd ../server && make web && make run    # builds the bundle in, serves it on :8080
```

See [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) and
[../docs/THREAT_MODEL.md](../docs/THREAT_MODEL.md) (§7 — the web's weaker trust
model). Design tokens: [../docs/design-tokens.json](../docs/design-tokens.json).
