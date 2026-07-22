import 'package:aul/l10n/app_localizations.dart';
import 'package:aul/src/features/notifications/notification_service.dart';
import 'package:aul/src/features/retention/reengagement_monitor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_notification_service.dart';

void main() {
  // Notification copy is localized; resolve the English strings directly.
  final l10n = lookupAppLocalizations(const Locale('en'));
  test(
    'tracking-off reminder fires once when active, never when inactive',
    () async {
      final notif = FakeNotificationService();
      final m = ReengagementMonitor(notif);

      // Inactive: no reminder even though sharing is expected but the service is down.
      await m.onTrackingState(
        shouldBeSharing: true,
        serviceRunning: false,
        active: false,
        l10n: l10n,
      );
      expect(notif.shown, isEmpty);

      // Active + condition true: exactly one reminder.
      await m.onTrackingState(
        shouldBeSharing: true,
        serviceRunning: false,
        active: true,
        l10n: l10n,
      );
      expect(notif.shown, hasLength(1));
      expect(notif.shown.single.id, NotifId.trackingOff);
      expect(notif.shown.single.title, 'Sharing is off');

      // Persisting condition does not repeat (no nagware).
      await m.onTrackingState(
        shouldBeSharing: true,
        serviceRunning: false,
        active: true,
        l10n: l10n,
      );
      expect(notif.shown, hasLength(1));

      // Service resumes → dedup clears; a later drop reminds again.
      await m.onTrackingState(
        shouldBeSharing: true,
        serviceRunning: true,
        active: true,
        l10n: l10n,
      );
      await m.onTrackingState(
        shouldBeSharing: true,
        serviceRunning: false,
        active: true,
        l10n: l10n,
      );
      expect(notif.shown, hasLength(2));
    },
  );

  test('no reminder when sharing is not expected', () async {
    final notif = FakeNotificationService();
    final m = ReengagementMonitor(notif);
    await m.onTrackingState(
      shouldBeSharing: false,
      serviceRunning: false,
      active: true,
      l10n: l10n,
    );
    expect(notif.shown, isEmpty);
  });

  test('battery-low reminds once at/under threshold when active', () async {
    final notif = FakeNotificationService();
    final m = ReengagementMonitor(notif);

    await m.onBattery(batteryPct: 50, active: true, l10n: l10n);
    expect(notif.shown, isEmpty);

    await m.onBattery(
      batteryPct: ReengagementMonitor.batteryThreshold,
      active: true,
      l10n: l10n,
    );
    expect(notif.shown, hasLength(1));
    expect(notif.shown.single.id, NotifId.batteryLow);

    await m.onBattery(
      batteryPct: 5,
      active: true,
      l10n: l10n,
    ); // still low → no repeat
    expect(notif.shown, hasLength(1));

    await m.onBattery(
      batteryPct: 80,
      active: true,
      l10n: l10n,
    ); // recovered → clears
    await m.onBattery(
      batteryPct: 10,
      active: true,
      l10n: l10n,
    ); // low again → reminds
    expect(notif.shown, hasLength(2));
  });

  test('battery-low respects the active gate', () async {
    final notif = FakeNotificationService();
    final m = ReengagementMonitor(notif);
    await m.onBattery(batteryPct: 5, active: false, l10n: l10n);
    expect(notif.shown, isEmpty);
  });
}
