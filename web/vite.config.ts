import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import { VitePWA } from 'vite-plugin-pwa';

// The dashboard talks to the Aul server. In dev, /v1 and /healthz are proxied to
// it (default :8080) so the app runs same-origin. In prod the server serves the
// built bundle via embed.FS, so requests are already same-origin.
const SERVER = process.env.AUL_SERVER ?? 'http://127.0.0.1:8080';

/// The service worker is registered as a CLASSIC script, and `import.meta` is a
/// hard SyntaxError there: the browser refuses the whole file with "ServiceWorker
/// script evaluation failed" — no push, no offline, no anything. libsodium's ESM
/// build reads `import.meta.url` to find its own directory (it never uses it: the
/// wasm binary is inlined as base64), so rewrite it to the worker's own URL —
/// `new URL('.', self.location.href)` yields the same directory. Applied to the
/// SW bundle ONLY (VitePWA's injectManifest.buildPlugins.vite), never the app.
///
/// Runs on the final chunk rather than per-module so that anything the bundler
/// itself emits is covered too. Keep this until libsodium ships a worker-safe
/// build — it is load-bearing, and its absence fails only at runtime.
const swNoImportMeta = (): Plugin => ({
  name: 'aul:sw-no-import-meta',
  apply: 'build',
  renderChunk(code) {
    if (!code.includes('import.meta.url')) return null;
    return { code: code.replaceAll('import.meta.url', 'self.location.href'), map: null };
  },
});

export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    VitePWA({
      // injectManifest (not generateSW): the service worker is OUR source
      // (src/sw.ts) so it can carry the Web Push handler — a background push
      // must open the sealed payload with libsodium + the circle keys from
      // IndexedDB, which no generated SW can do. Workbox only injects the
      // precache manifest into it. The precache/autoUpdate behaviour that used
      // to be configured here (skipWaiting + clientsClaim, cleanupOutdatedCaches
      // and the NetworkFirst app-shell route) is hand-written in src/sw.ts —
      // keep the two in sync.
      strategies: 'injectManifest',
      srcDir: 'src',
      filename: 'sw.ts',
      registerType: 'autoUpdate',
      includeAssets: ['favicon.svg', 'icon.svg'],
      manifest: {
        name: 'Aul',
        short_name: 'Aul',
        description: 'Private family location, end-to-end encrypted.',
        theme_color: '#155E4A',
        background_color: '#FAF7F2',
        display: 'standalone',
        start_url: '/',
        icons: [
          { src: '/icon.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any' },
          { src: '/icon.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'maskable' },
        ],
      },
      injectManifest: {
        // Precache the hashed static assets (safe to cache forever) — but NOT
        // the HTML document. The document carries response *headers* (notably
        // the CSP that allow-lists the map-tiles origin); precaching it would
        // pin a stale CSP in the SW cache and silently break the map when the
        // server's CSP changes. Instead the app shell is served NetworkFirst
        // (see src/sw.ts): fresh headers when online, cached copy only as an
        // offline fallback.
        globPatterns: ['**/*.{js,css,svg,png,woff2}'],
        // The main app chunk sits within a whisker of Workbox's 2 MiB default
        // ceiling (maplibre + libsodium). Over it, Workbox drops the file from
        // the precache with a warning and offline quietly stops working — raise
        // the ceiling instead of finding out from a bug report.
        maximumFileSizeToCacheInBytes: 4 * 1024 * 1024,
        buildPlugins: { vite: [swNoImportMeta()] },
      },
    }),
  ],
  server: {
    port: 5173,
    proxy: {
      '/v1': { target: SERVER, changeOrigin: true, ws: true },
      '/healthz': { target: SERVER, changeOrigin: true },
    },
  },
  build: { sourcemap: false },
});
