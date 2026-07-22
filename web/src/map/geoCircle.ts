/// A geographic circle (radius in METRES) as a GeoJSON polygon ring, so a radius
/// renders as true ground distance rather than a fixed number of pixels.
///
/// Lives in its own module because two maps need it and they must not import each
/// other: `MapView` (geofences, accuracy) is the dashboard and drags the whole
/// store graph behind it, while `ShareMap` is served to strangers on a public page
/// and deliberately keeps that graph out of its bundle (D-0051).
export function geoCircleRing(
  lng: number,
  lat: number,
  radiusM: number,
  steps = 64,
): number[][] {
  const ring: number[][] = [];
  const R = 6_371_000;
  const dLat = (radiusM / R) * (180 / Math.PI);
  const dLng = dLat / Math.cos((lat * Math.PI) / 180);
  for (let i = 0; i <= steps; i++) {
    const t = (i / steps) * 2 * Math.PI;
    ring.push([lng + dLng * Math.cos(t), lat + dLat * Math.sin(t)]);
  }
  return ring;
}
