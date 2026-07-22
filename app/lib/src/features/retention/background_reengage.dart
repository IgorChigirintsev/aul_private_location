import '../../domain/location_fix.dart';
import '../locale_controller.dart';
import 'reengagement_monitor.dart';
import 'retention_prefs.dart';

/// The per-fix re-engagement check, as a seam. See [FixCrossingEvaluator] in
/// background_arrival.dart, which exists for the same reason.
abstract interface class FixBatteryWatcher {
  Future<void> onFix(LocationFix fix);
}

/// Runs the low-battery reminder inside the headless location isolate.
///
/// The battery level rides along on every fix the native service forwards
/// (`batt`), and the isolate is the only thing that sees a fix — so this is the
/// only place the reminder CAN run. It used to hang off a foreground handler on
/// a channel nothing ever called, which is why it never once fired.
///
/// Both gates are reassembled from [SharedPreferences] exactly as
/// [BackgroundArrivalEvaluator] does, and for the same reason: there is no
/// Riverpod here. Unlike arrivals there is no relay half — a low battery is
/// nobody's business but the user's, so this never tells the circle anything.
class BackgroundReengagement implements FixBatteryWatcher {
  BackgroundReengagement({
    required ReengagementMonitor monitor,
    required RetentionPrefs prefs,
  }) : _monitor = monitor,
       _prefs = prefs;

  final ReengagementMonitor _monitor;
  final RetentionPrefs _prefs;

  @override
  Future<void> onFix(LocationFix fix) async {
    final batt = fix.battery;
    // No level on this fix (a platform that didn't report one) — say nothing
    // rather than guess. The monitor's dedup means the next fix that HAS a level
    // still reminds.
    if (batt == null) return;

    // The service outlives the UI, so its prefs snapshot would otherwise be
    // frozen at whatever the opt-ins were when Android last started it.
    await _prefs.reload();
    await _monitor.onBattery(
      batteryPct: batt,
      // serverEnabled AND reengageEnabled: the operator's kill-switch and the
      // user's own opt-in, both required, defaulting to off. The monitor itself
      // posts nothing when this is false — it is passed rather than short-
      // circuited here so that a recovering battery still clears the dedup flag.
      active: _prefs.serverEnabled && _prefs.reengageEnabled,
      l10n: currentL10n(),
    );
  }
}
