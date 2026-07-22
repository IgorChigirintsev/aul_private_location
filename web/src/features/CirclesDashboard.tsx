import { useEffect, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { X } from 'lucide-react';

import { api } from '../data/api';
import { keystore } from '../data/keystore';
import { openProfile } from '../data/profileCodec';
import { NO_MUTES, useMutes, useSetMutes, withCircleMuted } from '../data/mutes';
import type { CircleSummary, UserDTO } from '../data/types';

/// "My circles": every circle you belong to, with the two switches that decide
/// what each one costs you — whether you share your location with it, and whether
/// its members can reach you with notifications.
///
/// Each row is decrypted with THAT circle's OWN key (K_c is per-circle), so the
/// nickname and avatar are the ones you chose there — not the selected circle's.
export function CirclesDashboard({
  circles,
  names,
  onClose,
}: {
  circles: CircleSummary[];
  names: Record<string, string>;
  onClose: () => void;
}) {
  const { t } = useTranslation();

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/40 p-4" onClick={onClose}>
      <div
        className="flex max-h-[85vh] w-full max-w-lg flex-col rounded-2xl bg-surface shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-start justify-between gap-3 p-6 pb-3">
          <div>
            <h2 className="text-lg font-bold">{t('circlesDash.title')}</h2>
            <p className="mt-1 text-sm text-ink-soft">{t('circlesDash.subtitle')}</p>
          </div>
          <button onClick={onClose} aria-label={t('common.close')} className="rounded-full p-1 hover:bg-black/5">
            <X size={20} />
          </button>
        </div>

        <div className="flex-1 space-y-3 overflow-y-auto px-6 pb-6">
          {circles.map((c) => (
            <CircleRow key={c.id} circle={c} name={names[c.id] ?? t('dashboard.circleFallback')} />
          ))}
          {circles.length === 0 && <p className="text-sm text-ink-soft">{t('circlesDash.empty')}</p>}
        </div>

        <div className="border-t border-line p-4">
          <button onClick={onClose} className="w-full rounded-full bg-primary py-2.5 font-semibold text-white">
            {t('common.done')}
          </button>
        </div>
      </div>
    </div>
  );
}

/// One circle. A row owns its own queries/mutations (rather than the parent
/// fanning out N of each) so a slow or 404-ing circle never blocks the others.
function CircleRow({ circle, name }: { circle: CircleSummary; name: string }) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const myUserId = qc.getQueryData<UserDTO>(['me'])?.id;
  const [keyring, setKeyring] = useState<Uint8Array[] | null>(null);
  const [busy, setBusy] = useState(false);

  // This circle's OWN keyring, from local IndexedDB — the only thing that can
  // open the profile you set in THIS circle.
  useEffect(() => {
    let cancel = false;
    void (async () => {
      const ring = await keystore.loadCircleKeys(circle.id);
      if (!cancel) setKeyring(ring);
    })();
    return () => {
      cancel = true;
    };
  }, [circle.id]);

  // Shares the ['members', id] cache with the map/members panel, so a precision
  // change made here (or there) settles both.
  const members = useQuery({
    queryKey: ['members', circle.id],
    queryFn: () => api.members(circle.id),
  });
  const mutes = useMutes(circle.id);
  const setMutes = useSetMutes(circle.id);
  const muteSet = mutes.data ?? NO_MUTES;

  const mine = members.data?.find((m) => m.user_id === myUserId);
  const profile = mine?.profile_enc && keyring ? openProfile(mine.profile_enc, keyring) : null;
  const nick = profile?.nick?.trim() || mine?.email || '';
  const avatar = profile?.avatar;

  // "Sharing" is precision_mode ≠ paused, so this switch and the map's
  // Precise/City/Paused control are two views of ONE server value: turning it off
  // pauses, turning it on goes back to precise.
  const visible = circle.precision_mode !== 'paused';

  async function toggleVisibility(next: boolean) {
    if (busy) return;
    setBusy(true);
    try {
      await api.setPrecision(circle.id, next ? 'precise' : 'paused');
      // ['circles'] carries precision_mode (this switch + the map control);
      // ['members'] is what greys out a paused member's marker for everyone.
      await qc.invalidateQueries({ queryKey: ['circles'] });
      await qc.invalidateQueries({ queryKey: ['members', circle.id] });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="rounded-2xl border border-line p-4">
      <div className="flex items-center gap-3">
        {avatar ? (
          <img src={avatar} alt="" className="h-11 w-11 shrink-0 rounded-full object-cover" />
        ) : (
          <div className="grid h-11 w-11 shrink-0 place-items-center rounded-full bg-primary/10 text-lg font-semibold text-primary">
            {(nick || name).slice(0, 1).toUpperCase()}
          </div>
        )}
        <div className="min-w-0 flex-1">
          <div className="truncate font-semibold">{name}</div>
          <div className="truncate text-sm text-ink-soft">
            {nick ? t('circlesDash.youAs', { nick }) : t('circlesDash.youNoNick')}
          </div>
        </div>
        {circle.role === 'owner' && (
          <span className="shrink-0 text-xs text-ink-soft">{t('circles.owner')}</span>
        )}
      </div>

      <div className="mt-3 space-y-2">
        <Switch
          checked={visible}
          disabled={busy}
          onChange={toggleVisibility}
          title={t('circlesDash.visibility.title')}
          desc={visible ? t('circlesDash.visibility.on') : t('circlesDash.visibility.off')}
        />
        <Switch
          checked={!muteSet.circle_muted}
          disabled={setMutes.isPending}
          onChange={(on) => setMutes.mutate(withCircleMuted(muteSet, !on))}
          title={t('circlesDash.notifications.title')}
          desc={muteSet.circle_muted ? t('circlesDash.notifications.off') : t('circlesDash.notifications.on')}
        />
      </div>
    </div>
  );
}

function Switch({
  checked,
  onChange,
  title,
  desc,
  disabled = false,
}: {
  checked: boolean;
  onChange: (v: boolean) => void;
  title: string;
  desc: string;
  disabled?: boolean;
}) {
  return (
    <div className="flex items-start justify-between gap-3 rounded-xl bg-black/[0.03] p-3">
      <div className="min-w-0">
        <div className="text-sm font-medium">{title}</div>
        <div className="mt-0.5 text-xs text-ink-soft">{desc}</div>
      </div>
      <button
        type="button"
        role="switch"
        aria-checked={checked}
        aria-label={title}
        disabled={disabled}
        onClick={() => onChange(!checked)}
        className={`relative mt-0.5 h-6 w-11 shrink-0 rounded-full transition-colors disabled:opacity-40 ${checked ? 'bg-primary' : 'bg-black/15'}`}
      >
        <span
          className={`absolute top-0.5 h-5 w-5 rounded-full bg-white shadow transition-all ${checked ? 'left-[1.375rem]' : 'left-0.5'}`}
        />
      </button>
    </div>
  );
}
