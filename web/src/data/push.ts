import { api } from './api';

/// Web Push (VAPID) subscription plumbing for the dashboard.
///
/// What the server learns from this: the browser's push endpoint URL and the two
/// subscription keys the Web Push protocol needs to encrypt a message *to the
/// browser*. It never learns what is inside a notification — the payload we hand
/// it is already sealed under K_c (see notifyCodec.ts), so Web Push encryption is
/// only the outer transport layer here, not the confidentiality boundary.

/// Why the toggle could not be turned on. 'unsupported' — no SW/PushManager (or
/// no SW registration, e.g. `vite dev`); 'denied' — the user (or the browser)
/// refused notifications; 'failed' — the push service or the server said no.
export type PushResult = 'enabled' | 'denied' | 'unsupported' | 'failed';

/// True when this browser can do background push at all. Safari < 16.4, Firefox
/// with push disabled, and any non-secure origin land on false.
export function pushSupported(): boolean {
  return (
    typeof navigator !== 'undefined' &&
    'serviceWorker' in navigator &&
    typeof self !== 'undefined' &&
    'PushManager' in self &&
    typeof Notification !== 'undefined'
  );
}

/// Decodes a VAPID application-server key. They are published as base64url and
/// conventionally unpadded, but tolerate padding too — a rejected key would
/// silently cost every user their notifications.
export function vapidKeyToBytes(b64url: string): Uint8Array {
  const padded = b64url.replace(/-/g, '+').replace(/_/g, '/');
  const full = padded + '='.repeat((4 - (padded.length % 4)) % 4);
  return Uint8Array.from(atob(full), (c) => c.charCodeAt(0));
}

function sameBytes(a: ArrayBuffer | null | undefined, b: Uint8Array): boolean {
  if (!a) return false;
  const view = new Uint8Array(a);
  return view.length === b.length && view.every((v, i) => v === b[i]);
}

/// `navigator.serviceWorker.ready` never settles when nothing is registered (dev
/// server, or a browser that refused to install the SW), which would hang the
/// toggle forever. Cap the wait and treat a timeout as "no push here".
async function readyRegistration(): Promise<ServiceWorkerRegistration | null> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<null>((resolve) => {
    timer = setTimeout(() => resolve(null), 5_000);
  });
  try {
    return await Promise.race([navigator.serviceWorker.ready, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

/// Asks for notification permission, subscribes this browser to the push service
/// with the server's VAPID key, and registers the subscription server-side.
/// Idempotent: an existing subscription is reused (and replaced if it was made
/// with a different VAPID key — e.g. after the operator rotated theirs, when
/// subscribe() would otherwise throw forever).
export async function enablePush(vapidPublicKey: string): Promise<PushResult> {
  if (!pushSupported()) return 'unsupported';
  let permission: NotificationPermission;
  try {
    permission = await Notification.requestPermission();
  } catch {
    return 'denied';
  }
  if (permission !== 'granted') return 'denied';

  const reg = await readyRegistration();
  if (!reg?.pushManager) return 'unsupported';

  const appKey = vapidKeyToBytes(vapidPublicKey);
  try {
    let sub = await reg.pushManager.getSubscription();
    if (sub && !sameBytes(sub.options?.applicationServerKey, appKey)) {
      await sub.unsubscribe();
      sub = null;
    }
    sub ??= await reg.pushManager.subscribe({
      userVisibleOnly: true, // every push we send shows a notification — required by Chrome
      applicationServerKey: appKey as BufferSource,
    });
    const json = sub.toJSON();
    const p256dh = json.keys?.p256dh;
    const auth = json.keys?.auth;
    if (!json.endpoint || !p256dh || !auth) return 'failed';
    await api.pushSubscribe({ endpoint: json.endpoint, p256dh, auth });
    return 'enabled';
  } catch {
    return 'failed';
  }
}

/// Drops the local subscription and tells the server to forget the endpoint.
/// Best-effort on both halves: an orphaned endpoint just 410s on the next send.
export async function disablePush(): Promise<void> {
  if (!pushSupported()) return;
  try {
    const reg = await navigator.serviceWorker.getRegistration();
    const sub = await reg?.pushManager.getSubscription();
    if (!sub) return;
    const { endpoint } = sub;
    await sub.unsubscribe().catch(() => false);
    await api.pushUnsubscribe(endpoint).catch(() => undefined);
  } catch {
    /* no registration / push unavailable — nothing to undo */
  }
}
