import 'package:flutter/foundation.dart' show setEquals;

import '../../../l10n/app_localizations.dart';
import '../../domain/place.dart';
import '../../tracking/geofence_engine.dart';
import '../../tracking/geofence_state.dart';
import '../notifications/notification_service.dart';

/// Announces one of this device's own geofence crossings to the rest of the
/// circle. Implemented by [NotifyRelay] (features/retention/notify_relay.dart);
/// a plain callback here so the monitor keeps knowing nothing about the network.
typedef GeofenceRelay = Future<void> Function(GeofenceTransition transition);

/// Wires the client-side [GeofenceEngine] enter/exit crossings — computed on the
/// device's OWN fix stream, never from server plaintext — to local
/// notifications, and to the outbound relay that tells the rest of the circle.
///
/// The two have SEPARATE gates, and deliberately so:
///
///  * [active] (the arrival opt-in AND the server kill-switch) governs the LOCAL
///    alert — whether *you* get buzzed about your own arrivals.
///  * [relayActive] (the server kill-switch alone) governs the outbound relay —
///    whether the circle is told you arrived. Gating that on your own alert
///    opt-in would silently deprive everyone else of their arrival alerts
///    because of a preference about your notification tray. Mirrors the web
///    GeofenceFeed, which relays on `serverEnabled` alone.
///
/// WHO RUNS THIS, AND WHY ONLY THEM. Own-fix evaluation belongs to the headless
/// location isolate (`platform/background_service.dart`) and to nobody else.
/// That is not a preference, it is the topology: the native LocationService
/// forwards every fix to the `app.aul/bg` channel and to that channel ONLY, so
/// the background isolate is the only Dart that has a location stream at all —
/// whether or not the UI is up. Evaluating in the foreground too would mean two
/// engines, two inside-sets, two local notifications and two `/notify` fan-outs
/// per crossing, so the foreground [AppController] deliberately does not call
/// [onOwnFix]; it keeps only [onMemberArrival], which is about OTHER people's
/// crossings arriving on the realtime socket and is not a geofence computation
/// at all.
///
/// DURABILITY. The engine's inside-set is the whole memory of the feature, and
/// Android restarts the foreground service whenever it likes. So the set is
/// loaded from [GeofenceStateStore] before the first evaluation and written back
/// on every change — otherwise each restart re-announces "you arrived at Home"
/// to you and to the entire circle while you sit on the sofa. See
/// `tracking/geofence_state.dart`.
class ArrivalMonitor {
  /// [state] makes the crossing state durable; it defaults to a forgetful
  /// in-memory store, which is right for tests and for the foreground (which
  /// does not evaluate own fixes), and wrong for the background isolate — that
  /// one passes a [VaultGeofenceState].
  ArrivalMonitor({
    required NotificationService notifications,
    GeofenceRelay? relay,
    GeofenceStateStore? state,
    double hysteresisM = 30,
  }) : _notifications = notifications,
       _relay = relay,
       _state = state ?? MemoryGeofenceState(),
       _hysteresisM = hysteresisM;

  final NotificationService _notifications;
  final GeofenceRelay? _relay;
  final GeofenceStateStore _state;
  final double _hysteresisM;

  GeofenceEngine? _engine;

  /// What is currently in the store, so a fix that crosses nothing costs no
  /// write. Only meaningful once [_ensureEngine] has run.
  Set<String> _saved = const <String>{};

  /// Builds the engine on first use, seeded from durable state. Doing it lazily
  /// (rather than in the constructor) is what lets the load be awaited: a
  /// constructor cannot, and an engine that starts empty *while its real state
  /// loads* would emit exactly the phantom arrival this class exists to prevent.
  Future<GeofenceEngine> _ensureEngine() async {
    final existing = _engine;
    if (existing != null) return existing;
    final restored = await _state.load();
    _saved = Set<String>.of(restored);
    return _engine = GeofenceEngine(
      hysteresisM: _hysteresisM,
      restoreInside: restored,
    );
  }

  /// Feeds the device's own fix. Advances the geofence engine (so its
  /// inside/outside state stays correct even when inactive, preventing a burst of
  /// stale crossings the moment the user opts in), relays each crossing to the
  /// circle when [relayActive], and, when [active], posts an "arrived"/"left"
  /// notification per crossing.
  Future<void> onOwnFix({
    required double lat,
    required double lng,
    required List<Place> places,
    required DateTime now,
    required bool active,
    required AppLocalizations l10n,
    bool relayActive = false,
  }) async {
    final engine = await _ensureEngine();
    final events = engine.update(lat, lng, places, now);

    // Persisted BEFORE anything is announced, and this order is the whole point.
    // Crash between the two and the cost is one notification nobody hears —
    // annoying. Announce first and crash before the write, and the restarted
    // service re-reads the OLD set, re-crosses the same fence and tells the
    // whole circle a second time. A missed alert beats a phantom one sent to
    // everyone you know.
    //
    // Written on any CHANGE, not merely on an event: pruning a deleted place
    // mutates the set silently, and a set that disagrees with the store would
    // resurrect the place's fence on the next restart.
    final inside = engine.insidePlaceIds;
    if (!setEquals(inside, _saved)) {
      _saved = Set<String>.of(inside);
      await _state.save(_saved);
    }

    if (events.isEmpty) return;

    final relay = _relay;
    if (relayActive && relay != null) {
      for (final e in events) {
        await relay(e); // best-effort: the relay swallows its own failures
      }
    }

    if (!active) return;
    for (final e in events) {
      final arrived = e.kind == GeofenceKind.enter;
      await _notifications.show(
        id: NotifId.arrival,
        title: arrived ? l10n.notifArrivedTitle : l10n.notifLeftTitle,
        body: arrived
            ? l10n.notifArrivedBody(e.placeName)
            : l10n.notifLeftBody(e.placeName),
      );
    }
  }

  /// Surfaces a circle member's arrival seen on the realtime stream while the app
  /// is active. Behind the same arrival gate. (The realtime-stream consumer calls
  /// this when it decrypts a member ping that lands inside a shared place.)
  ///
  /// This one IS the foreground's to run: it is somebody else's crossing,
  /// already computed on their device, arriving over the socket.
  Future<void> onMemberArrival({
    required String memberName,
    required String placeName,
    required bool active,
    required AppLocalizations l10n,
  }) async {
    if (!active) return;
    await _notifications.show(
      id: NotifId.memberArrival,
      title: l10n.notifCircleUpdateTitle,
      body: l10n.notifMemberArrivedBody(memberName, placeName),
    );
  }

  /// Whether this device is inside [placeId]. Reflects durable state only after
  /// the first [onOwnFix] has hydrated the engine.
  bool isInside(String placeId) => _engine?.isInside(placeId) ?? false;
}
