import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../crypto/aul_crypto.dart';
import '../data/api/api_client.dart';
import '../data/db/connection.dart';
import '../data/db/queue_db.dart';
import '../data/key_vault.dart';
import '../data/secret_store.dart';
import '../domain/location_fix.dart';
import '../features/locale_controller.dart';
import '../features/notifications/notification_service.dart';
import '../features/retention/arrival_monitor.dart';
import '../features/retention/background_arrival.dart';
import '../features/retention/background_places.dart';
import '../features/retention/background_reengage.dart';
import '../features/retention/notify_relay.dart';
import '../features/retention/reengagement_monitor.dart';
import '../features/retention/retention_prefs.dart';
import '../features/share/background_shares.dart';
import '../features/share/share_keys.dart';
import '../tracking/fix_gate.dart';
import '../tracking/geofence_state.dart';
import '../tracking/reporter.dart';

/// Entry point for the headless background isolate hosted by the native
/// LocationService. It reuses the tested Dart pipeline (crypto + queue + API) so
/// reporting keeps working with the UI gone or after a reboot.
///
/// Must be a top-level function annotated for AOT retention.
@pragma('vm:entry-point')
void aulLocationServiceMain() {
  WidgetsFlutterBinding.ensureInitialized();
  // Registers the Dart-side plugin implementations (shared_preferences) in THIS
  // isolate — the native GeneratedPluginRegistrant on the service's FlutterEngine
  // brings up only the Java side. Without it the retention opt-ins are
  // unreadable here, and every crossing would be silently dropped. The FCM
  // background handler does exactly the same, for the same reason.
  DartPluginRegistrant.ensureInitialized();
  BackgroundReporter().start();
}

/// Owns the background reporting loop. Exposed (not private) so it can be
/// exercised by tests with injected dependencies.
class BackgroundReporter {
  BackgroundReporter({
    MethodChannel? channel,
    Reporter? reporter,
    List<CircleTarget> targets = const [],
    FixCrossingEvaluator? arrival,
    FixShareFeeder? shares,
    FixBatteryWatcher? reengage,
  }) : _channel = channel ?? const MethodChannel('app.aul/bg'),
       _reporter = reporter,
       _targets = targets,
       _arrival = arrival,
       _shares = shares,
       _reengage = reengage;

  final MethodChannel _channel;
  Reporter? _reporter;
  List<CircleTarget> _targets;
  QueueDatabase? _db;

  /// Evaluates geofence crossings for this device. Null when the isolate could
  /// not build one (signed out, no notification plugin) — reporting carries on
  /// regardless, because a location that reaches the circle matters more than an
  /// alert about it.
  FixCrossingEvaluator? _arrival;

  /// Feeds this device's live share links. Null when signed out / unconfigured.
  FixShareFeeder? _shares;

  /// Posts the low-battery reminder. Null when the isolate could not build one.
  FixBatteryWatcher? _reengage;

  /// Rejects a much vaguer fix while a sharp one is still current, so the
  /// circle's pin doesn't yank between a network estimate and a GPS fix.
  final FixGate _gate = FixGate();

  Future<void> start() async {
    _channel.setMethodCallHandler(handle);
    if (_reporter == null) {
      await _bootstrap();
    }
  }

  /// Builds the reporter from persisted secrets/config (runs in the isolate).
  Future<void> _bootstrap() async {
    final crypto = await AulCrypto.load();
    final vault = KeyVault(FlutterSecretStore());
    final baseUrl = await vault.loadServerUrl();
    if (baseUrl == null) return; // not configured to report yet
    _db = await openQueueDatabase();
    final api = AulApi(baseUrl: baseUrl, vault: vault);
    _reporter = Reporter(crypto: crypto, queue: _db!, api: api);

    final targets = <CircleTarget>[];
    for (final t in await vault.loadReportingTargets()) {
      final id = t['id'] as String?;
      if (id == null) continue;
      final keyBytes = await vault.loadCircleKey(id);
      if (keyBytes == null) continue;
      targets.add(
        CircleTarget(
          id,
          crypto.circleKeyFromBytes(keyBytes),
          PrecisionMode.fromWire(t['precision'] as String? ?? 'precise'),
        ),
      );
    }
    _targets = targets;
    // Deliberately NOT gated on [targets] being non-empty: a live share runs off
    // its own key and its own deadline, and must keep being fed when the circle
    // is paused or there is no circle at all.
    _shares = BackgroundShares(
      store: ShareKeyStore(vault),
      crypto: crypto,
      api: api,
    );
    await _bootstrapArrival(crypto: crypto, vault: vault, api: api);
    await _bootstrapReengage();
  }

  /// Builds the low-battery reminder. Best-effort like the arrival evaluator: no
  /// notification plugin in this isolate means no reminder, never a lost fix.
  Future<void> _bootstrapReengage() async {
    try {
      // The app's chosen language, not the system's — see [_bootstrapArrival].
      // (Idempotent, and _bootstrapArrival may have bailed before reaching it.)
      await restoreLocaleOverride();
      final notifications = LocalNotificationService();
      await notifications.init(); // recreates the channel; idempotent
      _reengage = BackgroundReengagement(
        monitor: ReengagementMonitor(notifications),
        prefs: RetentionPrefs(await SharedPreferences.getInstance()),
      );
    } catch (_) {
      _reengage = null;
    }
  }

  /// Builds the crossing evaluator. Best-effort and deliberately non-fatal: if
  /// any of it fails, the isolate still reports locations — the feature that
  /// people's safety actually rests on — and merely says nothing about arrivals.
  Future<void> _bootstrapArrival({
    required AulCrypto crypto,
    required KeyVault vault,
    required AulApi api,
  }) async {
    try {
      // The app's chosen language, not the system's: this isolate starts with a
      // blank heap and would otherwise render "You arrived at Home" in whatever
      // the phone is set to while the app itself is pinned to Russian. Same fix
      // the FCM handler applies.
      await restoreLocaleOverride();
      final notifications = LocalNotificationService();
      await notifications.init(); // recreates the channel; idempotent
      final places = BackgroundPlaces(vault: vault, crypto: crypto, api: api);
      _arrival = BackgroundArrivalEvaluator(
        monitor: ArrivalMonitor(
          notifications: notifications,
          // THE durable inside-set. Without this the service restarts Android
          // performs at will would each re-announce an arrival at a place the
          // user never left — to them, and to their whole circle.
          state: VaultGeofenceState(vault),
          relay: NotifyRelay(
            api: api,
            crypto: crypto,
            vault: vault,
            circleOfPlace: places.circleOf,
            whoIn: places.whoIn,
          ).onCrossing,
        ),
        places: places,
        prefs: RetentionPrefs(await SharedPreferences.getInstance()),
      );
    } catch (_) {
      _arrival = null; // no plugins / no prefs in this isolate — stay quiet
    }
  }

  /// Handles calls from the native service.
  Future<dynamic> handle(MethodCall call) async {
    switch (call.method) {
      case 'onLocation':
        await _onLocation((call.arguments as Map).cast<String, dynamic>());
        return null;
      case 'pause':
        return null; // native already stopped updates
      default:
        return null;
    }
  }

  Future<void> _onLocation(Map<String, dynamic> m) async {
    final reporter = _reporter;
    final fix = LocationFix.fromPayload({...m, 'mode': 'precise'});
    // The wake happened whether or not the fix is worth sealing — count it, then
    // decide. Hiding a rejected fix's wake would understate the battery cost.
    reporter?.stats.onWake();
    // A downgrade is dropped rather than sealed: the sharp fix the circle
    // already has is a better answer to "where are they" than this one. The same
    // reasoning covers every consumer below — a fix that would yank the circle's
    // pin across town would yank a share viewer's the same way.
    if (!_gate.accept(fix)) return;
    // The circle, at each target's own precision. Skipped entirely when there is
    // nothing to seal for — which is NOT the same as having nothing to do: a
    // live share below has its own key and its own deadline, and is fed whether
    // the circle is paused, empty, or signed out of.
    if (reporter != null && _targets.isNotEmpty) {
      await reporter.record(fix, _targets);
    }
    // The share links, RAW and under K_share. Before the circle's flush: a
    // watcher is looking at the map right now, and the queue is patient.
    try {
      await _shares?.onFix(fix);
    } catch (_) {
      // A share must never cost the circle a location either.
    }
    // Crossings are evaluated on gate-ACCEPTED fixes only, and that is on
    // purpose: the gate's job is to reject a vague network estimate that would
    // yank the pin across town, and a fix that would move the pin a kilometre
    // would just as happily invent an arrival and a departure. Reporting first
    // also means a slow relay can never delay the position itself.
    try {
      await _arrival?.onFix(fix);
    } catch (_) {
      // An alert must never cost the circle a location.
    }
    try {
      await _reengage?.onFix(fix);
    } catch (_) {
      // Ditto: a reminder is the least important thing on this path.
    }
    try {
      await reporter?.flushAll();
    } catch (_) {
      // Offline — the queue keeps the sealed pings for the next flush.
    }
  }
}
