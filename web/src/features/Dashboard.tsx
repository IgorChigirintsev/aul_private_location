import { useEffect, useMemo, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Trans, useTranslation } from 'react-i18next';
import { Compass, Eye, KeyRound, LocateFixed, LogOut, MapPin, Radio, Settings, ShieldCheck, Siren, UserPen, UserPlus } from 'lucide-react';

import { api, ApiError } from '../data/api';
import { keystore } from '../data/keystore';
import { keyManager } from '../data/keyManager';
import { openFramed, randomCircleKey, sealFramed, toBase64 } from '../crypto/aulCrypto';
import { pingToPosition } from '../data/pingDecode';
import { openSos, sealSos } from '../data/placeCodec';
import { RealtimeClient } from '../data/realtime';
import { usePositions } from '../store/positions';
import { usePlaces } from '../store/places';
import { useSos } from '../store/sos';
import { useMapDraft } from '../store/mapDraft';
import { useMapFocus } from '../store/mapFocus';
import { useConnection } from '../store/connection';
import { doLogout } from '../session';
import type { CircleSummary, MemberPosition, Place, PrecisionMode, SosDTO, UserDTO } from '../data/types';
import { openProfile } from '../data/profileCodec';
import { openPlace } from '../data/placeCodec';
import { MapView } from '../map/MapView';
import { MembersPanel } from './MembersPanel';
import { GeofenceFeed } from './GeofenceFeed';
import { MobileSheet } from './MobileSheet';
import { PlacesPanel } from './PlacesPanel';
import { Preferences } from './Preferences';
import { SosBanner } from './SosCenter';
import { InviteDialog } from './InviteDialog';
import { ShareBanner, ShareDialog } from './ShareDialog';
import { ProfileDialog } from './ProfileDialog';
import { CircleSwitcher } from './CircleSwitcher';
import { CirclesDashboard } from './CirclesDashboard';
import { OfflineBanner } from './OfflineBanner';
import { StartChoice } from './StartChoice';
import { VerifyDevices } from './VerifyDevices';
import { useWebReporter } from '../data/webReporter';
import { useShareReporter } from '../data/shareReporter';
import { useDevices } from '../store/devices';
import { useProfiles } from '../store/profiles';

type Panel = 'none' | 'places';

function decodeName(nameEncB64: string | null, key: Uint8Array | null, fallback: string): string {
  if (!nameEncB64 || !key) return fallback;
  try {
    return new TextDecoder().decode(openFramed(fromB64(nameEncB64), key)) || fallback;
  } catch {
    return fallback;
  }
}
function fromB64(b64: string): Uint8Array {
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

export function Dashboard() {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const circles = useQuery({ queryKey: ['circles'], queryFn: () => api.listCircles() });
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [keyring, setKeyring] = useState<Uint8Array[]>([]);
  const [showInvite, setShowInvite] = useState(false);
  const [showShare, setShowShare] = useState(false);
  const [showWho, setShowWho] = useState(false);
  const [showVerify, setShowVerify] = useState(false);
  const [showPrefs, setShowPrefs] = useState(false);
  const [showProfile, setShowProfile] = useState(false);
  const [showCircles, setShowCircles] = useState(false);
  const [circleNames, setCircleNames] = useState<Record<string, string>>({});
  const [panel, setPanel] = useState<Panel>('none');
  const reset = usePositions((s) => s.reset);
  const circleKey = keyring.length ? keyring[keyring.length - 1] : null;

  const selected: CircleSummary | undefined = useMemo(
    () => circles.data?.find((c) => c.id === selectedId) ?? circles.data?.[0],
    [circles.data, selectedId],
  );

  // Pick up any key envelopes addressed to this device, then load the circle's
  // keyring. Reset all per-circle client state on selection change.
  useEffect(() => {
    let cancel = false;
    reset();
    usePlaces.getState().reset();
    useSos.getState().reset();
    useMapDraft.getState().cancel();
    setPanel('none');
    setKeyring([]);
    if (!selected) return;
    (async () => {
      try {
        await keyManager.openPendingEnvelopes();
      } catch {
        /* offline / none */
      }
      const ring = await keystore.loadCircleKeys(selected.id);
      if (!cancel) setKeyring(ring);
    })();
    return () => {
      cancel = true;
    };
  }, [selected, reset]);

  // Seed + poll latest pings (30 s fallback), decrypting client-side.
  const latest = useQuery({
    queryKey: ['pings', selected?.id],
    queryFn: () => api.latestPings(selected!.id),
    enabled: !!selected && keyring.length > 0,
    refetchInterval: 30_000,
  });
  useEffect(() => {
    if (!latest.data || keyring.length === 0) return;
    const positions = latest.data
      .map((p) => pingToPosition(p, keyring))
      .filter((p): p is NonNullable<typeof p> => p !== null);
    usePositions.getState().bulk(positions);
  }, [latest.data, keyring]);

  // Live WebSocket updates: positions (in RealtimeClient), plus places/SOS/
  // precision fan-out wired to the stores + query invalidation.
  const rtRef = useRef<RealtimeClient | null>(null);
  useEffect(() => {
    if (!selected || keyring.length === 0) return;
    const keys = new Map<string, Uint8Array[]>([[selected.id, keyring]]);
    const rt = new RealtimeClient(keys, {
      onSos: (_c, payload) => useSos.getState().add(openSos(payload as SosDTO, keyring)),
      onSosResolved: (_c, id) => useSos.getState().remove(id),
      onPlaceUpdated: () => qc.invalidateQueries({ queryKey: ['places', selected.id] }),
      // Someone changed how they share. Refresh the members list too — it carries
      // precision_mode, which is what greys out a paused member's marker for
      // everyone else. This is the whole point of the realtime event.
      onPrecision: () => {
        void qc.invalidateQueries({ queryKey: ['circles'] });
        void qc.invalidateQueries({ queryKey: ['members', selected.id] });
      },
      onMemberChanged: () => qc.invalidateQueries({ queryKey: ['members', selected.id] }),
      // Client-inferred link health: an unreachable server can't announce its own
      // offline-ness, so we read it off the socket. Flips the "live updates
      // paused" banner (below) so a dropped connection never leaves the map
      // looking live. Only a genuine drop reports false — an intentional close on
      // circle switch / unmount is filtered out inside RealtimeClient.
      onStatus: (connected) => useConnection.getState().setOnline(connected),
    });
    rt.connect();
    rtRef.current = rt;
    return () => {
      rt.close();
      // Tearing down this subscription: we're no longer watching, so clear any
      // lingering "paused" state rather than leaving a stale banner behind.
      useConnection.getState().setOnline(true);
    };
  }, [selected, keyring, qc]);

  // This browser reports its own geolocation so the PC appears on the map as its
  // own (web) device — sealed under the circle key, honouring the precision mode
  // (paused = off). Fully E2EE; a denied permission simply means no PC marker.
  useWebReporter(selected?.id ?? null, circleKey, selected?.precision_mode ?? 'paused');

  // Live-share sessions are NOT a circle feature: they are sealed under their own
  // per-session key and feed one outsider each. This keeps every live one fed for
  // as long as the dashboard is open, independent of the circle or its precision
  // mode (the sharer opted into a share explicitly, per session, with a deadline).
  useShareReporter();

  // Circle devices → platform map, so web devices get a "PC" badge on the map.
  const devices = useQuery({
    queryKey: ['devices', selected?.id],
    queryFn: () => api.circleDevices(selected!.id),
    enabled: !!selected,
  });
  useEffect(() => {
    if (devices.data) useDevices.getState().setDevices(devices.data);
  }, [devices.data]);

  // Members carry their per-circle profile sealed under K_c. Decrypt each with
  // the keyring and populate the profiles store (email always kept as fallback),
  // so the panel and the map markers show the nickname + avatar.
  const members = useQuery({
    queryKey: ['members', selected?.id],
    queryFn: () => api.members(selected!.id),
    enabled: !!selected,
  });
  useEffect(() => {
    if (!members.data) return;
    useProfiles.getState().setProfiles(
      members.data.map((m) => {
        const p = m.profile_enc ? openProfile(m.profile_enc, keyring) : null;
        return {
          userId: m.user_id,
          email: m.email,
          nick: p?.nick,
          avatar: p?.avatar,
          // Server metadata, so the map can grey out a member who paused sharing
          // instead of leaving a stale marker that still looks live.
          precisionMode: m.precision_mode,
        };
      }),
    );
  }, [members.data, keyring]);

  // Places load at the CIRCLE level — not lazily when the Places panel opens — so
  // every member sees the circle's geofences on the map and GeofenceFeed can
  // detect arrivals for ANYONE. A place added by one member is thus tracked for
  // all: it shows up on every member's map and fires an arrival when anyone
  // enters it (the relay in GeofenceFeed announces the mover's own crossings).
  const placesQ = useQuery({
    queryKey: ['places', selected?.id],
    queryFn: () => api.listPlaces(selected!.id),
    enabled: !!selected && keyring.length > 0,
  });
  useEffect(() => {
    if (!placesQ.data) return;
    const opened = placesQ.data
      .map((dto) => openPlace(dto, keyring))
      .filter((p): p is Place => p !== null);
    usePlaces.getState().setAll(opened);
  }, [placesQ.data, keyring]);

  // The current user's own decrypted profile, to pre-fill the profile dialog.
  const myUserId = qc.getQueryData<UserDTO>(['me'])?.id;
  const myProfile = useMemo(() => {
    const mine = members.data?.find((m) => m.user_id === myUserId);
    return mine?.profile_enc ? openProfile(mine.profile_enc, keyring) : null;
  }, [members.data, myUserId, keyring]);

  // Decrypt EVERY circle's name (each under its own key) for the switcher list,
  // not just the selected one. Keys are local (IndexedDB), so this is cheap.
  useEffect(() => {
    let cancel = false;
    (async () => {
      const list = circles.data;
      if (!list) return;
      const entries = await Promise.all(
        list.map(async (c) => {
          const ring = await keystore.loadCircleKeys(c.id);
          const key = ring.length ? ring[ring.length - 1] : null;
          return [c.id, decodeName(c.name_enc, key, t('dashboard.circleFallback'))] as const;
        }),
      );
      if (!cancel) setCircleNames(Object.fromEntries(entries));
    })();
    return () => {
      cancel = true;
    };
  }, [circles.data, t]);

  async function rotateKey() {
    if (!selected) return;
    await keyManager.rotateKey(selected.id);
    setKeyring(await keystore.loadCircleKeys(selected.id));
    await qc.invalidateQueries({ queryKey: ['circles'] });
  }

  // Removing a member does NOT take back the K_c they already hold (v1 has no
  // forward secrecy), so they could still read future data. Offer the re-key
  // right where it matters instead of hoping the owner finds the rotate button.
  async function promptRotateAfterRemoval() {
    if (!selected || selected.role !== 'owner') return;
    if (!confirm(t('members.rotateAfterRemove'))) return;
    await rotateKey();
  }

  async function createCircle() {
    const fallbackName = t('dashboard.prompt.nameCircleDefault');
    const name = prompt(t('dashboard.prompt.nameCircle'), fallbackName) ?? fallbackName;
    const key = randomCircleKey();
    const nameEnc = toBase64(sealFramed(new TextEncoder().encode(name), key));
    const circle = await api.createCircle(nameEnc, 7);
    await keystore.saveCircleKey(circle.id, key);
    await qc.invalidateQueries({ queryKey: ['circles'] });
    setSelectedId(circle.id);
  }

  // Owner-only: re-seal a new name under K_c and PATCH it.
  async function renameCircle() {
    if (!selected || selected.role !== 'owner' || !circleKey) return;
    const name = prompt(t('circles.renamePrompt'), circleNames[selected.id] ?? '');
    if (name === null) return;
    const trimmed = name.trim();
    if (!trimmed) return;
    const nameEnc = toBase64(sealFramed(new TextEncoder().encode(trimmed), circleKey));
    await api.renameCircle(selected.id, nameEnc);
    setCircleNames((m) => ({ ...m, [selected.id]: trimmed }));
    await qc.invalidateQueries({ queryKey: ['circles'] });
  }

  // Leave immediately. A sole owner gets 409 → offer to delete the circle.
  async function leaveCircle() {
    if (!selected) return;
    if (!confirm(t('circles.leaveConfirm'))) return;
    try {
      await api.leaveCircle(selected.id);
    } catch (err) {
      if (err instanceof ApiError && err.status === 409) {
        if (!confirm(t('circles.soleOwner'))) return;
        await api.deleteCircle(selected.id);
      } else {
        throw err;
      }
    }
    setSelectedId(null); // fall back to the first remaining circle (or empty state)
    await qc.invalidateQueries({ queryKey: ['circles'] });
  }

  // Owner-only: delete the circle for everyone.
  async function deleteCircleAction() {
    if (!selected || selected.role !== 'owner') return;
    if (!confirm(t('circles.deleteConfirm', { name: circleNames[selected.id] ?? '' }))) return;
    await api.deleteCircle(selected.id);
    setSelectedId(null);
    await qc.invalidateQueries({ queryKey: ['circles'] });
  }

  async function setPrecision(mode: PrecisionMode) {
    if (!selected) return;
    await api.setPrecision(selected.id, mode);
    await qc.invalidateQueries({ queryKey: ['circles'] });
    // The members list carries precision_mode, which is what greys a paused
    // member's marker — without this the map keeps showing the old state.
    await qc.invalidateQueries({ queryKey: ['members', selected.id] });
  }

  async function raiseSos() {
    if (!selected || !circleKey) return;
    const msg = prompt(t('dashboard.prompt.sos'), '');
    if (msg === null) return; // cancelled
    // Cap the message so the sealed payload stays within one 256-byte pad block
    // (keeps its ciphertext length in the common bucket — see THREAT_MODEL).
    const ct = sealSos({ msg: msg.trim().slice(0, 160) || undefined, ts: Date.now() }, circleKey);
    await api.createSos(selected.id, ct);
    await qc.invalidateQueries({ queryKey: ['sos', selected.id] });
  }

  function openPanel(p: Panel) {
    useMapDraft.getState().cancel();
    setPanel((cur) => (cur === p ? 'none' : p));
  }

  // "Recenter on me": fly to THIS user's own freshest fix (across their devices).
  // Reads the stores at click time, so it always uses the latest position without
  // re-subscribing the component.
  function recenterOnMe() {
    if (!myUserId) return;
    const devices = useDevices.getState().devices;
    const positions = usePositions.getState().positions;
    let best: MemberPosition | null = null;
    for (const p of Object.values(positions)) {
      if (devices[p.deviceId]?.userId === myUserId && (!best || p.capturedAt > best.capturedAt)) best = p;
    }
    if (best) useMapFocus.getState().focus(best.lng, best.lat);
  }

  if (circles.isLoading) {
    return <div className="grid min-h-screen place-items-center text-ink-soft">{t('common.loading')}</div>;
  }

  if (!selected) {
    return <StartChoice onCreate={createCircle} />;
  }

  return (
    <div className="relative h-screen w-screen overflow-hidden">
      <MapView />

      {/* Top bar */}
      <header className="pointer-events-none absolute inset-x-0 top-0 z-30 flex items-center gap-2 p-3 md:items-start md:p-0">
        <CircleSwitcher
          circles={circles.data ?? []}
          selected={selected}
          names={circleNames}
          onSelect={setSelectedId}
          onManage={() => setShowCircles(true)}
          onRename={renameCircle}
          onLeave={leaveCircle}
          onDelete={deleteCircleAction}
          onCreate={createCircle}
        />
        <div className="flex-1" />
        <div className="pointer-events-auto flex max-w-[calc(100vw-1.5rem)] flex-wrap items-center justify-end gap-1 rounded-2xl bg-surface/95 p-1 shadow-md backdrop-blur md:max-w-none md:flex-nowrap md:[border-radius:0_0_0_1rem]">
          <button title={t('dashboard.tip.places')} onClick={() => openPanel('places')} className={`rounded-full p-2 hover:bg-black/5 ${panel === 'places' ? 'text-primary' : ''}`}><MapPin size={18} /></button>
          <div className="mx-0.5 h-5 w-px bg-black/10" />
          <button title={t('profile.tooltip')} onClick={() => setShowProfile(true)} disabled={!circleKey} className="rounded-full p-2 hover:bg-black/5 disabled:opacity-40"><UserPen size={18} /></button>
          <button title={t('dashboard.tip.whoSeesMe')} onClick={() => setShowWho(true)} className="rounded-full p-2 hover:bg-black/5"><Eye size={18} /></button>
          <button title={t('dashboard.tip.verify')} onClick={() => setShowVerify(true)} className="rounded-full p-2 hover:bg-black/5"><ShieldCheck size={18} /></button>
          {selected.role === 'owner' && (
            <button title={t('dashboard.tip.rotateKey')} onClick={rotateKey} className="rounded-full p-2 hover:bg-black/5"><KeyRound size={18} /></button>
          )}
          <button title={t('dashboard.tip.invite')} onClick={() => setShowInvite(true)} className="rounded-full p-2 hover:bg-black/5"><UserPlus size={18} /></button>
          <button title={t('dashboard.tip.share')} onClick={() => setShowShare(true)} className="rounded-full p-2 hover:bg-black/5"><Radio size={18} /></button>
          <button title={t('dashboard.tip.preferences')} onClick={() => setShowPrefs(true)} className="rounded-full p-2 hover:bg-black/5"><Settings size={18} /></button>
          <button title={t('dashboard.tip.signOut')} onClick={() => doLogout().then(() => qc.invalidateQueries({ queryKey: ['me'] }))} className="rounded-full p-2 hover:bg-black/5"><LogOut size={18} /></button>
        </div>
      </header>

      {/* SOS banner (top-centre, above everything) */}
      <div className="pointer-events-none absolute left-1/2 top-16 z-40 w-[26rem] max-w-[92vw] -translate-x-1/2">
        <SosBanner circleId={selected.id} keyring={keyring} />
      </div>

      {/* Precision + no-key banner */}
      {/* Clears the members panel on desktop: it docks flush-left at 20rem wide
          from top-16, so anything at left-3 top-16 sits UNDER it and can't even
          be clicked (that hid the Precise/City/Paused control entirely). On
          mobile the panel is a bottom sheet, so left-3 is free. */}
      <div className="absolute left-3 top-28 z-10 flex flex-col gap-2 md:left-[21rem] md:top-16">
        {/* Live-connection health + how stale the map may be. Client-inferred (an
            offline server can't say it's offline), non-alarming, and generic — the
            web client doesn't know whether it's talking to the cloud or a
            self-hosted box. Hidden while connected. */}
        <OfflineBanner />
        <div className="pointer-events-auto inline-flex rounded-full bg-surface/95 p-1 text-sm shadow-md backdrop-blur">
          {(['precise', 'city', 'paused'] as PrecisionMode[]).map((m) => (
            <button
              key={m}
              onClick={() => setPrecision(m)}
              className={`rounded-full px-4 py-2 md:px-3 md:py-1 ${selected.precision_mode === m ? 'bg-primary text-white' : 'text-ink-soft'}`}
            >
              {t(`common.precision.${m}`)}
            </button>
          ))}
        </div>
        {!circleKey && (
          <div className="max-w-xs rounded-xl bg-amber-50 p-3 text-sm text-amber-900 shadow" role="alert">
            {t('dashboard.noKey')}
          </div>
        )}
        {/* A live share shows a NON-member where you are — it never gets to run
            silently just because the dialog is closed. */}
        <ShareBanner onOpen={() => setShowShare(true)} />
      </div>

      {/* Right-side panel (Places) */}
      {panel === 'places' && (
        <div className="absolute inset-x-3 top-16 z-20 md:inset-x-auto md:right-3">
          <PlacesPanel circleId={selected.id} keyring={keyring} onClose={() => openPanel('places')} />
        </div>
      )}

      {/* Map controls: reset the map to north-up, and recenter on my own marker.
          A small stack floating just above the SOS button on both mobile and
          desktop. */}
      <div className="fixed bottom-[calc(16vh+5.75rem)] right-3 z-30 flex flex-col gap-2 md:bottom-32 md:right-4">
        <button
          title={t('dashboard.tip.northUp')}
          aria-label={t('dashboard.tip.northUp')}
          onClick={() => useMapFocus.getState().resetNorth()}
          className="grid h-11 w-11 place-items-center rounded-full bg-surface/95 text-ink shadow-md backdrop-blur transition-colors hover:bg-black/5"
        >
          <Compass size={20} />
        </button>
        <button
          title={t('dashboard.tip.recenter')}
          aria-label={t('dashboard.tip.recenter')}
          onClick={recenterOnMe}
          className="grid h-11 w-11 place-items-center rounded-full bg-surface/95 text-ink shadow-md backdrop-blur transition-colors hover:bg-black/5"
        >
          <LocateFixed size={20} />
        </button>
      </div>

      {/* SOS — a floating action, not a toolbar icon: it is the one control that
          must be findable and hittable in a panic, so it gets the bottom-right
          corner to itself. Cleared of the members panel (a bottom sheet up to
          45vh on mobile, left-docked on desktop) and of the map attribution. */}
      <button
        title={t('dashboard.tip.raiseSos')}
        aria-label={t('dashboard.tip.raiseSos')}
        onClick={raiseSos}
        disabled={!circleKey}
        className="fixed bottom-[calc(16vh+1rem)] right-3 z-30 grid h-14 w-14 place-items-center rounded-full bg-danger text-white shadow-lg transition-transform hover:scale-105 active:scale-95 disabled:opacity-40 disabled:hover:scale-100 md:bottom-12 md:right-4 md:h-16 md:w-16"
      >
        <Siren size={26} />
      </button>

      {/* Members + geofence presence */}
      <MobileSheet>
        <MembersPanel
          circleId={selected.id}
          isOwner={selected.role === 'owner'}
          onRemoved={promptRotateAfterRemoval}
        />
        <GeofenceFeed circleId={selected.id} circleKey={circleKey} />
      </MobileSheet>

      {showInvite && circleKey && (
        <InviteDialog circleId={selected.id} circleKey={circleKey} onClose={() => setShowInvite(false)} />
      )}
      {/* No circleKey gate: a live share seals under its OWN key, so it works even
          on a browser that never received K_c. */}
      {showShare && <ShareDialog onClose={() => setShowShare(false)} />}
      {showProfile && circleKey && (
        <ProfileDialog
          circleId={selected.id}
          circleKey={circleKey}
          currentProfile={myProfile ?? undefined}
          onClose={() => setShowProfile(false)}
        />
      )}
      {showWho && <WhoSeesMe circleName={decodeName(selected.name_enc, circleKey, t('dashboard.circleFallback'))} onClose={() => setShowWho(false)} />}
      {showVerify && <VerifyDevices circleId={selected.id} onClose={() => setShowVerify(false)} />}
      {showPrefs && <Preferences onClose={() => setShowPrefs(false)} />}
      {showCircles && (
        <CirclesDashboard
          circles={circles.data ?? []}
          names={circleNames}
          onClose={() => setShowCircles(false)}
        />
      )}
    </div>
  );
}

function WhoSeesMe({ circleName, onClose }: { circleName: string; onClose: () => void }) {
  const { t } = useTranslation();
  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/40 p-4" onClick={onClose}>
      <div className="w-full max-w-sm rounded-2xl bg-surface p-6 shadow-xl" onClick={(e) => e.stopPropagation()}>
        <h2 className="text-lg font-bold">{t('dashboard.who.title')}</h2>
        <p className="mt-3 text-ink-soft">
          <Trans i18nKey="dashboard.who.body" values={{ circleName }} components={{ b: <strong /> }} />
        </p>
        <button onClick={onClose} className="mt-5 w-full rounded-full bg-primary py-2.5 font-semibold text-white">{t('common.gotIt')}</button>
      </div>
    </div>
  );
}
