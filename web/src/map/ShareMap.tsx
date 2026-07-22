import { useEffect, useRef, useState } from 'react';
import maplibregl from 'maplibre-gl';
import type { FeatureCollection } from 'geojson';
import 'maplibre-gl/dist/maplibre-gl.css';

import { colors, motion } from '../design/tokens';
import { shouldDrawAccuracy } from './accuracy';
import { geoCircleRing } from './geoCircle';
import { createMarkerElement, pulseMarker } from './markerElement';
import { STYLE_URL } from './style';

/// A neutral glyph, not an initial: a live-share viewer is a stranger who is told
/// nothing about who this is beyond the point on the map.
const MARKER_GLYPH = '●';

/// The live-share map: exactly ONE marker, no stores, no circle data.
///
/// Deliberately not MapView — that map is wired to the dashboard's stores
/// (members, places, history, devices, profiles). This page is public and shows a
/// single decrypted point, so it stays a plain map with a single marker and keeps
/// the whole dashboard state graph out of the public bundle. The marker DOM/CSS
/// is shared (markerElement), so it looks like the rest of the app.
/// [accuracy] is the fix's own radius in metres, and it matters MORE here than on
/// the dashboard: a viewer opened this link to go and meet someone. A confident
/// dot over a ±350 m guess sends them to the wrong corner, and — being a stranger
/// with no other context — they have no way to know. Drawn under the same rules as
/// the dashboard so both maps say the same thing about the same fix.
export function ShareMap({
  lat,
  lng,
  accuracy,
}: {
  lat: number;
  lng: number;
  accuracy?: number;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<maplibregl.Map | null>(null);
  const markerRef = useRef<maplibregl.Marker | null>(null);
  const didFit = useRef(false);
  // State, not a ref: the draw effect must RE-RUN when the style finishes loading.
  // A ref would leave the `load` handler drawing with the values it closed over on
  // the first render — the wrong radius if a fix landed in between.
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
    map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-right');
    mapRef.current = map;
    map.on('load', () => {
      map.addSource('accuracy', { type: 'geojson', data: emptyFC() });
      map.addLayer({
        id: 'accuracy-fill',
        type: 'fill',
        source: 'accuracy',
        paint: { 'fill-color': colors.light.textSecondary, 'fill-opacity': 0.1 },
      });
      map.addLayer({
        id: 'accuracy-line',
        type: 'line',
        source: 'accuracy',
        paint: {
          'line-color': colors.light.textSecondary,
          'line-width': 1,
          'line-opacity': 0.28,
        },
      });
      setReady(true);
    });
    return () => {
      map.remove();
      mapRef.current = null;
      markerRef.current = null;
      didFit.current = false;
      setReady(false);
    };
  }, []);

  /// The haze for the current fix. Its own effect, keyed on `ready`, so a style
  /// that finishes loading after the first fix still draws the right radius.
  useEffect(() => {
    const map = mapRef.current;
    if (!map || !ready) return;
    const src = map.getSource('accuracy') as maplibregl.GeoJSONSource | undefined;
    src?.setData(
      shouldDrawAccuracy(accuracy)
        ? {
            type: 'FeatureCollection',
            features: [
              {
                type: 'Feature',
                properties: { accuracy },
                geometry: {
                  type: 'Polygon',
                  coordinates: [geoCircleRing(lng, lat, accuracy)],
                },
              },
            ],
          }
        : emptyFC(),
    );
  }, [ready, lat, lng, accuracy]);

  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    if (!markerRef.current) {
      markerRef.current = new maplibregl.Marker({
        element: createMarkerElement(MARKER_GLYPH),
        anchor: 'center',
      })
        .setLngLat([lng, lat])
        .addTo(map);
    } else {
      markerRef.current.setLngLat([lng, lat]);
    }
    pulseMarker(markerRef.current.getElement());

    // Snap to the first position, then follow: the viewer opened this link to
    // watch one person, so keeping them centred is the entire job.
    if (!didFit.current) {
      didFit.current = true;
      map.easeTo({ center: [lng, lat], zoom: 15, duration: 600 });
    } else {
      map.easeTo({ center: [lng, lat], duration: motion.markerInterpolateMs });
    }
  }, [lat, lng]);

  return <div ref={containerRef} data-testid="share-map" style={{ position: 'absolute', inset: 0 }} />;
}

function emptyFC(): FeatureCollection {
  return { type: 'FeatureCollection', features: [] };
}
