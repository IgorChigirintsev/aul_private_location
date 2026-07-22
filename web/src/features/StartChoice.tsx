import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';

import { parseInviteLink } from '../data/inviteLink';
import { ArrowRight, Link2, MapPinned, PlusCircle } from 'lucide-react';


/// The onboarding fork shown to a signed-in user who has no circles yet: an
/// explicit choice of how to start. Replaces the single-button empty state.
export function StartChoice({ onCreate }: { onCreate: () => void }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const [showJoin, setShowJoin] = useState(false);
  const [linkText, setLinkText] = useState('');
  const [error, setError] = useState(false);

  function join() {
    const parsed = parseInviteLink(linkText);
    if (!parsed) {
      setError(true);
      return;
    }
    // The fragment (K_c) rides only in this client-side navigation — never a
    // query string, never the server, never a log.
    nav(`/i/${parsed.inviteId}#${parsed.fragment}`);
  }

  return (
    <div className="grid min-h-screen place-items-center px-6 py-10 text-center">
      <div className="w-full max-w-md">
        <MapPinned className="mx-auto text-primary" size={48} />
        <h1 className="mt-4 text-2xl font-bold">{t('start.title')}</h1>
        <p className="mt-2 text-ink-soft">{t('start.body')}</p>

        <div className="mt-8 flex flex-col gap-3 text-left">
          {/* 1 — Create a circle (primary path) */}
          <button
            onClick={onCreate}
            className="group flex items-center gap-3 rounded-2xl bg-primary p-4 text-white shadow-md transition hover:brightness-105"
          >
            <PlusCircle size={24} className="shrink-0" />
            <span className="min-w-0 flex-1">
              <span className="block font-semibold">{t('start.create.title')}</span>
              <span className="block text-sm text-white/80">{t('start.create.body')}</span>
            </span>
            <ArrowRight size={18} className="shrink-0 opacity-70 transition group-hover:translate-x-0.5" />
          </button>

          {/* 2 — Join an existing circle via a pasted invite link */}
          {!showJoin ? (
            <button
              onClick={() => setShowJoin(true)}
              className="group flex items-center gap-3 rounded-2xl bg-surface p-4 shadow-md transition hover:bg-black/5"
            >
              <Link2 size={24} className="shrink-0 text-primary" />
              <span className="min-w-0 flex-1">
                <span className="block font-semibold">{t('start.join.title')}</span>
                <span className="block text-sm text-ink-soft">{t('start.join.body')}</span>
              </span>
              <ArrowRight size={18} className="shrink-0 text-ink-soft opacity-70 transition group-hover:translate-x-0.5" />
            </button>
          ) : (
            <div className="rounded-2xl bg-surface p-4 shadow-md">
              <div className="flex items-center gap-3">
                <Link2 size={24} className="shrink-0 text-primary" />
                <span className="font-semibold">{t('start.join.title')}</span>
              </div>
              <input
                autoFocus
                value={linkText}
                onChange={(e) => {
                  setLinkText(e.target.value);
                  if (error) setError(false);
                }}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') join();
                }}
                placeholder={t('start.join.placeholder')}
                aria-label={t('start.join.title')}
                aria-invalid={error}
                className="mt-3 w-full rounded-lg border border-line bg-bg px-3 py-2 text-sm"
              />
              {error && <p className="mt-2 text-sm text-danger">{t('start.join.error')}</p>}
              <button
                onClick={join}
                disabled={!linkText.trim()}
                className="mt-3 w-full rounded-full bg-primary py-2.5 font-semibold text-white disabled:opacity-40"
              >
                {t('start.join.submit')}
              </button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
