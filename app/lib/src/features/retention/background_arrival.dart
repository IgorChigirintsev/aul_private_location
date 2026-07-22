import '../../domain/location_fix.dart';
import '../locale_controller.dart';
import 'arrival_monitor.dart';
import 'background_places.dart';
import 'retention_prefs.dart';

/// The per-fix crossing evaluation, as a seam.
///
/// [BackgroundReporter] depends on this rather than on the real thing so its
/// tests keep needing no vault, no plugins and no network — the reporter's job
/// is the pipeline, and the crossing logic is tested on its own.
abstract interface class FixCrossingEvaluator {
  Future<void> onFix(LocationFix fix);
}

/// Evaluates this device's geofence crossings inside the headless location
/// isolate — the ONE place in the app that does so. See [ArrivalMonitor] for why
/// the foreground deliberately does not.
///
/// It exists because the two gates cannot be read here the way the UI reads
/// them: there is no Riverpod in this isolate, so [RetentionState] is
/// unavailable and both halves have to be reassembled from
/// [SharedPreferences] — and reassembled *correctly*, because conflating them is
/// the bug the whole feature is documented against:
///
///  * `active`      = serverEnabled AND arrivalEnabled → YOU get a local alert.
///  * `relayActive` = serverEnabled ALONE              → the CIRCLE is told.
///
/// So a user who wants their family alerted but does not want their own phone
/// buzzing keeps working, which is the entire point of keeping them separate.
class BackgroundArrivalEvaluator implements FixCrossingEvaluator {
  BackgroundArrivalEvaluator({
    required ArrivalMonitor monitor,
    required PlaceSource places,
    required RetentionPrefs prefs,
  }) : _monitor = monitor,
       _places = places,
       _prefs = prefs;

  final ArrivalMonitor _monitor;
  final PlaceSource _places;
  final RetentionPrefs _prefs;

  @override
  Future<void> onFix(LocationFix fix) async {
    // The service outlives the UI, so its SharedPreferences snapshot would
    // otherwise be frozen at whatever the opt-ins were when Android last started
    // it — hours ago. Re-read, or "I turned arrivals off" does nothing until a
    // restart.
    await _prefs.reload();
    final serverEnabled = _prefs.serverEnabled;

    // The operator's kill-switch is off, so BOTH outputs are off and evaluating
    // could only spend battery and radio to discard the answer. Note this is the
    // only gate that may skip evaluation: the user's own arrival opt-in must NOT,
    // or a member who silenced their own tray would stop relaying to everyone
    // else.
    if (!serverEnabled) return;

    await _places.ensureLoaded(fix.capturedAt);
    if (_places.places.isEmpty) return; // no fences — nothing to cross

    await _monitor.onOwnFix(
      // The RAW fix, never `forMode`'d. Precision coarsening exists to blur what
      // the CIRCLE is told; blurring the input to a local geofence would just
      // make it wrong — a city-grid coordinate lands up to a kilometre from the
      // house, which is several times a typical fence radius.
      lat: fix.lat,
      lng: fix.lng,
      places: _places.places,
      // The PLATFORM's fix time, not now(): the reporter is careful never to
      // relabel a settled fix, and a crossing carries the same timestamp into
      // the relay so the circle is told when it happened, not when it was sent.
      now: fix.capturedAt,
      active: serverEnabled && _prefs.arrivalEnabled,
      relayActive: serverEnabled,
      l10n: currentL10n(),
    );
  }
}
