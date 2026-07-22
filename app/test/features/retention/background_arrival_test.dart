import 'package:aul/src/domain/location_fix.dart';
import 'package:aul/src/domain/place.dart';
import 'package:aul/src/features/notifications/notification_service.dart';
import 'package:aul/src/features/retention/arrival_monitor.dart';
import 'package:aul/src/features/retention/background_arrival.dart';
import 'package:aul/src/features/retention/background_places.dart';
import 'package:aul/src/features/retention/retention_prefs.dart';
import 'package:aul/src/tracking/geofence_engine.dart';
import 'package:aul/src/tracking/geofence_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_notification_service.dart';

/// The fences, without a vault, libsodium or a network. The caching/decryption
/// that the real [BackgroundPlaces] does is a separate concern.
class _FakePlaces implements PlaceSource {
  _FakePlaces(this.places);

  @override
  List<Place> places;

  int loads = 0;

  @override
  Future<void> ensureLoaded(DateTime now) async => loads++;
}

/// A phone that dies mid-announcement — the case that decides whether the
/// durable write has to happen before the notification or after it.
class _ThrowingNotificationService implements NotificationService {
  @override
  Future<void> init() async {}

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async => throw StateError('the process died here');
}

/// Records what the circle would have been told. The real [NotifyRelay] seals
/// this under K_c and POSTs it; what matters here is whether it is called.
class _RecordingRelay {
  final List<GeofenceTransition> sent = [];
  Future<void> call(GeofenceTransition t) async => sent.add(t);
}

const _home = Place(
  id: 'home',
  version: 1,
  name: 'Home',
  lat: 43.2,
  lng: 76.8,
  radius: 100,
);

/// Inside the fence, and far outside it.
LocationFix _atHome(DateTime at) =>
    LocationFix(lat: 43.2, lng: 76.8, capturedAt: at, accuracy: 10);
LocationFix _away(DateTime at) =>
    LocationFix(lat: 43.25, lng: 76.85, capturedAt: at, accuracy: 10);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final t0 = DateTime.utc(2026, 7, 15, 12);

  /// The gates as the user/operator would have set them.
  Future<RetentionPrefs> prefsWith({
    required bool serverEnabled,
    required bool arrivalEnabled,
  }) async {
    SharedPreferences.setMockInitialValues({
      'retention.serverEnabled': serverEnabled,
      'retention.arrivalEnabled': arrivalEnabled,
    });
    return RetentionPrefs(await SharedPreferences.getInstance());
  }

  /// One "boot" of the headless location isolate. [state] is passed in so a test
  /// can restart the service and keep the durable state, exactly as the device
  /// does — the vault outlives the isolate.
  ({BackgroundArrivalEvaluator evaluator, FakeNotificationService notif}) boot({
    required RetentionPrefs prefs,
    required GeofenceStateStore state,
    required _RecordingRelay relay,
    List<Place> places = const [_home],
  }) {
    final notif = FakeNotificationService();
    return (
      evaluator: BackgroundArrivalEvaluator(
        monitor: ArrivalMonitor(
          notifications: notif,
          state: state,
          relay: relay.call,
        ),
        places: _FakePlaces(places),
        prefs: prefs,
      ),
      notif: notif,
    );
  }

  test('a service restart mid-visit does NOT re-announce the arrival', () async {
    // THE regression this whole change exists for. Android restarts a
    // START_STICKY foreground service whenever it likes; with the inside-set
    // held only in RAM, the first fix after each restart re-read as an "enter"
    // and told the user AND their whole circle they had just arrived home —
    // while they sat on the sofa, having moved nowhere.
    final prefs = await prefsWith(serverEnabled: true, arrivalEnabled: true);
    final state = MemoryGeofenceState(); // the vault: outlives the isolate
    final relay = _RecordingRelay();

    // Boot 1: walk in the door. One arrival, correctly.
    final first = boot(prefs: prefs, state: state, relay: relay);
    await first.evaluator.onFix(_away(t0));
    await first.evaluator.onFix(_atHome(t0.add(const Duration(minutes: 1))));
    expect(first.notif.shown, hasLength(1));
    expect(first.notif.shown.single.body, 'You arrived at Home');
    expect(relay.sent, hasLength(1));

    // Android kills and restarts the service. A brand-new isolate, a brand-new
    // engine — and the same sofa.
    final second = boot(prefs: prefs, state: state, relay: relay);
    for (var i = 0; i < 3; i++) {
      await second.evaluator.onFix(_atHome(t0.add(Duration(minutes: 10 + i))));
    }

    expect(
      second.notif.shown,
      isEmpty,
      reason: 'the restarted service must know it was already home',
    );
    expect(
      relay.sent,
      hasLength(1),
      reason: 'the circle must not be told a second time about one arrival',
    );

    // And the state is still honest: actually leaving still reports.
    await second.evaluator.onFix(_away(t0.add(const Duration(minutes: 20))));
    expect(second.notif.shown.single.body, 'You left Home');
    expect(relay.sent, hasLength(2));
  });

  test('a crossing while backgrounded notifies locally AND relays', () async {
    // The product hole: "Anna arrived home" only ever fired with the app open.
    // This is the background isolate's own path — no UI, no Riverpod, no
    // foreground fix stream — doing both halves.
    final prefs = await prefsWith(serverEnabled: true, arrivalEnabled: true);
    final relay = _RecordingRelay();
    final bg = boot(prefs: prefs, state: MemoryGeofenceState(), relay: relay);

    await bg.evaluator.onFix(_away(t0));
    await bg.evaluator.onFix(_atHome(t0.add(const Duration(minutes: 1))));

    expect(bg.notif.shown, hasLength(1));
    expect(bg.notif.shown.single.id, NotifId.arrival);
    expect(bg.notif.shown.single.body, 'You arrived at Home');

    expect(relay.sent, hasLength(1));
    expect(relay.sent.single.placeId, 'home');
    expect(relay.sent.single.kind, GeofenceKind.enter);
    expect(
      relay.sent.single.at,
      t0.add(const Duration(minutes: 1)),
      reason: 'the circle is told when it happened, not when it was sent',
    );
  });

  test(
    'the two gates are independent: the relay fires with the local alert opted out',
    () async {
      // The bug worth guarding forever. `arrival` is a preference about YOUR
      // notification tray; the relay is what everyone ELSE depends on. Gating the
      // relay on it would silently deprive the whole circle of their alerts.
      final prefs = await prefsWith(serverEnabled: true, arrivalEnabled: false);
      final relay = _RecordingRelay();
      final bg = boot(prefs: prefs, state: MemoryGeofenceState(), relay: relay);

      await bg.evaluator.onFix(_away(t0));
      await bg.evaluator.onFix(_atHome(t0.add(const Duration(minutes: 1))));

      expect(
        bg.notif.shown,
        isEmpty,
        reason: 'they opted out of being buzzed about their own arrivals',
      );
      expect(
        relay.sent,
        hasLength(1),
        reason: 'their family must still be told they got home',
      );
    },
  );

  test('the operator kill-switch alone stops both halves', () async {
    final prefs = await prefsWith(serverEnabled: false, arrivalEnabled: true);
    final relay = _RecordingRelay();
    final bg = boot(prefs: prefs, state: MemoryGeofenceState(), relay: relay);

    await bg.evaluator.onFix(_away(t0));
    await bg.evaluator.onFix(_atHome(t0.add(const Duration(minutes: 1))));

    expect(bg.notif.shown, isEmpty);
    expect(relay.sent, isEmpty);
  });

  test(
    'the gates are re-read per fix, not captured when the service booted',
    () async {
      // The isolate outlives the UI by hours, so a gate captured at boot would
      // be answering with preferences from a different part of the day.
      //
      // SCOPE: this pins that the evaluator READS the store on every fix. It
      // does NOT prove `RetentionPrefs.reload()` works, and cannot: in tests
      // SharedPreferences is one in-memory singleton, so the UI's write is
      // visible here without any reload. The real cross-ISOLATE cache — where
      // reload() is the thing that matters — only exists on a device.
      final prefs = await prefsWith(serverEnabled: true, arrivalEnabled: true);
      final relay = _RecordingRelay();
      final bg = boot(prefs: prefs, state: MemoryGeofenceState(), relay: relay);

      await bg.evaluator.onFix(_away(t0));
      await bg.evaluator.onFix(_atHome(t0.add(const Duration(minutes: 1))));
      expect(bg.notif.shown, hasLength(1));

      // The user opts out in the UI isolate; only the backing store changes.
      final ui = RetentionPrefs(await SharedPreferences.getInstance());
      await ui.setEnabled(RetentionFeature.arrival, false);

      await bg.evaluator.onFix(_away(t0.add(const Duration(minutes: 2))));
      expect(
        bg.notif.shown,
        hasLength(1),
        reason: 'the departure must not be announced after opting out',
      );
      expect(
        relay.sent,
        hasLength(2),
        reason: 'the relay is not gated on that preference',
      );
    },
  );

  test(
    'a second evaluator sharing the durable state does not double-announce',
    () async {
      // Defence in depth for the "two isolates both evaluate" hazard. The real
      // guarantee is that only the background isolate evaluates at all — the
      // foreground AppController has no own-fix geofence path, by construction.
      // This pins the property that makes an accidental second evaluator mostly
      // harmless: the inside-set is written to the shared store BEFORE anything
      // is announced, so a later evaluator hydrates from it and sees no crossing.
      //
      // NOTE it is a mitigation, not a proof: two evaluators running genuinely
      // CONCURRENTLY could both load the old set before either saved, and both
      // announce. That race is what single-ownership, not this, rules out.
      final prefs = await prefsWith(serverEnabled: true, arrivalEnabled: true);
      final state = MemoryGeofenceState();
      final relay = _RecordingRelay();

      final a = boot(prefs: prefs, state: state, relay: relay);
      final b = boot(prefs: prefs, state: state, relay: relay);

      await a.evaluator.onFix(_away(t0));
      final arriving = _atHome(t0.add(const Duration(minutes: 1)));
      await a.evaluator.onFix(arriving);
      await b.evaluator.onFix(arriving); // the same crossing, the other path

      expect(a.notif.shown, hasLength(1));
      expect(b.notif.shown, isEmpty);
      expect(
        relay.sent,
        hasLength(1),
        reason: 'one crossing is one fan-out to the circle',
      );
    },
  );

  test(
    'a crash while announcing does not resurrect the crossing on restart',
    () async {
      // Pins the ORDER: the inside-set is persisted BEFORE anything is
      // announced. Announcing first and dying before the write would leave the
      // store still saying "outside", so the restarted service would re-cross
      // the same fence and tell the whole circle a second time.
      //
      // A phone that dies mid-notification is exactly when this happens, so the
      // trade is deliberate: crash between the two and the cost is one alert
      // nobody hears, which beats a phantom arrival sent to everyone you know.
      final prefs = await prefsWith(serverEnabled: true, arrivalEnabled: true);
      final state = MemoryGeofenceState();
      final relay = _RecordingRelay();

      final dying = BackgroundArrivalEvaluator(
        monitor: ArrivalMonitor(
          notifications: _ThrowingNotificationService(),
          state: state,
          relay: relay.call,
        ),
        places: _FakePlaces(const [_home]),
        prefs: prefs,
      );
      await dying.onFix(_away(t0));
      await expectLater(
        dying.onFix(_atHome(t0.add(const Duration(minutes: 1)))),
        throwsA(isA<StateError>()),
      );
      expect(relay.sent, hasLength(1), reason: 'the circle was told once');

      // The service comes back up on the same sofa.
      final revived = boot(prefs: prefs, state: state, relay: relay);
      await revived.evaluator.onFix(
        _atHome(t0.add(const Duration(minutes: 5))),
      );
      expect(revived.notif.shown, isEmpty);
      expect(
        relay.sent,
        hasLength(1),
        reason: 'the crossing was already recorded before it was announced',
      );
    },
  );

  test('places are consulted through the source on every fix', () async {
    // The isolate must not evaluate against a list it captured once at boot: a
    // place added on the web while the phone is in a pocket has to start
    // fencing. (BackgroundPlaces turns this into a TTL'd refresh.)
    final prefs = await prefsWith(serverEnabled: true, arrivalEnabled: true);
    final places = _FakePlaces(const []);
    final notif = FakeNotificationService();
    final relay = _RecordingRelay();
    final evaluator = BackgroundArrivalEvaluator(
      monitor: ArrivalMonitor(
        notifications: notif,
        state: MemoryGeofenceState(),
        relay: relay.call,
      ),
      places: places,
      prefs: prefs,
    );

    await evaluator.onFix(_atHome(t0));
    expect(notif.shown, isEmpty, reason: 'no fences yet — nothing to cross');
    expect(places.loads, 1);

    // Someone adds Home on the dashboard; the source picks it up.
    places.places = const [_home];
    await evaluator.onFix(_away(t0.add(const Duration(minutes: 1))));
    await evaluator.onFix(_atHome(t0.add(const Duration(minutes: 2))));
    expect(notif.shown, hasLength(1));
    expect(notif.shown.single.body, 'You arrived at Home');
  });
}
