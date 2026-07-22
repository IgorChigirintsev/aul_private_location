/// IndexedDB key store for the web watcher. Holds the per-circle key K_c and the
/// device identity keypair (plus the mirrored UI language, so the service worker
/// — which has no localStorage — can localize background push notifications).
///
/// SHARED WITH THE SERVICE WORKER: src/sw.ts opens this exact database to
/// decrypt push payloads, so the names/layout below are a contract between the
/// two. Everything here uses only `indexedDB`, which both contexts have.
///
/// HONEST LIMITATION (THREAT_MODEL §7): the browser runs JS served by the server,
/// so a hostile server could exfiltrate these keys on load. The web client is a
/// convenience with a weaker trust model than the native app — use the app for
/// anything sensitive. We still keep keys in IndexedDB (not localStorage) and
/// never send K_c or the private key to the server.

const DB_NAME = 'aul';
const STORE = 'keys';
const KEY_IDENTITY = 'identity';
const KEY_DEVICE = 'device-id';
const KEY_UI_LANG = 'ui-lang';
const CIRCLE_PREFIX = 'circle:';

let dbPromise: Promise<IDBDatabase> | null = null;

function openDb(): Promise<IDBDatabase> {
  dbPromise ??= new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => {
      req.result.createObjectStore(STORE);
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return dbPromise;
}

async function put(key: string, value: unknown): Promise<void> {
  const db = await openDb();
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction(STORE, 'readwrite');
    tx.objectStore(STORE).put(value, key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

async function get<T>(key: string): Promise<T | undefined> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, 'readonly');
    const req = tx.objectStore(STORE).get(key);
    req.onsuccess = () => resolve(req.result as T | undefined);
    req.onerror = () => reject(req.error);
  });
}

async function del(key: string): Promise<void> {
  const db = await openDb();
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction(STORE, 'readwrite');
    tx.objectStore(STORE).delete(key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

const circleKeyName = (circleId: string) => `${CIRCLE_PREFIX}${circleId}`;

async function getAllInRange<T>(range: IDBKeyRange): Promise<T[]> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, 'readonly');
    const req = tx.objectStore(STORE).getAll(range);
    req.onsuccess = () => resolve((req.result as T[]) ?? []);
    req.onerror = () => reject(req.error);
  });
}

function sameKey(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

export const keystore = {
  /// Appends a circle key to the per-circle keyring (newest last). Keeping old
  /// keys means history sealed under a rotated key stays readable (v1 has no
  /// forward secrecy — see THREAT_MODEL).
  async saveCircleKey(circleId: string, key: Uint8Array): Promise<void> {
    const ring = (await get<Uint8Array[]>(circleKeyName(circleId))) ?? [];
    if (!ring.some((k) => sameKey(k, key))) ring.push(key);
    await put(circleKeyName(circleId), ring);
  },
  /// The current (newest) key — used for sealing invite fragments.
  async loadCircleKey(circleId: string): Promise<Uint8Array | undefined> {
    const ring = await get<Uint8Array[]>(circleKeyName(circleId));
    return ring && ring.length ? ring[ring.length - 1] : undefined;
  },
  /// The whole keyring — decryption tries each (rotation-safe).
  async loadCircleKeys(circleId: string): Promise<Uint8Array[]> {
    return (await get<Uint8Array[]>(circleKeyName(circleId))) ?? [];
  },
  /// EVERY circle's keys, flattened into one list (newest-per-circle last).
  /// The service worker needs this: a push payload carries no circle id (that
  /// would tell the server who is being notified about what), so it can only try
  /// every key this device holds until one authenticates.
  async loadAllCircleKeys(): Promise<Uint8Array[]> {
    // '￿' is above every character a UUID can contain, so the range covers
    // exactly the "circle:*" entries and never the identity/lang ones.
    const rings = await getAllInRange<unknown>(
      IDBKeyRange.bound(CIRCLE_PREFIX, `${CIRCLE_PREFIX}￿`),
    );
    return rings
      .filter((r): r is Uint8Array[] => Array.isArray(r))
      .flat()
      .filter((k) => k instanceof Uint8Array);
  },
  async removeCircleKey(circleId: string): Promise<void> {
    await del(circleKeyName(circleId));
  },
  /// Mirrors the active UI language (the app's own choice lives in localStorage,
  /// which a service worker cannot read) so background notifications are shown
  /// in the language the user picked, not the browser's.
  async saveUiLang(lang: string): Promise<void> {
    await put(KEY_UI_LANG, lang);
  },
  async loadUiLang(): Promise<string | undefined> {
    return get<string>(KEY_UI_LANG);
  },
  async saveIdentity(publicKey: Uint8Array, privateKey: Uint8Array): Promise<void> {
    await put(KEY_IDENTITY, { publicKey, privateKey });
  },
  async loadIdentity(): Promise<{ publicKey: Uint8Array; privateKey: Uint8Array } | undefined> {
    return get(KEY_IDENTITY);
  },
  /// The server device id this browser was last registered as. Persisting it and
  /// sending it back on the next sign-in is what stops a re-auth from minting a
  /// SECOND device row for the same identity — otherwise one browser slowly
  /// sprouts duplicate markers on the map (one per stale device). Wiped on logout
  /// with everything else, so a fresh sign-in correctly starts a new device.
  async saveDeviceId(id: string): Promise<void> {
    await put(KEY_DEVICE, id);
  },
  async loadDeviceId(): Promise<string | undefined> {
    return get<string>(KEY_DEVICE);
  },
  async wipe(): Promise<void> {
    const db = await openDb();
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(STORE, 'readwrite');
      tx.objectStore(STORE).clear();
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  },
};
