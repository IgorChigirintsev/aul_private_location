import { useState } from 'react';
import { Trans, useTranslation } from 'react-i18next';
import { useQueryClient } from '@tanstack/react-query';
import { Copy, Radio, X } from 'lucide-react';

import { api } from '../data/api';
import { useNow } from '../data/clock';
import { formatCountdown, msUntil } from '../data/format';
import { isShareLive, SHARE_TTL_CHOICES_S, SHARE_TTL_DEFAULT_S, SHARES_KEY, useShareSessions } from '../data/shares';
import { randomCircleKey, toBase64Url } from '../crypto/aulCrypto';
import { useShareKeys } from '../store/shareKeys';

function shareLink(id: string, keyB64Url: string): string {
  return `${location.origin}/s/${id}#${keyB64Url}`;
}

/// Creates a time-boxed link that lets ONE outsider — no account, no app — watch
/// the caller's live location, and manages the ones already running.
///
/// The key that decrypts the position (K_share) is generated HERE, per session,
/// and goes into the link's fragment. It is not the circle key: a viewer sees this
/// one person for this one window, and can never see the circle. The server gets
/// the session id and ciphertext, never the key.
export function ShareDialog({ onClose }: { onClose: () => void }) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const now = useNow();
  const sessions = useShareSessions(true);
  const keys = useShareKeys((s) => s.keys);
  const addKey = useShareKeys((s) => s.add);
  const forgetKey = useShareKeys((s) => s.forget);

  const [ttl, setTtl] = useState<number>(SHARE_TTL_DEFAULT_S);
  const [creating, setCreating] = useState(false);
  const [errored, setErrored] = useState(false);
  const [fresh, setFresh] = useState<string | null>(null); // id of the link just made
  const [copied, setCopied] = useState<string | null>(null);

  const live = (sessions.data ?? []).filter((s) => isShareLive(s, now));
  const freshLink = fresh && keys[fresh] ? shareLink(fresh, keys[fresh]) : null;

  async function create() {
    setCreating(true);
    setErrored(false);
    try {
      // 32 fresh random bytes — a per-session key, never the circle key.
      const keyB64Url = toBase64Url(randomCircleKey());
      const session = await api.createShare(ttl);
      // Store the key BEFORE showing the link: a reload between the two would
      // otherwise leave a live session this browser could no longer feed.
      addKey(session.id, keyB64Url);
      setFresh(session.id);
      await qc.invalidateQueries({ queryKey: SHARES_KEY });
    } catch {
      setErrored(true);
    } finally {
      setCreating(false);
    }
  }

  async function copy(id: string) {
    const key = keys[id];
    if (!key) return;
    await navigator.clipboard.writeText(shareLink(id, key));
    setCopied(id);
    setTimeout(() => setCopied(null), 1500);
  }

  async function revoke(id: string) {
    if (!confirm(t('share.revokeConfirm'))) return;
    try {
      await api.revokeShare(id);
    } catch {
      /* already gone server-side — drop it locally anyway */
    }
    forgetKey(id);
    if (fresh === id) setFresh(null);
    await qc.invalidateQueries({ queryKey: SHARES_KEY });
  }

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/40 p-4" onClick={onClose}>
      <div
        className="max-h-[90vh] w-full max-w-md overflow-y-auto rounded-2xl bg-surface p-6 shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-bold">{t('share.title')}</h2>
          <button onClick={onClose} aria-label={t('common.close')}><X size={20} /></button>
        </div>

        <p className="mt-3 text-sm text-ink-soft">{t('share.intro')}</p>

        <div className="mt-4">
          <div className="text-sm font-semibold">{t('share.duration')}</div>
          <div className="mt-2 inline-flex rounded-full bg-bg p-1 text-sm">
            {SHARE_TTL_CHOICES_S.map((choice) => (
              <button
                key={choice}
                onClick={() => setTtl(choice)}
                className={`rounded-full px-3 py-1 ${ttl === choice ? 'bg-primary text-white' : 'text-ink-soft'}`}
              >
                {t('share.minutes', { minutes: choice / 60 })}
              </button>
            ))}
          </div>
        </div>

        <button
          onClick={create}
          disabled={creating}
          className="mt-4 w-full rounded-full bg-primary py-2.5 font-semibold text-white disabled:opacity-40"
        >
          {creating ? t('share.creating') : t('share.create')}
        </button>
        {errored && <p className="mt-3 text-sm text-danger">{t('share.error')}</p>}

        {freshLink && (
          <div className="mt-4 rounded-xl border border-line p-3">
            <div className="text-sm font-semibold">{t('share.linkTitle')}</div>
            <div className="mt-2 flex items-center gap-2">
              <input
                readOnly
                value={freshLink}
                className="min-w-0 flex-1 truncate rounded-lg border border-line bg-bg px-3 py-2 text-sm"
              />
              <button
                onClick={() => copy(fresh!)}
                className="flex items-center gap-1 rounded-lg bg-primary px-3 py-2 text-sm font-semibold text-white"
              >
                <Copy size={14} />
                {copied === fresh ? t('common.copied') : t('common.copy')}
              </button>
            </div>
            <p className="mt-2 text-xs text-ink-soft">
              <Trans i18nKey="share.note" components={{ code: <code /> }} />
            </p>
          </div>
        )}

        <div className="mt-5">
          <div className="text-sm font-semibold">{t('share.active')}</div>
          {live.length === 0 && <p className="mt-2 text-sm text-ink-soft">{t('share.none')}</p>}
          <ul className="mt-2 flex flex-col gap-2">
            {live.map((session) => (
              <li
                key={session.id}
                className="flex items-center gap-3 rounded-xl border border-line p-3"
              >
                <Radio size={16} className="shrink-0 text-primary" />
                <div className="min-w-0 flex-1">
                  <div className="font-semibold tabular-nums">
                    {t('share.endsIn', { countdown: formatCountdown(msUntil(session.expires_at, now)) })}
                  </div>
                  <div className="truncate text-xs text-ink-soft">
                    {session.viewer_bound ? t('share.claimed') : t('share.unclaimed')}
                  </div>
                  {!keys[session.id] && (
                    <div className="truncate text-xs text-ink-soft">{t('share.noKeyHere')}</div>
                  )}
                </div>
                {keys[session.id] && (
                  <button
                    onClick={() => copy(session.id)}
                    className="rounded-lg border border-line px-2 py-1 text-xs font-semibold"
                  >
                    {copied === session.id ? t('common.copied') : t('common.copy')}
                  </button>
                )}
                <button
                  onClick={() => revoke(session.id)}
                  className="rounded-lg px-2 py-1 text-xs font-semibold text-danger hover:bg-danger/10"
                >
                  {t('share.revoke')}
                </button>
              </li>
            ))}
          </ul>
        </div>
      </div>
    </div>
  );
}

/// The dashboard's standing admission that a live share is running: a share is
/// the one thing here that shows a NON-member where you are, so it does not get
/// to be invisible just because the dialog is closed. Reads the same session list
/// the reporter polls (no fetch of its own).
export function ShareBanner({ onOpen }: { onOpen: () => void }) {
  const { t } = useTranslation();
  const now = useNow();
  const sessions = useShareSessions(false);
  const live = (sessions.data ?? []).filter((s) => isShareLive(s, now));
  if (live.length === 0) return null;

  // Soonest deadline first — that's the one the countdown should be about.
  const next = live.reduce((a, b) => (msUntil(a.expires_at, now) <= msUntil(b.expires_at, now) ? a : b));
  return (
    <button
      onClick={onOpen}
      className="pointer-events-auto inline-flex items-center gap-2 self-start rounded-full bg-accent/15 px-3 py-1.5 text-sm font-semibold text-ink shadow-md backdrop-blur"
    >
      <Radio size={14} className="text-accent" />
      {t('share.bannerSharing')}
      <span className="tabular-nums text-ink-soft">
        {formatCountdown(msUntil(next.expires_at, now))}
      </span>
    </button>
  );
}
