import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { X } from 'lucide-react';

import { api } from '../data/api';
import { keystore } from '../data/keystore';
import { computeSafetyCode, fromBase64 } from '../crypto/aulCrypto';

interface Row {
  deviceId: string;
  platform: string;
  emojis: string[];
  hex: string;
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

/// Device verification: shows the emoji safety code between THIS device and each
/// other member device. Two people compare the emoji in person; a match means no
/// server-injected key substitution (MITM). See THREAT_MODEL §3.
///
/// A safety code is PAIRWISE (your key × theirs), so with no other device in the
/// circle there is genuinely no code to show. That empty state explains why
/// instead of leading with a "compare these emojis" instruction and then
/// presenting nothing to compare, which read as a bug.
export function VerifyDevices({ circleId, onClose }: { circleId: string; onClose: () => void }) {
  const { t } = useTranslation();
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancel = false;
    (async () => {
      try {
        const id = await keystore.loadIdentity();
        if (!id) {
          setError(t('verify.noIdentity'));
          return;
        }
        const devices = await api.circleDevices(circleId);
        const out: Row[] = [];
        for (const d of devices) {
          if (!d.pubkey) continue;
          const pub = fromBase64(d.pubkey);
          if (sameBytes(pub, id.publicKey)) continue; // skip our own device
          const code = await computeSafetyCode(id.publicKey, pub);
          out.push({ deviceId: d.id, platform: d.platform, emojis: code.emojis, hex: code.hexFallback });
        }
        if (!cancel) setRows(out);
      } catch {
        if (!cancel) setError(t('verify.loadFailed'));
      }
    })();
    return () => {
      cancel = true;
    };
  }, [circleId, t]);

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/40 p-4" onClick={onClose}>
      <div className="w-full max-w-md rounded-2xl bg-surface p-6 shadow-xl" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-bold">{t('verify.title')}</h2>
          <button onClick={onClose} aria-label={t('common.close')}><X size={20} /></button>
        </div>
        {/* Only instruct the user to compare when there IS something to compare. */}
        {!error && rows !== null && rows.length > 0 && (
          <p className="mt-2 text-sm text-ink-soft">{t('verify.description')}</p>
        )}
        {error && <p className="mt-4 text-danger">{error}</p>}
        {!error && rows === null && <p className="mt-4 text-ink-soft">{t('verify.computing')}</p>}
        {rows?.length === 0 && (
          <div className="mt-4 rounded-xl bg-bg p-4">
            <p className="font-medium">{t('verify.noDevices')}</p>
            <p className="mt-1.5 text-sm text-ink-soft">{t('verify.noDevicesWhy')}</p>
          </div>
        )}
        <div className="mt-4 space-y-3">
          {rows?.map((r) => (
            <div key={r.deviceId} className="rounded-xl bg-bg p-3">
              <div className="text-xs uppercase tracking-wide text-ink-soft">{t('verify.deviceLabel', { platform: r.platform })}</div>
              <div className="mt-1 text-2xl leading-relaxed" aria-label={t('verify.safetyCodeAria', { hex: r.hex })}>
                {r.emojis.join(' ')}
              </div>
              <div className="font-mono text-xs text-ink-soft" style={{ fontFamily: 'var(--font-mono)' }}>
                {r.hex}
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
