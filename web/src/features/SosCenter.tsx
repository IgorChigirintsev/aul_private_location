import { useEffect } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { AlertTriangle, Check } from 'lucide-react';

import { api } from '../data/api';
import { openSos } from '../data/placeCodec';
import { useSos } from '../store/sos';

/// The SOS banner: seeds active alerts from the server and renders whatever the
/// realtime layer has put in the SOS store, each with its decrypted message /
/// last-known location and a Resolve action. Undecryptable alerts still show
/// (someone raised an SOS) so no emergency is ever silently missed.
export function SosBanner({ circleId, keyring }: { circleId: string; keyring: Uint8Array[] }) {
  const { t, i18n } = useTranslation();
  const qc = useQueryClient();
  const active = useSos((s) => s.active);
  const sosQ = useQuery({
    queryKey: ['sos', circleId],
    queryFn: () => api.listSos(circleId),
    enabled: keyring.length > 0,
    refetchInterval: 60_000,
  });

  useEffect(() => {
    if (!sosQ.data) return;
    // Reconcile (not replace): a poll must never drop a realtime-added alert.
    useSos.getState().reconcile(sosQ.data.map((dto) => openSos(dto, keyring)), Date.now());
  }, [sosQ.data, keyring]);

  async function resolve(id: string) {
    useSos.getState().remove(id);
    try {
      await api.resolveSos(circleId, id);
    } finally {
      await qc.invalidateQueries({ queryKey: ['sos', circleId] });
    }
  }

  const list = Object.values(active).sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  if (list.length === 0) return null;

  return (
    <div className="pointer-events-auto space-y-2">
      {list.map((s) => (
        <div key={s.id} className="flex items-start gap-3 rounded-2xl bg-danger px-4 py-3 text-white shadow-lg">
          <AlertTriangle size={20} className="mt-0.5 shrink-0" />
          <div className="flex-1">
            <div className="font-bold">{t('sos.title')}</div>
            <div className="text-sm text-white/90">
              {s.decrypted
                ? (s.message?.trim() || t('sos.noMessage')) +
                  (s.lat != null && s.lng != null ? ` · ${s.lat.toFixed(4)}, ${s.lng.toFixed(4)}` : '')
                : t('sos.encrypted')}
            </div>
            <div className="text-xs text-white/70">{new Date(s.createdAt).toLocaleTimeString(i18n.language)}</div>
          </div>
          <button
            onClick={() => resolve(s.id)}
            className="flex items-center gap-1 rounded-full bg-white/20 px-3 py-1.5 text-sm font-semibold hover:bg-white/30"
          >
            <Check size={15} /> {t('sos.resolve')}
          </button>
        </div>
      ))}
    </div>
  );
}
