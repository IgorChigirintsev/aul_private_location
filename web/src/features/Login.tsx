import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';

import { doLogin, doRegister } from '../session';
import { ApiError } from '../data/api';

export function Login() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const navigate = useNavigate();
  const [register, setRegister] = useState(true);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      if (register) await doRegister(email, password);
      else await doLogin(email, password);
      // The auth cookie is now set. Refresh the ['me'] query and leave the
      // dedicated /login route for "/", where Home renders the dashboard.
      // Without this navigate the /login route keeps showing the form even
      // though the account was created (there is no ['me'] observer here to
      // react to the invalidation).
      await qc.invalidateQueries({ queryKey: ['me'] });
      navigate('/', { replace: true });
    } catch (err) {
      // Localize the server error by its stable code where a generic message is
      // clearly right (rate-limited, locked, timeout…); otherwise fall through to
      // the server's own message, which for login ("wrong email or password") is
      // more useful than a coarse "unauthorized".
      setError(
        err instanceof ApiError
          ? t(`errors.${err.code}`, { defaultValue: err.message })
          : t('auth.error'),
      );
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="min-h-screen grid place-items-center px-4">
      <div className="w-full max-w-md">
        <h1 className="text-5xl font-extrabold text-primary" style={{ fontFamily: 'var(--font-heading)' }}>
          Aul
        </h1>
        <p className="mt-2 text-ink-soft leading-relaxed">{t('auth.tagline')}</p>

        <div className="mt-8 inline-flex rounded-full bg-black/5 p-1 text-sm">
          <button
            type="button"
            onClick={() => setRegister(true)}
            className={`px-4 py-1.5 rounded-full ${register ? 'bg-white shadow font-semibold' : 'text-ink-soft'}`}
          >
            {t('auth.createAccount')}
          </button>
          <button
            type="button"
            onClick={() => setRegister(false)}
            className={`px-4 py-1.5 rounded-full ${!register ? 'bg-white shadow font-semibold' : 'text-ink-soft'}`}
          >
            {t('auth.signIn')}
          </button>
        </div>

        <form onSubmit={submit} className="mt-6 space-y-3">
          <input
            type="email"
            required
            placeholder={t('auth.email')}
            autoComplete="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className="w-full rounded-xl border border-line bg-white px-4 py-3 outline-none focus:border-primary"
          />
          <input
            type="password"
            required
            minLength={8}
            placeholder={t('auth.password')}
            autoComplete={register ? 'new-password' : 'current-password'}
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="w-full rounded-xl border border-line bg-white px-4 py-3 outline-none focus:border-primary"
          />
          {error && <p className="text-danger text-sm" role="alert">{error}</p>}
          <button
            type="submit"
            disabled={busy}
            className="w-full rounded-full bg-primary py-3 font-semibold text-white hover:bg-primary-hover disabled:opacity-60"
          >
            {busy ? '…' : register ? t('auth.createAccount') : t('auth.signIn')}
          </button>
        </form>

        <p className="mt-4 text-center text-xs text-ink-soft">{t('auth.disclaimer')}</p>
      </div>
    </div>
  );
}
