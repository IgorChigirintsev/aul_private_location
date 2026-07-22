import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { BrowserRouter } from 'react-router-dom';

import { App } from './App';
import { applyTheme, loadTheme } from './theme';
import './i18n';
import './index.css';

// Stamp the saved theme before the first paint. "system" is a no-op (the CSS
// prefers-color-scheme rules already cover it), so there is no flash either way.
applyTheme(loadTheme());

const queryClient = new QueryClient({
  defaultOptions: { queries: { refetchOnWindowFocus: false } },
});

// Render immediately. libsodium is NOT initialised here on purpose: awaiting it
// up front made every visitor — including the landing page and crawlers — wait
// on ~1 MB of wasm they may never need. Each crypto route now loads and
// initialises it itself (see src/crypto/loadCrypto.ts + the lazy routes in App).
createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <App />
      </BrowserRouter>
    </QueryClientProvider>
  </StrictMode>,
);
