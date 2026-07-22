import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Bell, X } from 'lucide-react';

import { usePrefs } from '../store/prefs';
import { disablePush, enablePush, pushSupported } from '../data/push';
import { serverRetentionEnabled, useServerInfo } from '../data/retention';
import { LanguageSwitcher } from '../i18n/LanguageSwitcher';
import { ThemeSwitcher } from './ThemeSwitcher';

type Perm = NotificationPermission | 'unsupported';

function currentPermission(): Perm {
  return typeof Notification === 'undefined' ? 'unsupported' : Notification.permission;
}

/// Preferences dialog: the retention-feature opt-ins (all OFF by default), the
/// browser-notification permission affordance, and the background-push opt-in.
/// The whole section is hidden and the toggles are inert when the operator has
/// disabled the features server-side (kill-switch). Opting into arrival alerts
/// requests notification permission on the spot; opting into background
/// notifications also subscribes this browser to Web Push.
export function Preferences({ onClose }: { onClose: () => void }) {
  const { t } = useTranslation();
  const info = useServerInfo();
  const serverEnabled = serverRetentionEnabled(info.data);
  // Absent/null: the operator configured no VAPID keys, so there is no push to
  // opt into — the toggle is hidden rather than offered and then failing.
  const vapidKey = info.data?.vapid_public_key ?? null;
  const arrivalEnabled = usePrefs((s) => s.arrivalEnabled);
  const pushEnabled = usePrefs((s) => s.pushEnabled);
  const setArrivalEnabled = usePrefs((s) => s.setArrivalEnabled);
  const setPushEnabled = usePrefs((s) => s.setPushEnabled);
  const [perm, setPerm] = useState<Perm>(currentPermission);
  const [pushBusy, setPushBusy] = useState(false);
  const [pushNote, setPushNote] = useState<string | null>(null);
  const canPush = pushSupported();
  // Why the switch is off/inert: the last failure reason, else the standing
  // "this browser can't" for a browser without push at all.
  const pushHint = pushNote ?? (canPush ? null : t('prefs.push.unsupported'));

  async function requestPermission() {
    if (typeof Notification === 'undefined') return;
    try {
      const res = await Notification.requestPermission();
      setPerm(res);
    } catch {
      /* ignore — leave the current state */
    }
  }

  async function onToggleArrival(v: boolean) {
    setArrivalEnabled(v);
    // Opting in is the natural moment to ask for notification permission.
    if (v && perm === 'default') await requestPermission();
  }

  /// Turning this on asks for permission, subscribes to the push service and
  /// registers the subscription; turning it off undoes all three. The stored
  /// pref only flips when the browser actually agreed, so a denied prompt leaves
  /// the switch off (with the reason underneath) instead of lying.
  async function onTogglePush(v: boolean) {
    if (pushBusy || !vapidKey) return;
    setPushNote(null);
    setPushBusy(true);
    try {
      if (!v) {
        setPushEnabled(false);
        await disablePush();
        return;
      }
      const res = await enablePush(vapidKey);
      setPushEnabled(res === 'enabled');
      setPerm(currentPermission());
      if (res !== 'enabled') setPushNote(t(`prefs.push.${res}`));
    } finally {
      setPushBusy(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/40 p-4" onClick={onClose}>
      <div className="w-full max-w-sm rounded-2xl bg-surface p-6 shadow-xl" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-bold">{t('prefs.title')}</h2>
          <button onClick={onClose} className="rounded-full p-1 hover:bg-black/5"><X size={18} /></button>
        </div>

        <div className="mt-4 flex items-center justify-between gap-3 rounded-xl bg-black/[0.03] p-3">
          <span className="text-sm font-medium">{t('language.label')}</span>
          <LanguageSwitcher />
        </div>

        <div className="mt-3 flex items-center justify-between gap-3 rounded-xl bg-black/[0.03] p-3">
          <span className="text-sm font-medium">{t('theme.label')}</span>
          <ThemeSwitcher />
        </div>

        {!serverEnabled ? (
          <p className="mt-3 rounded-xl bg-amber-50 p-3 text-sm text-amber-900">
            {t('prefs.serverDisabled')}
          </p>
        ) : (
          <div className="mt-3 space-y-3">
            <p className="text-sm text-ink-soft">{t('prefs.intro')}</p>

            <Toggle
              checked={arrivalEnabled}
              onChange={onToggleArrival}
              title={t('prefs.arrival.title')}
              desc={t('prefs.arrival.desc')}
            />

            <div className="rounded-xl bg-black/[0.03] p-3">
              <div className="flex items-center gap-2 text-sm font-medium">
                <Bell size={15} className="text-primary" /> {t('prefs.notifications.title')}
              </div>
              <div className="mt-1 flex items-center justify-between gap-2">
                <span className="text-xs text-ink-soft">
                  {perm === 'granted'
                    ? t('prefs.notifications.granted')
                    : perm === 'denied'
                      ? t('prefs.notifications.denied')
                      : perm === 'unsupported'
                        ? t('prefs.notifications.unsupported')
                        : t('prefs.notifications.default')}
                </span>
                {(perm === 'default') && (
                  <button
                    onClick={requestPermission}
                    className="shrink-0 rounded-full bg-primary px-3 py-1.5 text-xs font-semibold text-white"
                  >
                    {t('prefs.notifications.allow')}
                  </button>
                )}
              </div>
            </div>

            {vapidKey && (
              <div>
                <Toggle
                  checked={pushEnabled}
                  onChange={onTogglePush}
                  title={t('prefs.push.title')}
                  desc={t('prefs.push.desc')}
                  disabled={!canPush || pushBusy}
                />
                {pushHint && (
                  <p className="mt-1 px-1 text-xs text-amber-800" role="status">
                    {pushHint}
                  </p>
                )}
              </div>
            )}

            {!vapidKey ? (
              <p className="text-xs text-ink-soft">{t('prefs.push.serverOff')}</p>
            ) : (
              !pushEnabled && <p className="text-xs text-ink-soft">{t('prefs.backgroundNote')}</p>
            )}
          </div>
        )}

        <button onClick={onClose} className="mt-5 w-full rounded-full bg-primary py-2.5 font-semibold text-white">{t('common.done')}</button>
      </div>
    </div>
  );
}

function Toggle({
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
