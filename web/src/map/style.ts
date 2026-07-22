/// OpenFreeMap "positron" — muted light basemap, no API key, self-hostable.
/// Override with VITE_TILES_STYLE to point at a self-hosted style.
///
/// Shared by every map in the app (the circle map and the public live-share
/// viewer) so a self-hosting operator sets the tiles origin exactly once — and
/// so the CSP only ever has one tiles host to allow-list.
export const STYLE_URL =
  (import.meta.env.VITE_TILES_STYLE as string | undefined) ??
  'https://tiles.openfreemap.org/styles/positron';
