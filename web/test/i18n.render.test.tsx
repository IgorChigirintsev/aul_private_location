import { afterAll, describe, expect, it } from 'vitest';
import { renderToStaticMarkup } from 'react-dom/server';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { I18nextProvider } from 'react-i18next';
import { MemoryRouter } from 'react-router-dom';

import i18n from '../src/i18n';
import { Login } from '../src/features/Login';

/// Renders a real feature component through the bundled i18n instance and asserts
/// the visible copy switches with the active language. renderToStaticMarkup keeps
/// this in the existing node test environment (no jsdom needed) — no effects run,
/// so the sign-in form renders synchronously.
function renderLogin(): string {
  const qc = new QueryClient();
  return renderToStaticMarkup(
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={qc}>
        <MemoryRouter>
          <Login />
        </MemoryRouter>
      </QueryClientProvider>
    </I18nextProvider>,
  );
}

describe('i18n rendering', () => {
  it('shows the Russian copy after changeLanguage("ru")', async () => {
    await i18n.changeLanguage('ru');
    const html = renderLogin();
    expect(html).toContain('Создать аккаунт'); // auth.createAccount (ru)
    expect(html).toContain('Пароль'); // auth.password (ru)
    expect(html).not.toContain('Create account');
  });

  it('shows the English copy after changeLanguage("en")', async () => {
    await i18n.changeLanguage('en');
    const html = renderLogin();
    expect(html).toContain('Create account');
    expect(html).not.toContain('Создать аккаунт');
  });
});

afterAll(async () => {
  await i18n.changeLanguage('en');
});
