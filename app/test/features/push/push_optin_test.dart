import 'package:aul/src/controller.dart';
import 'package:aul/src/data/api/api_client.dart';
import 'package:aul/src/features/push/push_messaging.dart';
import 'package:aul/src/features/retention/retention_controller.dart';
import 'package:aul/src/features/retention/retention_prefs.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A [PushMessaging] that records calls instead of touching Firebase.
class _FakePushMessaging implements PushMessaging {
  _FakePushMessaging({this.token = 'fcm-token-1'});

  /// What register() returns; null models a refused prompt / offline / a build
  /// with no Firebase config.
  String? token;
  int registerCalls = 0;
  int unregisterCalls = 0;

  @override
  Future<String?> register(AulApi api) async {
    registerCalls++;
    return token;
  }

  @override
  Future<void> unregister(AulApi? api) async => unregisterCalls++;

  @override
  Future<bool> ensureReady() async => true;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// A signed-in session, without touching the vault or the network.
class _FakeAppController extends AppController {
  @override
  AppSession build() => const AppSession(
    phase: AuthPhase.signedIn,
    serverUrl: 'https://example.test',
  );
}

ProviderContainer _container(_FakePushMessaging push) {
  final c = ProviderContainer(
    overrides: [
      controllerProvider.overrideWith(_FakeAppController.new),
      pushMessagingProvider.overrideWithValue(push),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('opting in to background push', () {
    test('registers the token and persists the opt-in', () async {
      final push = _FakePushMessaging();
      final c = _container(push);
      final ctrl = c.read(retentionProvider.notifier);

      await ctrl.toggle(RetentionFeature.push, true);

      expect(push.registerCalls, 1);
      expect(c.read(retentionProvider).pushEnabled, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('retention.pushEnabled'), isTrue);
    });

    test(
      'a REFUSED prompt leaves the switch off, and says so on disk',
      () async {
        // The switch must not lie: register() returning null means no token
        // reached the server, so the opt-in is rolled back rather than promising
        // notifications that can never arrive.
        final push = _FakePushMessaging(token: null);
        final c = _container(push);
        final ctrl = c.read(retentionProvider.notifier);

        await ctrl.toggle(RetentionFeature.push, true);

        expect(push.registerCalls, 1);
        expect(c.read(retentionProvider).pushEnabled, isFalse);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('retention.pushEnabled'), isFalse);
      },
    );

    test('opting out unregisters and persists', () async {
      final push = _FakePushMessaging();
      final c = _container(push);
      final ctrl = c.read(retentionProvider.notifier);

      await ctrl.toggle(RetentionFeature.push, true);
      await ctrl.toggle(RetentionFeature.push, false);

      expect(push.unregisterCalls, 1);
      expect(c.read(retentionProvider).pushEnabled, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('retention.pushEnabled'), isFalse);
    });

    test('opting out and back in registers again', () async {
      // The once-a-session guard must not stick after an opt-out.
      final push = _FakePushMessaging();
      final c = _container(push);
      final ctrl = c.read(retentionProvider.notifier);

      await ctrl.toggle(RetentionFeature.push, true);
      await ctrl.toggle(RetentionFeature.push, false);
      await ctrl.toggle(RetentionFeature.push, true);

      expect(push.registerCalls, 2);
    });

    test('toggling push does not touch the other opt-ins', () async {
      final push = _FakePushMessaging();
      final c = _container(push);
      final ctrl = c.read(retentionProvider.notifier);

      await ctrl.toggle(RetentionFeature.push, true);

      final s = c.read(retentionProvider);
      expect(s.arrivalEnabled, isFalse);
      expect(s.reengageEnabled, isFalse);
    });
  });

  group('RetentionState gating', () {
    test('push needs BOTH the kill-switch and fcm_enabled', () {
      const optedIn = RetentionState(pushEnabled: true, loaded: true);

      // Opted in, but the operator configured no FCM: nothing could deliver.
      expect(optedIn.copyWith(serverEnabled: true).pushActive, isFalse);
      // Opted in with FCM, but the whole feature set is off server-side.
      expect(optedIn.copyWith(fcmEnabled: true).pushActive, isFalse);
      // Both gates open.
      expect(
        optedIn.copyWith(serverEnabled: true, fcmEnabled: true).pushActive,
        isTrue,
      );
    });

    test('never active without the user opting in', () {
      // The anti-stalking default: a server saying "push is available" must not
      // by itself put a token on the wire.
      const state = RetentionState(
        serverEnabled: true,
        fcmEnabled: true,
        loaded: true,
      );
      expect(state.pushEnabled, isFalse);
      expect(state.pushActive, isFalse);
    });

    test('fcm_enabled gates ONLY push, not the other features', () {
      // A server with the features on but no push transport still runs arrival
      // alerts and reminders — those are local and need no server at all.
      const state = RetentionState(
        serverEnabled: true,
        fcmEnabled: false,
        arrivalEnabled: true,
        reengageEnabled: true,
        pushEnabled: true,
        loaded: true,
      );
      expect(state.arrivalActive, isTrue);
      expect(state.reengageActive, isTrue);
      expect(state.pushActive, isFalse);
      expect(state.pushAvailable, isFalse); // switch hidden
    });

    test('pushAvailable is about the server, not the opt-in', () {
      // Whether to SHOW the switch depends only on whether the server could
      // deliver; whether it is ON is the user's business.
      const off = RetentionState(serverEnabled: true, fcmEnabled: true);
      expect(off.pushAvailable, isTrue);
      expect(off.copyWith(pushEnabled: true).pushAvailable, isTrue);
    });

    test('enabled() covers every feature', () {
      const state = RetentionState(pushEnabled: true);
      expect(state.enabled(RetentionFeature.push), isTrue);
      expect(state.enabled(RetentionFeature.arrival), isFalse);
      expect(state.enabled(RetentionFeature.reengage), isFalse);
    });
  });
}
