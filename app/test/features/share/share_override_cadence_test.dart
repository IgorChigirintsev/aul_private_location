import 'package:aul/src/controller.dart';
import 'package:aul/src/data/api/models.dart';
import 'package:aul/src/data/key_vault.dart';
import 'package:aul/src/data/secret_store.dart';
import 'package:aul/src/domain/location_fix.dart';
import 'package:aul/src/features/retention/retention_controller.dart';
import 'package:aul/src/platform/location_control.dart';
import 'package:aul/src/tracking/adaptive_scheduler.dart';
import 'package:aul/src/tracking/motion.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Retention is irrelevant to cadence and, left real, its build() listens back
/// on the controller — a cycle in a bare test container. Stub it inert.
class _NoRetention extends RetentionController {
  @override
  RetentionState build() => const RetentionState();
}

/// Records what the app asked the native service for, without a platform
/// channel. [reporting] flips true on any start so `isReporting()` is truthful.
class _FakeControl implements LocationControl {
  final List<TrackingProfile> started = [];
  int stops = 0;
  bool reporting = false;

  @override
  Future<void> start({
    required TrackingProfile profile,
    required String notificationText,
  }) async {
    started.add(profile);
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

/// An [AppController] booted signed-in with one precise circle, so [startSharing]
/// has a real target to report to and resolves to the 30 s circle cadence.
class _Ctrl extends AppController {
  @override
  AppSession build() => AppSession(
    phase: AuthPhase.signedIn,
    serverUrl: 'https://aul.example',
    circles: const [
      CircleSummary(
        id: 'family',
        role: 'member',
        keyEpoch: 1,
        retentionDays: 7,
        precisionMode: 'precise',
      ),
    ],
  );
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
        vaultProvider.overrideWithValue(KeyVault(InMemorySecretStore())),
        controlProvider.overrideWithValue(control),
        controllerProvider.overrideWith(_Ctrl.new),
        retentionProvider.overrideWith(_NoRetention.new),
      ],
    );
    addTearDown(container.dispose);
  });

  AppController ctrl() => container.read(controllerProvider.notifier);

  test('a live circle stream runs at the 30 s circle cadence', () async {
    await ctrl().startSharing();
    expect(control.started.single.interval, AdaptiveScheduler.unknownInterval);
    expect(control.started.single.interval, const Duration(seconds: 30));
  });

  test(
    'a share starting on a live 30 s circle reconfigures to 10 s (the override)',
    () async {
      await ctrl().startSharing();
      expect(control.started.last.interval, const Duration(seconds: 30));

      await ctrl().setShareNeedsLocation(true);

      // The running service was reconfigured, not left at the circle cadence.
      expect(control.started.length, 2);
      expect(control.started.last.interval, AdaptiveScheduler.shareInterval);
      expect(control.started.last.interval, const Duration(seconds: 10));
      expect(control.stops, 0, reason: 'reconfigure, never a second stream');
    },
  );

  test(
    'when the share ends the cadence returns to the circle 30 s, not stuck at 10',
    () async {
      await ctrl().startSharing();
      await ctrl().setShareNeedsLocation(true);
      expect(control.started.last.interval, const Duration(seconds: 10));

      await ctrl().setShareNeedsLocation(false);

      // Dropped back to the circle's own cadence; the stream is NOT stopped
      // (the circle still needs it) and NOT left pinned at 10 s.
      expect(control.started.last.interval, const Duration(seconds: 30));
      expect(control.reporting, isTrue);
      expect(control.stops, 0);
    },
  );

  test('SOS beats a share when both are active (5 s wins)', () async {
    await ctrl().startSharing();
    await ctrl().setShareNeedsLocation(true);
    expect(control.started.last.interval, const Duration(seconds: 10));

    // Raise the emergency cadence over the same stream that is already sharing.
    await ctrl().startSharing(
      mode: TrackingMode.sos,
      precisionOverride: PrecisionMode.precise,
    );

    expect(control.started.last.interval, AdaptiveScheduler.sosInterval);
    expect(control.started.last.interval, const Duration(seconds: 5));
  });
}
