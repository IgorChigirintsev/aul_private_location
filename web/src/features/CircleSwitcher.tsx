import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Check, ChevronDown, LayoutGrid, LogOut, Pencil, Plus, Trash2 } from 'lucide-react';

import type { CircleSummary } from '../data/types';

/// The circle "identity" pill in the top-left, doubled as a switcher: it lists
/// every circle the user belongs to (decrypted names), switches on click, and
/// offers the circles dashboard, rename (owner), leave, and create. Docked flush
/// to the top-left corner on desktop (matches the dashboard chrome).
export function CircleSwitcher({
  circles,
  selected,
  names,
  onSelect,
  onManage,
  onRename,
  onLeave,
  onDelete,
  onCreate,
}: {
  circles: CircleSummary[];
  selected: CircleSummary;
  names: Record<string, string>;
  onSelect: (id: string) => void;
  onManage: () => void;
  onRename: () => void;
  onLeave: () => void;
  onDelete: () => void;
  onCreate: () => void;
}) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const nameOf = (c: CircleSummary) => names[c.id] ?? t('dashboard.circleFallback');

  return (
    <div className="pointer-events-auto relative">
      <button
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="menu"
        aria-expanded={open}
        className="flex items-center gap-2 rounded-full bg-surface/95 px-4 py-2 shadow-md backdrop-blur transition-colors hover:bg-surface md:[border-radius:0_0_1rem_0]"
      >
        <span className="font-extrabold text-primary" style={{ fontFamily: 'var(--font-heading)' }}>
          Aul
        </span>
        <span className="text-ink-soft">·</span>
        <span className="max-w-[40vw] truncate font-medium sm:max-w-[16rem]">{nameOf(selected)}</span>
        <ChevronDown size={16} className={`text-ink-soft transition-transform ${open ? 'rotate-180' : ''}`} />
      </button>

      {open && (
        <>
          <div className="fixed inset-0 z-40" onClick={() => setOpen(false)} aria-hidden />
          <div
            role="menu"
            className="absolute left-0 top-full z-50 mt-1 w-64 max-w-[80vw] rounded-2xl border border-line bg-surface p-1.5 shadow-xl"
          >
            <div className="px-3 py-1.5 text-xs font-semibold uppercase tracking-wide text-ink-soft">
              {t('circles.yours')}
            </div>
            <div className="max-h-64 overflow-y-auto">
              {circles.map((c) => (
                <button
                  key={c.id}
                  role="menuitem"
                  onClick={() => {
                    onSelect(c.id);
                    setOpen(false);
                  }}
                  className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left hover:bg-black/5"
                >
                  <span className="flex-1 truncate">{nameOf(c)}</span>
                  {c.role === 'owner' && (
                    <span className="shrink-0 text-xs text-ink-soft">{t('circles.owner')}</span>
                  )}
                  {c.id === selected.id && <Check size={16} className="shrink-0 text-primary" />}
                </button>
              ))}
            </div>

            <div className="my-1 h-px bg-black/10" />

            <button
              role="menuitem"
              onClick={() => {
                setOpen(false);
                onManage();
              }}
              className="flex w-full items-center gap-2 rounded-lg px-3 py-2 hover:bg-black/5"
            >
              <LayoutGrid size={15} className="text-ink-soft" /> {t('circlesDash.open')}
            </button>

            {selected.role === 'owner' && (
              <button
                role="menuitem"
                onClick={() => {
                  setOpen(false);
                  onRename();
                }}
                className="flex w-full items-center gap-2 rounded-lg px-3 py-2 hover:bg-black/5"
              >
                <Pencil size={15} className="text-ink-soft" /> {t('circles.rename')}
              </button>
            )}
            <button
              role="menuitem"
              onClick={() => {
                setOpen(false);
                onLeave();
              }}
              className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-danger hover:bg-danger/10"
            >
              <LogOut size={15} /> {t('circles.leave')}
            </button>
            {selected.role === 'owner' && (
              <button
                role="menuitem"
                onClick={() => {
                  setOpen(false);
                  onDelete();
                }}
                className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-danger hover:bg-danger/10"
              >
                <Trash2 size={15} /> {t('circles.delete')}
              </button>
            )}
            <div className="my-1 h-px bg-black/10" />
            <button
              role="menuitem"
              onClick={() => {
                setOpen(false);
                onCreate();
              }}
              className="flex w-full items-center gap-2 rounded-lg px-3 py-2 hover:bg-black/5"
            >
              <Plus size={15} className="text-ink-soft" /> {t('circles.create')}
            </button>
          </div>
        </>
      )}
    </div>
  );
}
