import { defineConfig } from '@playwright/test';

// Two modes:
//  - default: Vite dev on :5173 (proxies /v1 + WS to the Go server on :8080).
//  - PW_BASE_URL set: run against a server that already serves the built app
//    (e.g. the Go server with the embedded bundle on :8080) — validates the
//    production same-origin + CSP path.
const external = process.env.PW_BASE_URL;

export default defineConfig({
  testDir: './e2e',
  timeout: 60_000,
  expect: { timeout: 15_000 },
  fullyParallel: false,
  workers: 1,
  use: {
    baseURL: external ?? 'http://localhost:5173',
    headless: true,
    launchOptions: {
      // Software WebGL so MapLibre GL renders in headless CI.
      args: [
        '--enable-unsafe-swiftshader',
        '--use-gl=angle',
        '--use-angle=swiftshader',
        '--ignore-gpu-blocklist',
      ],
    },
  },
  webServer: external
    ? undefined
    : {
        command: 'npm run dev',
        url: 'http://localhost:5173',
        timeout: 60_000,
        reuseExistingServer: true,
      },
});
