/// Honest presentation of a fix's REPORTED uncertainty.
///
/// Every browser fix carries `GeolocationCoordinates.accuracy` — the radius in
/// metres of the 95% confidence circle around the reported point. We decode it
/// (pingDecode: `accuracy: fix.acc`) and used to drop it on the floor, drawing a
/// ±500 m Wi-Fi guess as exactly the same confident dot as a ±5 m GPS fix. A
/// desktop PC has no GPS: it is located from the Wi-Fi APs it can see, which is
/// typically 20-100 m and can be several hundred. "The map shows me where I am
/// not" is the honest reading of that dot — the dot was never the truth, the
/// circle around it is.
///
/// These helpers are pure so they can be tested; the map layer that consumes
/// them (MapView) is not unit-tested.

/// Below this radius we do NOT draw the accuracy circle.
///
/// Two reasons, both about not drawing noise. (1) Scale: the member marker is
/// itself 44 px across, so a circle under ~25 m hides
/// beneath the marker at any zoom you would actually read it at — at z14 one
/// pixel is ~7 m of ground, so 25 m is a 3-4 px ring. (2) Meaning: ~5-20 m is
/// simply as good as consumer positioning gets, so a circle there communicates
/// nothing a viewer could act on. At that scale the dot IS the truth.
export const ACCURACY_MIN_DRAW_M = 25;

/// Above this radius a fix is bad enough to say so in words. ~200 m is roughly
/// where a Wi-Fi-located desktop stops agreeing with the block you are on, which
/// is the complaint this exists to answer.
export const ACCURACY_POOR_M = 200;

/// A number we can believe: present, finite and positive. Anything else (absent
/// `acc` from an older reporter, 0, NaN from a mangled payload) means "unknown",
/// and unknown must never render as a confident zero-radius circle.
export function isUsableAccuracy(accuracy: number | null | undefined): accuracy is number {
  return typeof accuracy === 'number' && Number.isFinite(accuracy) && accuracy > 0;
}

/// Whether to draw the accuracy circle for this fix: skipped when the accuracy is
/// absent (we cannot claim a radius we were not told) and when it is small enough
/// to be meaningless (see ACCURACY_MIN_DRAW_M).
export function shouldDrawAccuracy(accuracy: number | null | undefined): accuracy is number {
  return isUsableAccuracy(accuracy) && accuracy >= ACCURACY_MIN_DRAW_M;
}

/// Whether this fix is vague enough to warn its OWNER about in plain language.
export function isPoorAccuracy(accuracy: number | null | undefined): accuracy is number {
  return isUsableAccuracy(accuracy) && accuracy > ACCURACY_POOR_M;
}

/// The number + unit of an accuracy radius, split so the caller can put them
/// through i18n. Metres up to a kilometre (whole metres — a decimetre on a Wi-Fi
/// guess would be false precision), kilometres beyond, to one decimal in the
/// active locale's notation ("1.2" / "1,2").
export function accuracyParts(
  accuracy: number,
  lang: string,
): { value: string; unit: 'm' | 'km' } {
  const metres = Math.round(accuracy);
  // Rounding decides the unit, so 999.6 m reads "1 km" rather than "1000 m".
  if (metres < 1000) return { value: String(metres), unit: 'm' };
  const km = new Intl.NumberFormat(lang, { maximumFractionDigits: 1 }).format(metres / 1000);
  return { value: km, unit: 'km' };
}

/// Minimal shape of i18next's `t` — enough to format, without coupling this
/// module to react-i18next.
type Translate = (key: string, vars?: Record<string, string>) => string;

/// The user-visible accuracy label: "±40 m" / "±1,2 км".
export function formatAccuracy(accuracy: number, lang: string, t: Translate): string {
  const { value, unit } = accuracyParts(accuracy, lang);
  return t('members.accuracy', { value, unit: t(`common.unit.${unit}`) });
}
