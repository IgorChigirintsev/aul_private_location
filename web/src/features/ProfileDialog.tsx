import { useCallback, useState } from 'react';
import type { ChangeEvent } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { X } from 'lucide-react';
import Cropper from 'react-easy-crop';
import type { Area, Point } from 'react-easy-crop';
import 'react-easy-crop/react-easy-crop.css';

import { api } from '../data/api';
import { fromBase64 } from '../crypto/aulCrypto';
import { sealProfile } from '../data/profileCodec';

/// The cropped avatar is downscaled to this square, so a member's picture stays
/// tiny inside the sealed blob regardless of the source photo's size.
const AVATAR_PX = 128;
/// Client-side guard well under the server's 128 KiB limit for the sealed blob.
const MAX_PROFILE_BYTES = 100 * 1024;

function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error('image load failed'));
    img.src = src;
  });
}

/// Draws the user-chosen crop rectangle onto a 128×128 canvas and returns it as a
/// JPEG data URL. The source is a data URL (same-origin, untainted), so the
/// canvas can be exported.
async function cropToDataUrl(src: string, area: Area): Promise<string> {
  const img = await loadImage(src);
  const canvas = document.createElement('canvas');
  canvas.width = AVATAR_PX;
  canvas.height = AVATAR_PX;
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('no 2d context');
  ctx.drawImage(img, area.x, area.y, area.width, area.height, 0, 0, AVATAR_PX, AVATAR_PX);
  return canvas.toDataURL('image/jpeg', 0.85);
}

/// Sets the caller's own per-circle profile: a nickname (shown instead of the
/// email) and a self-cropped avatar. Everything is sealed under K_c before it
/// leaves the browser — the server only ever relays ciphertext.
export function ProfileDialog({
  circleId,
  circleKey,
  currentProfile,
  onClose,
}: {
  circleId: string;
  circleKey: Uint8Array;
  currentProfile?: { nick?: string; avatar?: string };
  onClose: () => void;
}) {
  const { t } = useTranslation();
  const qc = useQueryClient();

  const [nick, setNick] = useState(currentProfile?.nick ?? '');
  // The saved avatar (data URL) shown as the preview until a new photo is cropped.
  const [avatar, setAvatar] = useState<string | undefined>(currentProfile?.avatar);
  // A freshly chosen photo (data URL) being cropped; null when not cropping.
  const [fileSrc, setFileSrc] = useState<string | null>(null);
  const [crop, setCrop] = useState<Point>({ x: 0, y: 0 });
  const [zoom, setZoom] = useState(1);
  const [croppedAreaPixels, setCroppedAreaPixels] = useState<Area | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const onCropComplete = useCallback((_area: Area, pixels: Area) => {
    setCroppedAreaPixels(pixels);
  }, []);

  function onFile(e: ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    e.target.value = ''; // allow re-picking the same file later
    if (!file) return;
    setError(null);
    const reader = new FileReader();
    reader.onload = () => {
      if (typeof reader.result !== 'string') {
        setError(t('profile.imageError'));
        return;
      }
      setFileSrc(reader.result);
      setCrop({ x: 0, y: 0 });
      setZoom(1);
      setCroppedAreaPixels(null);
    };
    reader.onerror = () => setError(t('profile.imageError'));
    reader.readAsDataURL(file);
  }

  function removeAvatar() {
    setAvatar(undefined);
    setFileSrc(null);
    setCroppedAreaPixels(null);
    setError(null);
  }

  async function save() {
    setSaving(true);
    setError(null);
    try {
      let nextAvatar = avatar;
      if (fileSrc && croppedAreaPixels) {
        nextAvatar = await cropToDataUrl(fileSrc, croppedAreaPixels);
      }
      const b64 = sealProfile({ nick: nick.trim(), avatar: nextAvatar }, circleKey);
      if (fromBase64(b64).length > MAX_PROFILE_BYTES) {
        setError(t('profile.tooLarge'));
        setSaving(false);
        return;
      }
      await api.setProfile(circleId, b64);
      await qc.invalidateQueries({ queryKey: ['members', circleId] });
      onClose();
    } catch {
      setError(t('profile.saveError'));
      setSaving(false);
    }
  }

  const initial = (nick.trim().slice(0, 1) || '?').toUpperCase();

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/40 p-4" onClick={onClose}>
      <div
        className="w-full max-w-sm rounded-2xl bg-surface p-6 shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-bold">{t('profile.title')}</h2>
          <button onClick={onClose} aria-label={t('common.close')}><X size={20} /></button>
        </div>

        <label htmlFor="profile-nick" className="mt-4 block text-sm font-medium">
          {t('profile.nickname')}
        </label>
        <input
          id="profile-nick"
          value={nick}
          onChange={(e) => setNick(e.target.value)}
          maxLength={40}
          placeholder={t('profile.nicknamePlaceholder')}
          className="mt-1 w-full rounded-lg border border-line bg-bg px-3 py-2 text-sm"
        />

        <div className="mt-4 text-sm font-medium">{t('profile.avatar')}</div>
        {fileSrc ? (
          <>
            <div className="relative mt-2 h-56 overflow-hidden rounded-xl bg-black/80">
              <Cropper
                image={fileSrc}
                crop={crop}
                zoom={zoom}
                aspect={1}
                cropShape="round"
                showGrid={false}
                onCropChange={setCrop}
                onZoomChange={setZoom}
                onCropComplete={onCropComplete}
                disableAutomaticStylesInjection
              />
            </div>
            <label htmlFor="profile-zoom" className="mt-3 block text-xs text-ink-soft">
              {t('profile.zoom')}
            </label>
            <input
              id="profile-zoom"
              type="range"
              min={1}
              max={3}
              step={0.01}
              value={zoom}
              onChange={(e) => setZoom(Number(e.target.value))}
              className="w-full accent-primary"
            />
          </>
        ) : (
          <div className="mt-2 flex items-center gap-3">
            {avatar ? (
              <img src={avatar} alt="" className="h-16 w-16 rounded-full object-cover" />
            ) : (
              <div className="grid h-16 w-16 place-items-center rounded-full bg-primary/10 text-xl font-semibold text-primary">
                {initial}
              </div>
            )}
            <label className="cursor-pointer rounded-full border border-line px-3 py-1.5 text-sm font-medium hover:bg-black/5">
              {avatar ? t('profile.changePhoto') : t('profile.choosePhoto')}
              <input type="file" accept="image/*" className="hidden" onChange={onFile} />
            </label>
          </div>
        )}

        {(avatar || fileSrc) && (
          <button onClick={removeAvatar} className="mt-3 text-sm text-danger hover:underline">
            {t('profile.removePhoto')}
          </button>
        )}

        {error && <p className="mt-3 text-sm text-danger">{error}</p>}

        <div className="mt-5 flex gap-2">
          <button
            onClick={onClose}
            className="flex-1 rounded-full border border-line py-2.5 font-semibold hover:bg-black/5"
          >
            {t('profile.cancel')}
          </button>
          <button
            onClick={save}
            disabled={saving}
            className="flex-1 rounded-full bg-primary py-2.5 font-semibold text-white disabled:opacity-50"
          >
            {saving ? t('profile.saving') : t('profile.save')}
          </button>
        </div>
      </div>
    </div>
  );
}
