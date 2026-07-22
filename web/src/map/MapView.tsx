import { useEffect, useRef, useState } from 'react';
import maplibregl from 'maplibre-gl';
import type { FeatureCollection } from 'geojson';
import 'maplibre-gl/dist/maplibre-gl.css';

import { usePositions } from '../store/positions';
import { usePlaces } from '../store/places';
import { useMapDraft } from '../store/mapDraft';
import { useMapFocus } from '../store/mapFocus';
import { useSos } from '../store/sos';
import { useDevices } from '../store/devices';
import { memberDisplayName, useProfiles } from '../store/profiles';
import { colors, motion } from '../design/tokens';
import { isStale } from '../data/freshness';
import type { MemberPosition, Place } from '../data/types';
import { shouldDrawAccuracy } from './accuracy';
import { geoCircleRing } from './geoCircle';
import { STYLE_URL } from './style';
import {
  createMarkerElement,
  setMarkerAvatar,
  setMarkerPaused,
  setMarkerSos,
  setMarkerStale,
  setMarkerTag,
  updateMarkerElement,
} from './markerElement';

/// The device ids currently raising an SOS, so their markers pulse red. Read
/// live from the store each pass (marker creation, redecoration, SOS changes).
function sosDeviceSet(): Set<string> {
  const out = new Set<string>();
  for (const e of Object.values(useSos.getState().active)) {
    if (e.deviceId) out.add(e.deviceId);
  }
  return out;
}

interface Tracked {
  marker: maplibregl.Marker;
  el: HTMLDivElement;
  from: [number, number];
  to: [number, number];
  start: number;
  raf: number | null;
  /// Capture time of the fix this marker is showing, so a periodic sweep can dim
  /// it to "stale" once it ages out — even with no new position event.
  capturedAt: number;
}

/// Resolves the marker's presentation for a device by joining the devices store
/// (deviceId → userId + platform) with the profiles store (userId → nick/avatar).
/// Falls back to the email, then the device id, for the label letter.
function markerInfo(deviceId: string): {
  label: string;
  avatar: string | null;
  tag: string | null;
  paused: boolean;
} {
  const dev = useDevices.getState().devices[deviceId];
  const profile = dev ? useProfiles.getState().profiles[dev.userId] : undefined;
  const name = profile?.nick?.trim() || profile?.email || deviceId;
  return {
    label: name.slice(0, 1).toUpperCase(),
    avatar: profile?.avatar ?? null,
    tag: dev?.platform === 'web' ? 'PC' : null,
    // Current sharing state from the server, NOT the last ping's mode: a paused
    // reporter sends nothing, so the ping would keep claiming its old mode.
    paused: profile?.precisionMode === 'paused',
  };
}

function placesToCircles(places: Place[]): FeatureCollection {
  return {
    type: 'FeatureCollection',
    features: places.map((p) => ({
      type: 'Feature',
      properties: { id: p.id, name: p.name },
      geometry: { type: 'Polygon', coordinates: [geoCircleRing(p.lng, p.lat, p.radius)] },
    })),
  };
}

/// Each fix's REPORTED uncertainty as a true-ground-radius circle around its
/// marker. The browser tells us how vague every fix is and a Wi-Fi-located
/// desktop is routinely ±100 m or worse; drawing that as the same confident dot
/// as a ±5 m GPS fix is precisely the kind of claim this product refuses to make
/// elsewhere. Fixes with no accuracy, or one too small to mean anything, are
/// skipped rather than guessed at (see accuracy.ts for the thresholds).
function accuracyCircles(positions: MemberPosition[]): FeatureCollection {
  return {
    type: 'FeatureCollection',
    features: positions.flatMap((p) =>
      shouldDrawAccuracy(p.accuracy)
        ? [
            {
              type: 'Feature' as const,
              properties: { deviceId: p.deviceId, accuracy: p.accuracy },
              geometry: {
                type: 'Polygon' as const,
                coordinates: [geoCircleRing(p.lng, p.lat, p.accuracy)],
              },
            },
          ]
        : [],
    ),
  };
}

function createPlaceElement(): HTMLDivElement {
  const el = document.createElement('div');
  el.className = 'aul-place';
  el.style.cssText =
    'display:inline-flex;flex-direction:column;align-items:center;padding:2px 8px;' +
    'border-radius:9999px;background:rgba(21,94,74,0.92);color:#fff;font-size:11px;' +
    'font-weight:600;white-space:nowrap;line-height:1.25;' +
    'box-shadow:0 1px 4px rgba(0,0,0,0.25);transform:translateY(-2px)';
  el.append(document.createElement('span'), document.createElement('span'));
  (el.lastChild as HTMLSpanElement).style.cssText =
    'font-size:9px;font-weight:500;opacity:0.75';
  return el;
}

/// The place's E2EE name, with the OWNER's nickname as a second, quieter line.
/// The name comes out of the sealed blob; `createdBy` is server metadata resolved
/// through the profiles store. The owner line is dropped entirely when unknown,
/// so the pill stays a single line rather than showing an empty row.
function renderPlaceElement(el: HTMLElement, p: Place): void {
  const [nameEl, ownerEl] = el.childNodes as unknown as [HTMLSpanElement, HTMLSpanElement];
  nameEl.textContent = p.name;
  const owner = p.createdBy
    ? memberDisplayName(useProfiles.getState().profiles, p.createdBy)
    : null;
  ownerEl.textContent = owner ?? '';
  ownerEl.style.display = owner ? 'block' : 'none';
}

/// Full-screen live map. Renders animated member markers, encrypted places with
/// their geofence radii, and a draft place while editing — all from
/// client-decrypted stores (the server never sees coordinates).
export function MapView() {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<maplibregl.Map | null>(null);
  const tracked = useRef<Map<string, Tracked>>(new Map());
  const placeMarkers = useRef<Map<string, maplibregl.Marker>>(new Map());
  const didFit = useRef(false);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    if (!containerRef.current) return;
    const map = new maplibregl.Map({
      container: containerRef.current,
      style: STYLE_URL,
      center: [0, 20],
      zoom: 1.5,
      attributionControl: { compact: true },
    });
    // The +/- zoom buttons are a mouse affordance; on a touch screen pinch-zoom is
    // natural and the control only crowds the top-right toolbar. Add it for fine
    // pointers (desktop) only.
    if (window.matchMedia('(pointer: fine)').matches) {
      map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-right');
    }
    mapRef.current = map;
    // Test seam. The map is a WebGL canvas and MapLibre is an ES module with no
    // global handle, so an e2e run has no way to ask what was actually drawn — and
    // a screenshot cannot tell a 350 m accuracy circle from a smudge in the
    // basemap (it tried; it could not). Exposing the instance costs nothing: it is
    // the user's own map, holding nothing the page has not already rendered.
    (window as unknown as { __aulMap?: maplibregl.Map }).__aulMap = map;

    map.on('load', () => {
      // Added FIRST so it renders beneath the geofences and (being a canvas
      // layer) beneath every DOM marker: the uncertainty is context for the pin,
      // not the subject. A muted grey at a lighter weight than the geofences'
      // green keeps it readable as "haze" rather than as another place.
      map.addSource('accuracy', { type: 'geojson', data: emptyFC() });
      map.addLayer({ id: 'accuracy-fill', type: 'fill', source: 'accuracy', paint: { 'fill-color': colors.light.textSecondary, 'fill-opacity': 0.1 } });
      map.addLayer({ id: 'accuracy-line', type: 'line', source: 'accuracy', paint: { 'line-color': colors.light.textSecondary, 'line-width': 1, 'line-opacity': 0.28 } });

      map.addSource('geofences', { type: 'geojson', data: emptyFC() });
      map.addLayer({ id: 'geofence-fill', type: 'fill', source: 'geofences', paint: { 'fill-color': '#155E4A', 'fill-opacity': 0.08 } });
      map.addLayer({ id: 'geofence-line', type: 'line', source: 'geofences', paint: { 'line-color': '#155E4A', 'line-width': 1.5, 'line-opacity': 0.5 } });

      map.addSource('draft', { type: 'geojson', data: emptyFC() });
      map.addLayer({ id: 'draft-fill', type: 'fill', source: 'draft', paint: { 'fill-color': '#B4632A', 'fill-opacity': 0.1 } });
      map.addLayer({ id: 'draft-line', type: 'line', source: 'draft', paint: { 'line-color': '#B4632A', 'line-width': 2, 'line-dasharray': [2, 2] } });

      setReady(true);
    });

    // Click sets the draft place centre while the add/edit flow is active.
    map.on('click', (e) => {
      const draft = useMapDraft.getState();
      if (draft.active) draft.setCenter({ lat: e.lngLat.lat, lng: e.lngLat.lng });
    });

    return () => {
      map.remove();
      mapRef.current = null;
      setReady(false);
    };
  }, []);

  // Live member positions (existing behaviour): one animated marker per device.
  useEffect(() => {
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    const render = (positions: Record<string, MemberPosition>) => {
      const map = mapRef.current;
      if (!map) return;
      const entries = Object.values(positions);
      const sos = sosDeviceSet();

      for (const pos of entries) {
        const key = pos.deviceId;
        let t = tracked.current.get(key);
        const target: [number, number] = [pos.lng, pos.lat];

        const stale = isStale(pos.capturedAt);
        if (!t) {
          const info = markerInfo(key);
          const el = createMarkerElement(info.label);
          const marker = new maplibregl.Marker({ element: el, anchor: 'center' }).setLngLat(target).addTo(map);
          t = { marker, el, from: target, to: target, start: 0, raf: null, capturedAt: pos.capturedAt };
          tracked.current.set(key, t);
          // A fix that arrives already stale must not pulse as if it were live.
          updateMarkerElement(el, pos, !stale);
          setMarkerAvatar(el, info.avatar, info.label);
          setMarkerTag(el, info.tag);
          setMarkerPaused(el, info.paused);
          setMarkerStale(el, stale);
          setMarkerSos(el, sos.has(key));
        } else {
          const current = t.marker.getLngLat();
          t.from = [current.lng, current.lat];
          t.to = target;
          t.start = performance.now();
          t.capturedAt = pos.capturedAt;
          setMarkerStale(t.el, stale);
          setMarkerSos(t.el, sos.has(key));
          updateMarkerElement(t.el, pos, !stale);
          if (t.raf) cancelAnimationFrame(t.raf);
          if (reduce) {
            t.marker.setLngLat(target);
          } else {
            const step = (now: number) => {
              const p = Math.min(1, (now - t!.start) / motion.markerInterpolateMs);
              const lng = t!.from[0] + (t!.to[0] - t!.from[0]) * p;
              const lat = t!.from[1] + (t!.to[1] - t!.from[1]) * p;
              t!.marker.setLngLat([lng, lat]);
              if (p < 1) t!.raf = requestAnimationFrame(step);
            };
            t.raf = requestAnimationFrame(step);
          }
        }
      }

      // Rebuilt from every live fix on each pass — cheap, self-cleaning, and it
      // deliberately does not fight the marker interpolation above: the circle
      // snaps to the new fix while the marker glides to it over a second.
      // Undefined until the style has loaded; the next fix redraws it.
      (map.getSource('accuracy') as maplibregl.GeoJSONSource | undefined)?.setData(
        accuracyCircles(entries),
      );

      if (!didFit.current && entries.length > 0) {
        didFit.current = true;
        if (entries.length === 1) {
          map.easeTo({ center: [entries[0].lng, entries[0].lat], zoom: 14, duration: 600 });
        } else {
          const b = new maplibregl.LngLatBounds();
          for (const p of entries) b.extend([p.lng, p.lat]);
          map.fitBounds(b, { padding: 80, maxZoom: 15, duration: 600 });
        }
      }
    };

    render(usePositions.getState().positions);
    const unsub = usePositions.subscribe((s) => render(s.positions));
    // Re-decorate markers when the devices map or the profiles load/change: a
    // "PC" badge for web devices, plus each member's chosen avatar + nickname
    // initial — independent of position updates.
    const redecorate = () => {
      const sos = sosDeviceSet();
      for (const [deviceId, t] of tracked.current) {
        const info = markerInfo(deviceId);
        setMarkerAvatar(t.el, info.avatar, info.label);
        setMarkerTag(t.el, info.tag);
        setMarkerPaused(t.el, info.paused);
        setMarkerStale(t.el, isStale(t.capturedAt));
        setMarkerSos(t.el, sos.has(deviceId));
      }
    };
    const unsubDevices = useDevices.subscribe(redecorate);
    const unsubProfiles = useProfiles.subscribe(redecorate);
    // Pulse the raiser's marker the moment an SOS starts (or clear it on resolve),
    // without waiting for the next position fix.
    const unsubSos = useSos.subscribe(() => {
      const sos = sosDeviceSet();
      for (const [deviceId, t] of tracked.current) setMarkerSos(t.el, sos.has(deviceId));
    });
    // Age markers to "stale" on a timer: without new fixes the position store
    // never changes, so a device that quietly stopped reporting would otherwise
    // keep its confident dot forever. Re-evaluate freshness on the same 30s
    // cadence as the poll/geofence pass.
    const staleTimer = setInterval(() => {
      for (const t of tracked.current.values()) setMarkerStale(t.el, isStale(t.capturedAt));
    }, 30_000);
    return () => {
      unsub();
      unsubDevices();
      unsubProfiles();
      unsubSos();
      clearInterval(staleTimer);
    };
    // `ready` re-runs this once the style has loaded, so fixes that arrived
    // before it get their accuracy circle drawn (markers live in a ref, so the
    // second pass updates them rather than duplicating them).
  }, [ready]);

  // Places → geofence circles + labelled pins.
  useEffect(() => {
    if (!ready) return;
    const render = (places: Record<string, Place>) => {
      const map = mapRef.current;
      if (!map) return;
      const list = Object.values(places);
      (map.getSource('geofences') as maplibregl.GeoJSONSource | undefined)?.setData(placesToCircles(list));

      const live = new Set(list.map((p) => p.id));
      for (const [id, marker] of placeMarkers.current) {
        if (!live.has(id)) {
          marker.remove();
          placeMarkers.current.delete(id);
        }
      }
      for (const p of list) {
        const existing = placeMarkers.current.get(p.id);
        if (existing) {
          existing.setLngLat([p.lng, p.lat]);
          renderPlaceElement(existing.getElement(), p);
        } else {
          const el = createPlaceElement();
          renderPlaceElement(el, p);
          const marker = new maplibregl.Marker({ element: el, anchor: 'bottom' })
            .setLngLat([p.lng, p.lat])
            .addTo(map);
          placeMarkers.current.set(p.id, marker);
        }
      }
    };
    render(usePlaces.getState().places);
    const unsub = usePlaces.subscribe((s) => render(s.places));
    // Place labels name their owner out of the profiles store, which fills in
    // AFTER the members query resolves — without this the labels would keep the
    // ownerless text they were first drawn with.
    const unsubProfiles = useProfiles.subscribe(() => render(usePlaces.getState().places));
    return () => {
      unsub();
      unsubProfiles();
    };
  }, [ready]);

  // Store-driven map commands: fly-to-member (tap a row / "recenter on me") and
  // reset-north (the compass button). Each is gated on its own counter changing,
  // so the two never trip each other. `essential: true` runs even under
  // prefers-reduced-motion — these are direct responses to a tap, not decoration.
  useEffect(() => {
    let prevSeq = useMapFocus.getState().seq;
    let prevNorth = useMapFocus.getState().north;
    return useMapFocus.subscribe((s) => {
      const map = mapRef.current;
      if (!map) return;
      if (s.seq !== prevSeq) {
        prevSeq = s.seq;
        if (s.target) map.flyTo({ center: [s.target.lng, s.target.lat], zoom: 15, duration: 800, essential: true });
      }
      if (s.north !== prevNorth) {
        prevNorth = s.north;
        map.easeTo({ bearing: 0, pitch: 0, duration: 400, essential: true });
      }
    });
  }, []);

  // Draft place circle (add/edit flow).
  useEffect(() => {
    if (!ready) return;
    const render = (d: ReturnType<typeof useMapDraft.getState>) => {
      const map = mapRef.current;
      if (!map) return;
      const src = map.getSource('draft') as maplibregl.GeoJSONSource | undefined;
      if (!src) return;
      if (d.active && d.center) {
        src.setData({
          type: 'FeatureCollection',
          features: [{ type: 'Feature', properties: {}, geometry: { type: 'Polygon', coordinates: [geoCircleRing(d.center.lng, d.center.lat, d.radius)] } }],
        });
      } else {
        src.setData(emptyFC());
      }
    };
    render(useMapDraft.getState());
    return useMapDraft.subscribe(render);
  }, [ready]);

  // Fill the positioned parent. Inline style beats maplibre-gl.css's unlayered
  // `.maplibregl-map{position:relative}` which would otherwise collapse the map
  // to 0 height (see D-0033).
  return (
    <div ref={containerRef} data-testid="map" style={{ position: 'absolute', inset: 0 }} />
  );
}

function emptyFC(): FeatureCollection {
  return { type: 'FeatureCollection', features: [] };
}
