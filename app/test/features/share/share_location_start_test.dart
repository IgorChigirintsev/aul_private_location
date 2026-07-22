import 'package:aul/src/controller.dart';
import 'package:aul/src/data/secret_store.dart';
import 'package:aul/src/platform/location_control.dart';
import 'package:aul/src/tracking/adaptive_scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [LocationControl] that records what the app asked the native service for,
/// without a platform channel.
class _FakeControl implements LocationControl {
  final List<TrackingProfile> started = [];
  final List<String> notifications = [];
  int stops = 0;
  bool reporting = false;

  @override
  Future<void> start({
    required TrackingProfile profile,
    required String notificationText,
  }) async {
    started.add(profile);
    notifications.add(notificationText);
    reporting = true;
  }

  @override
  Future<void> stop() async {
    stops++;
    reporting = false;
  }

  @override
  Future<bool> isReporting() async => reporting;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeControl control;
  late ProviderContainer container;

  setUp(() {
    control = _FakeControl();
    container = ProviderContainer(
      overrides: [
        secretStoreProvider.overrideWithValue(InMemorySecretStore()),
        controlProvider.overrideWithValue(control),
      ],
    );
    addTearDown(container.dispose);
  });

  AppController ctrl() => container.read(controllerProvider.notifier);

  test(
    'a share going live with NO circle sharing starts the location service',
    () async {
      // The hole this guards: the isolate is the only thing that feeds a share,
      // and it only ever runs while the native service does. Nothing else here
      // is reporting — no circle, or every circle paused — so if this does not
      // start the service, the link is fed nothing and no test of the isolate
      // would ever notice.
      await ctrl().setShareNeedsLocation(true);

      expect(control.started, hasLength(1));
      // At the share cadence, not the 10-minute still one: someone is watching a
      // map right now.
      expect(control.started.single.interval, AdaptiveScheduler.shareInterval);
      expect(control.started.single.isPaused, isFalse);
      // And the notification says a link is what's running, rather than naming a
      // circle that is receiving nothing.
      expect(control.notifications.single, isNotEmpty);
    },
  );

  test('the last share ending stops the service', () async {
    await ctrl().setShareNeedsLocation(true);
    await ctrl().setShareNeedsLocation(false);

    expect(control.stops, 1);
    expect(control.reporting, isFalse);
  });

  test(
    'a share rides a stream that is already running, never a second one',
    () async {
      // One GPS stream, always. A second start would mean two foreground services
      // and double the battery for the same fixes.
      control.reporting = true;
      await ctrl().setShareNeedsLocation(true);

      expect(control.started, isEmpty);
      expect(control.stops, 0, reason: 'and it must not interrupt the circle');
    },
  );
}
