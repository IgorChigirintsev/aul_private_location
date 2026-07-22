import '../domain/location_fix.dart';

/// Decides whether a freshly-arrived fix is worth reporting, or whether it is a
/// downgrade that would move the marker to a place the device is not.
///
/// Android interleaves providers: a coarse network estimate (±500 m) and a sharp
/// GPS fix (±5 m) arrive on the SAME callback, in no guaranteed order. Sealing
/// every one of them makes the circle watch the pin yank a couple of blocks away
/// and back — the marker is "correct" on average and wrong at every instant.
///
/// So a much vaguer fix is rejected while a sharper one is still current. The
/// escape hatch is age: a sharp fix that has stopped being refreshed is a fix
/// about where the device WAS, and past [staleAfter] a vague fix about where it
/// IS beats it. Without that clause a single lucky GPS fix would wedge the gate
/// shut for the rest of the session.
///
/// Mirrors the web reporter's guard (same 2× / 90 s thresholds), so the two
/// clients agree on what is worth showing.
class FixGate {
  FixGate({
    this.staleAfter = const Duration(seconds: 90),
    this.vaguerFactor = 2.0,
  });

  /// How old the held fix must be before a vaguer one is allowed to replace it.
  final Duration staleAfter;

  /// How many times vaguer than the held fix an incoming fix must be to be
  /// treated as a downgrade rather than ordinary jitter.
  final double vaguerFactor;

  LocationFix? _held;

  /// The fix currently considered authoritative, or null before the first one.
  LocationFix? get held => _held;

  /// True when [fix] should be reported. Accepting also makes it the new held
  /// fix; rejecting leaves the held fix in place.
  ///
  /// Age is measured between the two fixes' own capture times, never against
  /// `DateTime.now()`: both come from the platform's clock on the same device,
  /// so they are comparable, and the decision stays a pure function of its
  /// inputs (which is why it can be unit-tested without a fake clock).
  bool accept(LocationFix fix) {
    final held = _held;
    if (held == null) {
      _held = fix;
      return true;
    }
    final heldAccuracy = held.accuracy;
    final incomingAccuracy = fix.accuracy;
    // An unmeasured accuracy on either side makes "vaguer" undefined. Guessing
    // would be worse than passing it through: a fix with no accuracy is the only
    // fix we have, and dropping it would freeze the marker.
    if (heldAccuracy != null && incomingAccuracy != null) {
      final isDowngrade = incomingAccuracy > heldAccuracy * vaguerFactor;
      final heldAge = fix.capturedAt.difference(held.capturedAt);
      if (isDowngrade && heldAge < staleAfter) return false;
    }
    _held = fix;
    return true;
  }
}
