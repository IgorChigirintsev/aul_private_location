import { useEffect, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { MapPin, Pencil, Plus, Trash2, X } from 'lucide-react';

import { api } from '../data/api';
import { openPlace, sealPlace } from '../data/placeCodec';
import { usePlaces } from '../store/places';
import { useMapDraft } from '../store/mapDraft';
import { memberDisplayName, useProfiles } from '../store/profiles';
import type { Place } from '../data/types';

/// Places manager: lists the circle's encrypted places, and drives the add/edit
/// flow (click the map to set the centre, drag the slider for the geofence
/// radius). Names + coordinates are sealed with K_c before they leave the browser.
export function PlacesPanel({
  circleId,
  keyring,
  onClose,
}: {
  circleId: string;
  keyring: Uint8Array[];
  onClose: () => void;
}) {
  const { t } = useTranslation();
  const qc = useQueryClient();
  const key = keyring.length ? keyring[keyring.length - 1] : null;
  const placesQ = useQuery({
    queryKey: ['places', circleId],
    queryFn: () => api.listPlaces(circleId),
    enabled: keyring.length > 0,
  });
  const draft = useMapDraft();
  const [name, setName] = useState('');
  const [busy, setBusy] = useState(false);
  const places = usePlaces((s) => s.places);
  const profiles = useProfiles((s) => s.profiles);

  // Decrypt the fetched places into the shared store (drives map circles/pins).
  useEffect(() => {
    if (!placesQ.data) return;
    const opened = placesQ.data
      .map((dto) => openPlace(dto, keyring))
      .filter((p): p is Place => p !== null);
    usePlaces.getState().setAll(opened);
  }, [placesQ.data, keyring]);

  function startAdd() {
    setName('');
    draft.begin({ radius: 150 });
  }
  function startEdit(p: Place) {
    setName(p.name);
    draft.begin({ editId: p.id, center: { lat: p.lat, lng: p.lng }, radius: p.radius });
  }

  async function save() {
    if (!key || !draft.center || !name.trim()) return;
    setBusy(true);
    try {
      const ct = sealPlace({ name: name.trim(), lat: draft.center.lat, lng: draft.center.lng, radius: draft.radius }, key);
      if (draft.editId) {
        const current = places[draft.editId];
        await api.updatePlace(circleId, draft.editId, ct, current?.version ?? 1);
      } else {
        await api.createPlace(circleId, ct);
      }
      draft.cancel();
      setName('');
      await qc.invalidateQueries({ queryKey: ['places', circleId] });
    } finally {
      setBusy(false);
    }
  }

  async function remove(p: Place) {
    if (!confirm(t('places.confirmDelete', { name: p.name }))) return;
    await api.deletePlace(circleId, p.id);
    await qc.invalidateQueries({ queryKey: ['places', circleId] });
  }

  const list = Object.values(places).sort((a, b) => a.name.localeCompare(b.name));

  return (
    <div className="pointer-events-auto w-full rounded-2xl bg-surface/97 p-4 shadow-xl backdrop-blur md:w-80 md:max-w-[90vw]">
      <div className="flex items-center justify-between">
        <h2 className="flex items-center gap-2 font-bold"><MapPin size={18} className="text-primary" /> {t('places.heading')}</h2>
        <button onClick={onClose} className="rounded-full p-1 hover:bg-black/5"><X size={18} /></button>
      </div>

      {draft.active ? (
        <div className="mt-3 rounded-xl bg-black/[0.03] p-3">
          <input
            autoFocus
            value={name}
            maxLength={80}
            onChange={(e) => setName(e.target.value)}
            placeholder={t('places.namePlaceholder')}
            className="w-full rounded-lg border border-black/10 px-3 py-2 text-sm"
          />
          <p className="mt-2 text-xs text-ink-soft">
            {draft.center ? t('places.centreSet') : t('places.clickMap')}
          </p>
          <label className="mt-2 block text-xs text-ink-soft">
            {t('places.radiusLabel')} <strong>{draft.radius} {t('common.unit.m')}</strong>
            <input
              type="range" min={50} max={1000} step={10} value={draft.radius}
              onChange={(e) => draft.setRadius(Number(e.target.value))}
              className="mt-1 w-full"
            />
          </label>
          <div className="mt-2 flex gap-2">
            <button
              disabled={!draft.center || !name.trim() || busy}
              onClick={save}
              className="flex-1 rounded-full bg-primary py-2 text-sm font-semibold text-white disabled:opacity-40"
            >
              {draft.editId ? t('places.saveChanges') : t('places.addPlace')}
            </button>
            <button onClick={() => { draft.cancel(); setName(''); }} className="rounded-full px-3 py-2 text-sm text-ink-soft hover:bg-black/5">{t('common.cancel')}</button>
          </div>
        </div>
      ) : (
        <button onClick={startAdd} disabled={!key} className="mt-3 flex w-full items-center justify-center gap-2 rounded-full border border-primary/30 py-2 text-sm font-semibold text-primary hover:bg-primary/5 disabled:opacity-40">
          <Plus size={16} /> {t('places.addAPlace')}
        </button>
      )}

      <ul className="mt-3 max-h-64 space-y-1 overflow-y-auto">
        {list.length === 0 && !draft.active && (
          <li className="py-4 text-center text-sm text-ink-soft">{t('places.empty')}</li>
        )}
        {list.map((p) => (
          <li key={p.id} className="flex items-center gap-2 rounded-lg px-2 py-1.5 hover:bg-black/[0.03]">
            <MapPin size={15} className="shrink-0 text-primary" />
            <div className="min-w-0 flex-1">
              <div className="truncate text-sm font-medium">{p.name}</div>
              {/* The name above came out of the sealed blob; the owner is server
                  metadata (created_by) resolved through the profiles store. */}
              {p.createdBy && (
                <div className="truncate text-xs text-ink-soft">
                  {t('places.addedBy', { name: memberDisplayName(profiles, p.createdBy) })}
                </div>
              )}
            </div>
            <span className="shrink-0 text-xs text-ink-soft">{p.radius} {t('common.unit.m')}</span>
            <button onClick={() => startEdit(p)} className="rounded p-1 text-ink-soft hover:bg-black/5" title={t('places.edit')}><Pencil size={14} /></button>
            <button onClick={() => remove(p)} className="rounded p-1 text-danger hover:bg-danger/10" title={t('places.delete')}><Trash2 size={14} /></button>
          </li>
        ))}
      </ul>
    </div>
  );
}
