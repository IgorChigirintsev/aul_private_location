import { batteryColor } from '../design/tokens';
import type { MemberPosition } from '../data/types';

/// Builds the DOM element for a member marker: a round avatar with a battery
/// ring, and a pulse on fresh updates.
///
/// Uncertainty is NOT drawn here. It used to look like it was — a translucent
/// disc called an "accuracy halo" that was a fixed 72 px and knew nothing about
/// any fix. The real thing is a ground-radius circle on the map itself; see
/// map/accuracy.ts.
export function createMarkerElement(label: string): HTMLDivElement {
  const el = document.createElement('div');
  el.className = 'aul-marker';
  el.innerHTML = `
    <div class="aul-marker__tag" hidden></div>
    <div class="aul-marker__ring">
      <div class="aul-marker__avatar"></div>
    </div>
    <div class="aul-marker__batt"></div>`;
  // Set the letter via textContent (never innerHTML) so a member-chosen nickname
  // can't inject markup.
  const av = el.querySelector<HTMLElement>('.aul-marker__avatar');
  if (av) av.textContent = label;
  return el;
}

/// Sets the marker's avatar to a cropped image (a data URL) or, when null,
/// restores the fallback letter. Keeps the round avatar shape from the CSS.
export function setMarkerAvatar(el: HTMLElement, dataUrl: string | null, label: string): void {
  const av = el.querySelector<HTMLElement>('.aul-marker__avatar');
  if (!av) return;
  if (dataUrl) {
    av.textContent = '';
    av.style.backgroundImage = `url("${dataUrl}")`;
    av.style.backgroundSize = 'cover';
    av.style.backgroundPosition = 'center';
  } else {
    av.style.backgroundImage = '';
    av.textContent = label;
  }
}

/// Greys a marker out to show the member has PAUSED sharing. Their reporter stops
/// sending, so the marker would otherwise sit at its last position looking exactly
/// like a live one — the pin stays put (that IS where they stopped), but it reads
/// as "not live" at a glance.
export function setMarkerPaused(el: HTMLElement, paused: boolean): void {
  el.classList.toggle('aul-marker--paused', paused);
}

/// Dims a marker to show its last fix has gone STALE — the device stopped
/// reporting long enough ago (data/freshness.ts) that we can no longer claim this
/// is where it is now. Unlike "paused" (a deliberate, server-reported state) this
/// is client-inferred purely from the fix's age, so a device that silently drops
/// off — dead battery, no signal, server unreachable — stops looking live instead
/// of sitting on the map with a confident dot.
export function setMarkerStale(el: HTMLElement, stale: boolean): void {
  el.classList.toggle('aul-marker--stale', stale);
}

/// Marks a marker as raising an SOS: a red pulsing ring, so the person in
/// distress is unmistakable at a glance for everyone watching. Driven by the
/// active SOS events (which carry the raiser's device); cleared when the SOS is
/// resolved.
export function setMarkerSos(el: HTMLElement, sos: boolean): void {
  el.classList.toggle('aul-marker--sos', sos);
}

/// Shows/hides a small badge above the marker (e.g. "PC" for a web device, so a
/// member visible on both phone and computer is distinguishable on the map).
export function setMarkerTag(el: HTMLElement, tag: string | null): void {
  const t = el.querySelector<HTMLElement>('.aul-marker__tag');
  if (!t) return;
  if (tag) {
    t.textContent = tag;
    t.hidden = false;
  } else {
    t.textContent = '';
    t.hidden = true;
  }
}

/// Restarts the "just updated" pulse on a marker.
export function pulseMarker(el: HTMLElement): void {
  el.classList.remove('aul-marker--pulse');
  // reflow to restart the animation
  void el.offsetWidth;
  el.classList.add('aul-marker--pulse');
}

export function updateMarkerElement(el: HTMLElement, pos: MemberPosition, fresh: boolean): void {
  const ring = el.querySelector<HTMLElement>('.aul-marker__ring');
  const batt = el.querySelector<HTMLElement>('.aul-marker__batt');
  const pct = pos.battery ?? null;
  const color = batteryColor(pct);
  if (ring) {
    const deg = pct != null ? Math.round((pct / 100) * 360) : 360;
    ring.style.background = `conic-gradient(${color} ${deg}deg, rgba(0,0,0,0.08) ${deg}deg)`;
  }
  if (batt) {
    batt.textContent = pct != null ? `${pct}%` : '';
    batt.style.color = color;
  }
  if (fresh) pulseMarker(el);
}
