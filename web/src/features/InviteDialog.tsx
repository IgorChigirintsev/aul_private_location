import { useEffect, useState } from 'react';
import QRCode from 'qrcode';
import { Trans, useTranslation } from 'react-i18next';
import { Copy, X } from 'lucide-react';

import { api } from '../data/api';
import { toBase64Url } from '../crypto/aulCrypto';

/// Creates an invite and shows the shareable link + QR. The circle key K_c is
/// appended as the URL fragment — it never touches the server.
export function InviteDialog({
  circleId,
  circleKey,
  onClose,
}: {
  circleId: string;
  circleKey: Uint8Array;
  onClose: () => void;
}) {
  const { t } = useTranslation();
  const [link, setLink] = useState<string | null>(null);
  const [qr, setQr] = useState<string | null>(null);
  const [errored, setErrored] = useState(false);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const invite = await api.createInvite(circleId, 5);
        // K_c → URL-safe base64 without padding, in the fragment.
        const url = `${location.origin}/i/${invite.id}#${toBase64Url(circleKey)}`;
        if (cancelled) return;
        setLink(url);
        setQr(await QRCode.toDataURL(url, { margin: 1, width: 240 }));
      } catch {
        if (!cancelled) setErrored(true);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [circleId, circleKey]);

  async function copy() {
    if (!link) return;
    await navigator.clipboard.writeText(link);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  }

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/40 p-4" onClick={onClose}>
      <div
        className="w-full max-w-sm rounded-2xl bg-surface p-6 shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-bold">{t('invite.title')}</h2>
          <button onClick={onClose} aria-label={t('common.close')}><X size={20} /></button>
        </div>
        {errored && <p className="mt-4 text-danger">{t('invite.error')}</p>}
        {!errored && !link && <p className="mt-4 text-ink-soft">{t('invite.creating')}</p>}
        {link && (
          <>
            {qr && <img src={qr} alt={t('invite.qrAlt')} className="mx-auto mt-4 rounded-lg" width={200} height={200} />}
            <p className="mt-4 text-xs text-ink-soft">
              <Trans i18nKey="invite.note" components={{ code: <code /> }} />
            </p>
            <div className="mt-3 flex items-center gap-2">
              <input readOnly value={link} className="min-w-0 flex-1 truncate rounded-lg border border-line bg-bg px-3 py-2 text-sm" />
              <button
                onClick={copy}
                className="flex items-center gap-1 rounded-lg bg-primary px-3 py-2 text-sm font-semibold text-white"
              >
                <Copy size={14} />
                {copied ? t('common.copied') : t('common.copy')}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
