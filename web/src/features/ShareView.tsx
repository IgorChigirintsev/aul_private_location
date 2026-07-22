import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { useParams } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { CloudOff, EyeOff, Hourglass, Link2Off, Radio, TimerOff } from 'lucide-react';

import { api, ApiError } from '../data/api';
import { useNow } from '../data/clock';
import { formatCountdown, msUntil } from '../data/format';
import { openShareFix } from '../data/shareCodec';
import { CIRCLE_KEY_BYTES, fromBase64Url } from '../crypto/aulCrypto';
import { formatAccuracy, isUsableAccuracy } from '../map/accuracy';
import { ShareMap } from '../map/ShareMap';

const POLL_MS = 10_000;

/// The states this page never comes back from. Everything else is a wait.
type Stop = 'forbidden' | 'expired' | 'notFound';

/// Reads K_share out of the URL fragment. The fragment is never sent to the
/// server by a browser — which is exactly why the key lives there, the same way
/// an invite link carries K_c. Returns null for a missing or malformed key
/// (someone pasted the link without its `#…` tail).
function keyFromFragment(): Uint8Array | null {
  const fragment = window.location.hash.replace(/^#/, '');
  if (!fragment) return null;
  try {
    const key = fromBase64Url(fragment);
    // K_share is 32 bytes, same as any symmetric key here — see randomCircleKey.
    return key.length === CIRCLE_KEY_BYTES ? key : null;
  } catch {
    return null;
  }
}

/// Blacks the page out whenever this tab is hidden or loses focus, restoring it
/// on focus.
///
/// Be clear about what this is: a browser CANNOT prevent an OS screenshot, a
/// screen recording, or a phone camera pointed at the monitor. Nothing on the web
/// platform can, and this does not try. It only removes the map from a *casual*
/// grab — an alt-tab, a screen-share that switches windows, a screenshot tool
/// that takes focus first. It is a deterrent, and the UI copy promises exactly
/// that and nothing more ("the map hides when this tab loses focus"). Do not
/// re-word it into a screenshot-blocking claim: that would be a lie.
function useObscureWhenUnfocused(): boolean {
  const [obscured, setObscured] = useState(false);
  useEffect(() => {
    const hide = () => setObscured(true);
    const show = () => setObscured(false);
    const onVisibility = () => (document.visibilityState === 'hidden' ? hide() : show());
    document.addEventListener('visibilitychange', onVisibility);
    window.addEventListener('blur', hide);
    window.addEventListener('focus', show);
    window.addEventListener('pagehide', hide);
    setObscured(document.visibilityState === 'hidden' || !document.hasFocus());
    return () => {
      document.removeEventListener('visibilitychange', onVisibility);
      window.removeEventListener('blur', hide);
      window.removeEventListener('focus', show);
      window.removeEventListener('pagehide', hide);
    };
  }, []);
  return obscured;
}

/// The public live-share viewer: `/s/:sessionId#<base64url(K_share)>`.
///
/// No account, no circle, no app. It polls the public endpoint, decrypts the one
/// position with the key from the fragment, and shows it until the countdown
/// runs out. The server only ever handed it ciphertext.
export function ShareView() {
  const { t, i18n } = useTranslation();
  const { sessionId } = useParams();
  const now = useNow();
  const obscured = useObscureWhenUnfocused();
  const key = useMemo(() => keyFromFragment(), []);
  const [stopped, setStopped] = useState<Stop | null>(null);

  const share = useQuery({
    queryKey: ['share', sessionId],
    queryFn: () => api.getShare(sessionId!),
    enabled: !!sessionId && !!key && stopped === null,
    refetchInterval: POLL_MS,
    refetchOnWindowFocus: true, // the app default is off; here a returning viewer wants it fresh
    retry: false, // 403/410/404 are answers, not failures to retry
  });

  // The server's terminal answers. 403 is its own state on purpose: "someone else
  // opened this" is a very different thing to tell a viewer than "it expired".
  const error = share.error;
  useEffect(() => {
    if (!(error instanceof ApiError)) return;
    if (error.status === 403) setStopped('forbidden');
    else if (error.status === 410) setStopped('expired');
    else if (error.status === 404) setStopped('notFound');
  }, [error]);

  // The deadline is enforced here too, not just by the server: the page must go
  // dark the second the countdown hits zero, without waiting for a poll.
  const expiresAt = share.data?.expires_at;
  useEffect(() => {
    if (stopped === null && expiresAt && msUntil(expiresAt, now) <= 0) setStopped('expired');
  }, [expiresAt, now, stopped]);

  const position = share.data?.position ?? null;
  const fix = useMemo(
    () => (position && key ? openShareFix(position.nonce, position.ciphertext, key) : null),
    [position, key],
  );

  if (!key) {
    return <Screen icon={<Link2Off />} title={t('share.view.missingKey.title')} body={t('share.view.missingKey.body')} />;
  }
  if (stopped === 'forbidden') {
    return <Screen icon={<EyeOff />} title={t('share.view.forbidden.title')} body={t('share.view.forbidden.body')} />;
  }
  if (stopped === 'notFound') {
    return <Screen icon={<Link2Off />} title={t('share.view.notFound.title')} body={t('share.view.notFound.body')} />;
  }
  // Expired: no map, no last-known dot, nothing. The share is over.
  if (stopped === 'expired') {
    return <Screen icon={<TimerOff />} title={t('share.view.expired.title')} body={t('share.view.expired.body')} />;
  }
  // A position we cannot open means the fragment is not this session's key.
  if (position && !fix) {
    return <Screen icon={<Link2Off />} title={t('share.view.badKey.title')} body={t('share.view.badKey.body')} />;
  }

  const offline = share.isError; // non-ApiError (network) — keep polling, just say so
  const countdown = formatCountdown(msUntil(expiresAt, now));

  if (!share.data) {
    return offline
      ? <Screen icon={<CloudOff />} title={t('share.view.offline.title')} body={t('share.view.offline.body')} />
      : <Screen icon={<Hourglass />} title={t('share.view.connecting')} body="" />;
  }

  if (!fix) {
    return (
      <Screen
        icon={<Hourglass />}
        title={t('share.view.waiting.title')}
        body={t('share.view.waiting.body')}
        note={t('share.view.endsIn', { countdown })}
      />
    );
  }

  return (
    <div className="relative h-screen w-screen overflow-hidden">
      <ShareMap lat={fix.lat} lng={fix.lng} accuracy={fix.acc} />

      <header className="pointer-events-none absolute inset-x-0 top-0 z-30 flex justify-center p-3">
        <div className="pointer-events-auto flex items-center gap-2 rounded-full bg-surface/95 px-4 py-2 text-sm shadow-md backdrop-blur">
          <Radio size={14} className="text-primary" />
          <span className="font-semibold">{t('share.view.title')}</span>
          {/* You came here to go and meet someone: how vague the dot is decides
              whether you look for them on this corner or the next one. */}
          {isUsableAccuracy(fix.acc) && (
            <span className="whitespace-nowrap text-ink-soft">
              {formatAccuracy(fix.acc, i18n.language, t)}
            </span>
          )}
          <span className="tabular-nums text-ink-soft">{t('share.view.endsIn', { countdown })}</span>
        </div>
      </header>

      {offline && (
        <div
          role="status"
          className="pointer-events-none absolute inset-x-0 top-16 z-30 flex justify-center px-3"
        >
          <div className="rounded-full bg-amber-50 px-3 py-1.5 text-xs font-semibold text-amber-900 shadow">
            {t('share.view.offline.title')}
          </div>
        </div>
      )}

      <footer className="pointer-events-none absolute inset-x-0 bottom-0 z-30 flex justify-center p-3">
        <p className="max-w-md rounded-xl bg-surface/95 px-3 py-2 text-center text-xs text-ink-soft shadow backdrop-blur">
          {t('share.view.privacy')} {t('share.view.focusNote')}
        </p>
      </footer>

      {obscured && (
        <div
          aria-hidden
          className="fixed inset-0 z-50 grid place-items-center bg-black text-sm text-white/70"
        >
          {t('share.view.focusNote')}
        </div>
      )}
    </div>
  );
}

function Screen({
  icon,
  title,
  body,
  note,
}: {
  icon: ReactNode;
  title: string;
  body: string;
  note?: string;
}) {
  return (
    <div className="grid min-h-screen place-items-center px-6 text-center">
      <div className="max-w-sm">
        <div className="mx-auto flex h-12 w-12 items-center justify-center text-ink-soft">{icon}</div>
        <h1 className="mt-3 text-xl font-bold">{title}</h1>
        {body && <p className="mt-2 text-ink-soft">{body}</p>}
        {note && <p className="mt-4 font-semibold tabular-nums">{note}</p>}
      </div>
    </div>
  );
}
