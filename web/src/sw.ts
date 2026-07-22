/// The Aul service worker (Workbox `injectManifest` — vite.config.ts points at
/// this file). Two jobs:
///
///  1. Offline/caching, equivalent to what the old generateSW config produced:
///     skipWaiting + clientsClaim (registerType: 'autoUpdate'), precache the
///     hashed assets, drop outdated caches, and serve navigations NetworkFirst
///     so the document's CSP header is always fresh online.
///  2. BACKGROUND WEB PUSH. The server relays an opaque blob it cannot read; we
///     open it here with the circle keys from IndexedDB and libsodium, so the
///     notification text ("Ann arrived at Home") is produced on this device and
///     nowhere else. Anything we cannot open shows a deliberately contentless
///     fallback — never a hint of what the push was about.
///
/// Note this file is bundled on its own (its own Vite build): it must not import
/// React, i18next, or anything else that assumes a DOM.
/// <reference lib="webworker" />
import { clientsClaim } from 'workbox-core';
import { ExpirationPlugin } from 'workbox-expiration';
import { cleanupOutdatedCaches, precacheAndRoute } from 'workbox-precaching';
import { registerRoute } from 'workbox-routing';
import { NetworkFirst } from 'workbox-strategies';

import { initCrypto } from './crypto/aulCrypto';
import { keystore } from './data/keystore';
import { openNotify, type NotifyPayload } from './data/notifyCodec';
import en from './i18n/locales/en.json';
import ru from './i18n/locales/ru.json';

// `self` is module-scoped here, so this shadows (rather than clashes with) the
// ambient WorkerGlobalScope declaration.
declare let self: ServiceWorkerGlobalScope & {
  __WB_MANIFEST: Parameters<typeof precacheAndRoute>[0];
};

/* -------------------------------------------------------------------------- */
/* 1. Caching (mirrors the previous generateSW behaviour — keep in sync)       */
/* -------------------------------------------------------------------------- */

self.skipWaiting();
clientsClaim();

// The build injects the precache manifest here (hashed JS/CSS/SVG/PNG only —
// never the HTML document, whose CSP header must not be pinned in a cache).
precacheAndRoute(self.__WB_MANIFEST);
cleanupOutdatedCaches();

/// Never cache API/WS traffic: it carries live, private data.
const API_PATH = /^\/(v1\/|healthz|metrics)/;

// Navigations: network first (fresh headers/CSP), cache only as offline fallback.
registerRoute(
  ({ request, url }) => request.mode === 'navigate' && !API_PATH.test(url.pathname),
  new NetworkFirst({
    cacheName: 'aul-app-shell',
    networkTimeoutSeconds: 3,
    plugins: [new ExpirationPlugin({ maxEntries: 8 })],
  }),
);

/* -------------------------------------------------------------------------- */
/* 2. Background push                                                          */
/* -------------------------------------------------------------------------- */

/// The brand name — deliberately untranslated, and deliberately the ONLY thing
/// an undecryptable push can put on the lock screen besides the generic body.
const TITLE = 'Aul';
const ICON = '/icon.svg';

const CATALOGS = { en, ru };
type Lang = keyof typeof CATALOGS;

/// The language for a background notification. A service worker has no
/// localStorage, so the app mirrors its resolved language into IndexedDB
/// (keystore.saveUiLang); fall back to the browser's own language, then English.
async function lang(): Promise<Lang> {
  let stored: string | undefined;
  try {
    stored = await keystore.loadUiLang();
  } catch {
    /* no DB yet — fall through to the browser language */
  }
  const raw = (stored ?? self.navigator?.language ?? 'en').toLowerCase();
  return raw.startsWith('ru') ? 'ru' : 'en';
}

/// Minimal {{placeholder}} interpolation — the i18next runtime is a DOM-side
/// dependency we will not drag into the worker for three strings.
function fill(template: string, vars: Record<string, string>): string {
  return template.replace(/\{\{(\w+)\}\}/g, (_, k: string) => vars[k] ?? '');
}

/// Opens a relayed push payload with every circle key this device holds.
/// Returns null on anything unexpected — the caller then shows the generic
/// notification. Never throws, never logs the payload.
async function openPush(b64: string): Promise<NotifyPayload | null> {
  try {
    await initCrypto(); // libsodium's wasm — the SW initialises its own copy
    const keys = await keystore.loadAllCircleKeys();
    if (keys.length === 0) return null; // signed out, or keys never synced here
    return openNotify(b64, keys);
  } catch {
    return null;
  }
}

async function onPush(raw: string | null): Promise<void> {
  const payload = raw ? await openPush(raw) : null;
  const strings = CATALOGS[await lang()].push;

  // No key opened it: another circle, a signed-out browser, or a payload not
  // meant for us. Say nothing about it — but still show something, because
  // userVisibleOnly:true promises the browser a visible notification.
  if (!payload) {
    await self.registration.showNotification(TITLE, {
      body: strings.generic,
      icon: ICON,
      badge: ICON,
      tag: 'aul-generic',
      data: { url: '/' },
    });
    return;
  }

  // `timestamp` (when the event happened, vs when the push landed) is widely
  // supported but missing from TypeScript's NotificationOptions.
  const options: NotificationOptions & { timestamp?: number } = {
    body: fill(payload.t === 'arrival' ? strings.arrived : strings.left, {
      who: payload.who,
      place: payload.place,
    }),
    icon: ICON,
    badge: ICON,
    timestamp: payload.ts,
    // One notification per person+place+kind: a re-arrival replaces the stale
    // line instead of stacking, while an arrival is not erased by a departure.
    tag: `aul:${payload.t}:${payload.who}:${payload.place}`,
    data: { url: '/' },
  };
  await self.registration.showNotification(TITLE, options);
}

self.addEventListener('push', (event: PushEvent) => {
  // Read the payload synchronously: `event.data` is not guaranteed to survive
  // the await inside the handler.
  let raw: string | null = null;
  try {
    raw = event.data?.text() ?? null;
  } catch {
    raw = null;
  }
  event.waitUntil(onPush(raw));
});

/// Focus an existing dashboard tab if one is open, otherwise open one.
self.addEventListener('notificationclick', (event: NotificationEvent) => {
  event.notification.close();
  const url = new URL(
    (event.notification.data as { url?: string } | undefined)?.url ?? '/',
    self.location.origin,
  ).href;
  event.waitUntil(
    (async () => {
      const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      const existing = windows.find((c) => new URL(c.url).origin === self.location.origin);
      if (existing) {
        await existing.focus();
        return;
      }
      await self.clients.openWindow(url);
    })(),
  );
});
