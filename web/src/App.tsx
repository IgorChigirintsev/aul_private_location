import { lazy, Suspense } from 'react';
import { Route, Routes } from 'react-router-dom';

import { useMe } from './session';
import { loadCrypto } from './crypto/loadCrypto';
import { Landing } from './features/Landing';

/// The marketing landing is the only route in the entry chunk: it is public, it
/// is what crawlers and first-time visitors get, and it needs neither crypto nor
/// the map. Everything heavy loads on demand — and the crypto routes wait for
/// libsodium first, because `aulCrypto` throws if a primitive runs before init.
const Dashboard = lazy(async () => {
  await loadCrypto();
  return { default: (await import('./features/Dashboard')).Dashboard };
});
const Login = lazy(async () => {
  await loadCrypto();
  return { default: (await import('./features/Login')).Login };
});
const Join = lazy(async () => {
  await loadCrypto();
  return { default: (await import('./features/Join')).Join };
});
/// The PUBLIC live-share viewer. No account and no circle — it only needs
/// libsodium (K_share arrives in the URL fragment) and the map, so it is
/// deliberately outside Home/useMe: gating it behind auth would defeat the whole
/// point of a link an outsider can open.
const ShareView = lazy(async () => {
  await loadCrypto();
  return { default: (await import('./features/ShareView')).ShareView };
});
/// No crypto, no map — split purely to keep it out of the landing's chunk.
const Download = lazy(async () => ({
  default: (await import('./features/Download')).Download,
}));

function Fallback() {
  return <div className="grid min-h-screen place-items-center text-ink-soft">…</div>;
}

function Home() {
  const me = useMe();
  if (me.isLoading) {
    return <Fallback />;
  }
  // Logged out: show the public marketing landing (not the sign-in form).
  // Logged in: the authenticated dashboard, still served from "/".
  return me.isError ? <Landing /> : <Dashboard />;
}

export function App() {
  return (
    <Suspense fallback={<Fallback />}>
      <Routes>
        <Route path="/login" element={<Login />} />
        <Route path="/download" element={<Download />} />
        <Route path="/i/:inviteId" element={<Join />} />
        <Route path="/s/:sessionId" element={<ShareView />} />
        <Route path="*" element={<Home />} />
      </Routes>
    </Suspense>
  );
}
