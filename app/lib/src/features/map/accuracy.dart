import 'package:intl/intl.dart';

/// Below this radius (metres) the accuracy circle is NOT drawn: it would sit
/// under the member marker itself and communicate nothing a viewer could act on.
/// Shared between the map halo and the members-list "±N" label so the two never
/// disagree about what counts as a meaningful uncertainty. Matches the web
/// `ACCURACY_MIN_DRAW_M` (web/src/map/accuracy.ts).
const double kAccuracyMinDrawMeters = 25;

/// A number we can believe: present, finite and positive. Anything else (an
/// older reporter that sent no accuracy, 0, or a NaN from a mangled payload)
/// means "unknown" and must never render as a confident zero-radius figure.
/// Mirrors the web `isUsableAccuracy`.
bool isUsableAccuracy(double? accuracy) =>
    accuracy != null && accuracy.isFinite && accuracy > 0;

/// The number + unit of an accuracy radius, split so the caller can localize the
/// unit. Whole metres up to a kilometre (a decimetre on a Wi-Fi guess would be
/// false precision), kilometres beyond that to one decimal in the active
/// locale's notation ("1.2" / "1,2"). Mirrors the web `accuracyParts`.
({String value, bool isKilometers}) accuracyParts(
  double accuracy,
  String locale,
) {
  final metres = accuracy.round();
  // Rounding decides the unit, so 999.6 m reads "1 km" rather than "1000 m".
  if (metres < 1000) return (value: '$metres', isKilometers: false);
  final km =
      (NumberFormat.decimalPattern(locale)
            ..minimumFractionDigits = 0
            ..maximumFractionDigits = 1)
          .format(metres / 1000);
  return (value: km, isKilometers: true);
}
