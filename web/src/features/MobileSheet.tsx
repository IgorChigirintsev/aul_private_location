import { useEffect, useRef, useState, type ReactNode } from 'react';

type Snap = 'peek' | 'half' | 'full';
/// The three resting heights, as fractions of the viewport — Google-Maps style.
const FRACTION: Record<Snap, number> = { peek: 0.16, half: 0.52, full: 0.9 };
const ORDER: Snap[] = ['peek', 'half', 'full'];

/// The dashboard's People/geofence panel. On the phone-web it is a bottom sheet
/// that can be DRAGGED between peek / half / full, or TAPPED on its handle to
/// toggle open↔closed — the map stays full-screen behind it. On desktop (md+) it
/// is the same left-docked panel as before, with none of the drag machinery.
export function MobileSheet({ children }: { children: ReactNode }) {
  const [isMobile, setIsMobile] = useState(
    () => typeof window !== 'undefined' && window.matchMedia('(max-width: 767px)').matches,
  );
  useEffect(() => {
    const mq = window.matchMedia('(max-width: 767px)');
    const on = () => setIsMobile(mq.matches);
    mq.addEventListener('change', on);
    return () => mq.removeEventListener('change', on);
  }, []);

  const [snap, setSnap] = useState<Snap>('peek');
  // Live height while a drag is in progress (null = resting at the snap point).
  const [dragH, setDragH] = useState<number | null>(null);
  const drag = useRef<{ startY: number; startH: number; moved: boolean } | null>(null);

  if (!isMobile) {
    // Height hugs the content (one member ⇒ a short card), capped at the space
    // between the top bar and the bottom edge so a long roster still scrolls
    // rather than running off-screen. Anchored at the top only — pinning BOTH
    // top and bottom (bottom-3 + top-16) is what forced the old full-height box.
    return (
      <aside className="absolute left-0 top-16 z-10 max-h-[calc(100vh-5rem)] w-80 overflow-y-auto bg-bg/95 shadow-[0_-8px_24px_rgba(0,0,0,0.08)] backdrop-blur [border-radius:0_1rem_1rem_0]">
        {children}
      </aside>
    );
  }

  const vh = window.innerHeight;
  const px = (f: number) => Math.round(f * vh);
  const height = dragH ?? px(FRACTION[snap]);

  const onDown = (e: React.PointerEvent) => {
    (e.target as HTMLElement).setPointerCapture(e.pointerId);
    drag.current = { startY: e.clientY, startH: height, moved: false };
  };
  const onMove = (e: React.PointerEvent) => {
    if (!drag.current) return;
    const dy = drag.current.startY - e.clientY; // dragging UP grows the sheet
    if (Math.abs(dy) > 6) drag.current.moved = true;
    setDragH(Math.min(px(FRACTION.full), Math.max(px(FRACTION.peek), drag.current.startH + dy)));
  };
  const onUp = () => {
    if (!drag.current) return;
    const tapped = !drag.current.moved;
    const h = dragH ?? height;
    drag.current = null;
    setDragH(null);
    if (tapped) {
      // A tap (no real drag) toggles open↔closed.
      setSnap((s) => (s === 'peek' ? 'half' : 'peek'));
      return;
    }
    // Snap to whichever resting height is closest to where the finger let go.
    let best: Snap = 'peek';
    let bestD = Infinity;
    for (const s of ORDER) {
      const d = Math.abs(px(FRACTION[s]) - h);
      if (d < bestD) {
        bestD = d;
        best = s;
      }
    }
    setSnap(best);
  };

  return (
    <aside
      className="absolute inset-x-0 bottom-0 z-10 flex flex-col rounded-t-2xl bg-bg/95 shadow-[0_-8px_24px_rgba(0,0,0,0.12)] backdrop-blur"
      style={{ height, transition: dragH == null ? 'height 0.25s ease' : 'none' }}
    >
      <div
        onPointerDown={onDown}
        onPointerMove={onMove}
        onPointerUp={onUp}
        style={{ touchAction: 'none' }}
        className="flex shrink-0 cursor-grab touch-none justify-center py-2.5 active:cursor-grabbing"
        role="button"
        aria-label="Resize panel"
      >
        <div className="h-1.5 w-10 rounded-full bg-black/20" />
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain">{children}</div>
    </aside>
  );
}
