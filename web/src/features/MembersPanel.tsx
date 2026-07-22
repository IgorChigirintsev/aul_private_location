import { useEffect, useMemo, useReducer } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { Battery, Bell, BellOff, MapPin, UserMinus } from 'lucide-react';

import { api } from '../data/api';
import { useMapFocus } from '../store/mapFocus';
import { isStale } from '../data/freshness';
import { NO_MUTES, useMutes, useSetMutes, withMemberMuted } from '../data/mutes';
import { formatAccuracy, isPoorAccuracy, isUsableAccuracy } from '../map/accuracy';
import { useDevices } from '../store/devices';
import { usePositions } from '../store/positions';
import { useProfiles } from '../store/profiles';
import { batteryColor } from '../design/tokens';
import type { MemberPosition, UserDTO } from '../data/types';

/// Members panel: everyone in the circle, their precision mode, and — where a
/// decrypted position exists — battery and "updated N min ago". Each other member
/// gets a mute toggle (the server then stops fanning their notifications out to
/// this account). Owners can also remove a member; [onRemoved] then lets the
/// parent offer a key rotation (a removed member keeps their copy of K_c — v1 has
/// no forward secrecy).
export function MembersPanel({
  circleId,
  isOwner = false,
  onRemoved,
}: {
  circleId: string;
  isOwner?: boolean;
  onRemoved?: () => void;
}) {
  const { t, i18n } = useTranslation();
  const lang = i18n.resolvedLanguage ?? i18n.language;
  // Advance "N min ago" and let a fresh row cross into "stale" on its own, even
  // when nothing new arrives (a device that quietly stopped reporting produces no
  // store change to re-render off). Same 30s cadence as the poll/geofence pass.
  const [, tick] = useReducer((n: number) => n + 1, 0);
  useEffect(() => {
    const timer = setInterval(tick, 30_000);
    return () => clearInterval(timer);
  }, []);
  const agoLabel = (ms: number): string => {
    const s = Math.round((Date.now() - ms) / 1000);
    if (s < 60) return t('members.ago.justNow');
    const m = Math.round(s / 60);
    if (m < 60) return t('members.ago.min', { count: m });
    const h = Math.round(m / 60);
    return t('members.ago.hour', { count: h });
  };
  const members = useQuery({
    queryKey: ['members', circleId],
    queryFn: () => api.members(circleId),
  });
  const positions = usePositions((s) => s.positions);
  const devices = useDevices((s) => s.devices);
  const profiles = useProfiles((s) => s.profiles);

  /// Each member's OWN freshest position, joined through their devices.
  ///
  /// This used to be `posList[0]` — literally the first decrypted position in the
  /// store, shown on every row, so everyone wore one person's pin, battery and
  /// "N min ago". The excuse was that the server didn't expose device→member; it
  /// does now (`GET /circles/:id/devices`, already loaded for the map's PC badge),
  /// so a member with several devices gets their newest, and one with none gets
  /// nothing instead of someone else's.
  const positionByUser = useMemo(() => {
    const out: Record<string, MemberPosition> = {};
    for (const pos of Object.values(positions)) {
      const userId = devices[pos.deviceId]?.userId;
      if (!userId) continue;
      const current = out[userId];
      if (!current || pos.capturedAt > current.capturedAt) out[userId] = pos;
    }
    return out;
  }, [positions, devices]);
  const qc = useQueryClient();
  const myUserId = qc.getQueryData<UserDTO>(['me'])?.id;
  const mutes = useMutes(circleId);
  const setMutes = useSetMutes(circleId);
  const muteSet = mutes.data ?? NO_MUTES;

  function toggleMute(userId: string, muted: boolean) {
    setMutes.mutate(withMemberMuted(muteSet, userId, muted));
  }

  async function remove(userId: string, name: string) {
    if (!confirm(t('members.removeConfirm', { name }))) return;
    await api.removeMember(circleId, userId);
    await qc.invalidateQueries({ queryKey: ['members', circleId] });
    onRemoved?.();
  }

  return (
    <div className="flex flex-col gap-2 p-3">
      <h2 className="px-1 text-sm font-semibold text-ink-soft">{t('members.heading')}</h2>
      {members.data?.map((m) => {
        const p = positionByUser[m.user_id];
        // Older than the shared threshold: the device stopped reporting, so the
        // last fix is no longer "where they are now". Flag the row instead of
        // letting a fresh-looking "N min ago" imply otherwise.
        const stale = p != null && isStale(p.capturedAt);
        // The member's per-circle profile (nickname + avatar), decrypted into the
        // profiles store; fall back to the email and its first letter.
        const profile = profiles[m.user_id];
        const name = profile?.nick?.trim() || m.email;
        const avatar = profile?.avatar;
        const muted = muteSet.muted_user_ids.includes(m.user_id);
        // A word to YOURSELF when your own fix is genuinely bad, and only from a
        // web device: a desktop is located from the Wi-Fi it can see, so a couple
        // of blocks off is the hardware being honest, not a bug to chase. Never
        // shown for someone else (they cannot act on it) and never for a phone.
        const wifiHint =
          m.user_id === myUserId &&
          p != null &&
          devices[p.deviceId]?.platform === 'web' &&
          isPoorAccuracy(p.accuracy);
        return (
          <div
            key={m.user_id}
            onClick={p ? () => useMapFocus.getState().focus(p.lng, p.lat) : undefined}
            className={`flex items-center gap-3 rounded-xl bg-surface p-3 shadow-sm ${p ? 'cursor-pointer transition-colors hover:bg-primary/5' : ''}`}
            title={p ? t('members.centerOnMap') : undefined}
          >
            {avatar ? (
              <img
                src={avatar}
                alt=""
                className="h-10 w-10 shrink-0 rounded-full object-cover"
              />
            ) : (
              <div className="grid h-10 w-10 shrink-0 place-items-center rounded-full bg-primary/10 font-semibold text-primary">
                {name.slice(0, 1).toUpperCase()}
              </div>
            )}
            <div className="min-w-0 flex-1">
              <div className="truncate font-medium">
                {name}
                {m.user_id === myUserId && (
                  <span className="ml-1 font-normal text-ink-soft">{t('profile.you')}</span>
                )}
              </div>
              {/* Three facts in a 20rem panel: let the ROW wrap between them, but
                  never inside one — "±350 m" broke after the number, stranding the
                  unit on its own line, and an icon must not part from its text. */}
              <div className="flex flex-wrap items-center gap-x-2 gap-y-0.5 text-xs text-ink-soft">
                <span className="whitespace-nowrap">{t(`common.precision.${m.precision_mode}`)}</span>
                {p && (
                  <span
                    className={`inline-flex items-center gap-1 whitespace-nowrap ${stale ? 'italic opacity-60' : ''}`}
                  >
                    <MapPin size={12} />
                    {agoLabel(p.updatedAt)}
                  </span>
                )}
                {p && stale && (
                  <span
                    className="inline-flex items-center whitespace-nowrap rounded-full bg-accent/15 px-1.5 py-px text-[10px] font-semibold uppercase tracking-wide text-accent"
                    title={t('members.staleTitle')}
                  >
                    {t('members.stale')}
                  </span>
                )}
                {p && isUsableAccuracy(p.accuracy) && (
                  <span className="whitespace-nowrap" title={t('members.accuracyTitle')}>
                    {formatAccuracy(p.accuracy, lang, t)}
                  </span>
                )}
              </div>
              {wifiHint && (
                <p className="mt-1 text-xs leading-snug text-ink-soft">{t('members.wifiHint')}</p>
              )}
            </div>
            {p?.battery != null && (
              <div className="flex items-center gap-1 text-sm font-semibold" style={{ color: batteryColor(p.battery) }}>
                <Battery size={16} />
                {p.battery}%
              </div>
            )}
            {m.user_id !== myUserId && (
              <button
                title={muted ? t('members.unmute', { name }) : t('members.mute', { name })}
                aria-label={muted ? t('members.unmute', { name }) : t('members.mute', { name })}
                aria-pressed={muted}
                disabled={setMutes.isPending}
                onClick={(e) => {
                  e.stopPropagation();
                  toggleMute(m.user_id, !muted);
                }}
                className={`shrink-0 rounded-full p-2 transition-colors hover:bg-black/5 disabled:opacity-40 ${muted ? 'text-danger' : 'text-ink-soft'}`}
              >
                {muted ? <BellOff size={16} /> : <Bell size={16} />}
              </button>
            )}
            {isOwner && m.user_id !== myUserId && (
              <button
                title={t('members.remove')}
                aria-label={t('members.remove')}
                onClick={(e) => {
                  e.stopPropagation();
                  void remove(m.user_id, name);
                }}
                className="shrink-0 rounded-full p-2 text-ink-soft transition-colors hover:bg-danger/10 hover:text-danger"
              >
                <UserMinus size={16} />
              </button>
            )}
          </div>
        );
      })}
      {members.data?.length === 0 && (
        <p className="px-1 text-sm text-ink-soft">{t('members.empty')}</p>
      )}
    </div>
  );
}
