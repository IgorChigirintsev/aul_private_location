import 'package:aul/l10n/app_localizations.dart';
import 'package:aul/src/domain/place.dart';
import 'package:aul/src/features/notifications/notification_service.dart';
import 'package:aul/src/features/retention/arrival_monitor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_notification_service.dart';

void main() {
  // Notification copy is localized; resolve the English strings directly.
  final l10n = lookupAppLocalizations(const Locale('en'));
  const home = Place(
    id: 'home',
    version: 1,
    name: 'Home',
    lat: 43.2,
    lng: 76.8,
    radius: 100,
  );
  final t0 = DateTime.utc(2026, 1, 1);

  test(
    'arrival fires only when active (arrivalEnabled AND serverEnabled)',
    () async {
      final notif = FakeNotificationService();
      final monitor = ArrivalMonitor(notifications: notif);

      // Inactive: crossing the geofence must NOT notify, but the engine advances.
      await monitor.onOwnFix(
        lat: 43.25,
        lng: 76.85,
        places: [home],
        now: t0,
        active: false,
        l10n: l10n,
      ); // far
      await monitor.onOwnFix(
        lat: 43.2,
        lng: 76.8,
        places: [home],
        now: t0,
        active: false,
        l10n: l10n,
      ); // enter
      expect(notif.shown, isEmpty);
      expect(monitor.isInside('home'), isTrue);

      // Move back out (still inactive) so we can re-enter while active.
      await monitor.onOwnFix(
        lat: 43.25,
        lng: 76.85,
        places: [home],
        now: t0,
        active: false,
        l10n: l10n,
      );
      expect(monitor.isInside('home'), isFalse);

      // Active: entering now fires "You arrived at Home".
      await monitor.onOwnFix(
        lat: 43.2,
        lng: 76.8,
        places: [home],
        now: t0,
        active: true,
        l10n: l10n,
      );
      expect(notif.shown, hasLength(1));
      expect(notif.shown.single.id, NotifId.arrival);
      expect(notif.shown.single.body, 'You arrived at Home');

      // Active: leaving fires "You left Home".
      await monitor.onOwnFix(
        lat: 43.25,
        lng: 76.85,
        places: [home],
        now: t0,
        active: true,
        l10n: l10n,
      );
      expect(notif.shown, hasLength(2));
      expect(notif.shown.last.body, 'You left Home');
    },
  );

  test('member arrival is gated by the same flag', () async {
    final notif = FakeNotificationService();
    final monitor = ArrivalMonitor(notifications: notif);

    await monitor.onMemberArrival(
      memberName: 'Aisha',
      placeName: 'School',
      active: false,
      l10n: l10n,
    );
    expect(notif.shown, isEmpty);

    await monitor.onMemberArrival(
      memberName: 'Aisha',
      placeName: 'School',
      active: true,
      l10n: l10n,
    );
    expect(notif.shown, hasLength(1));
    expect(notif.shown.single.id, NotifId.memberArrival);
    expect(notif.shown.single.body, 'Aisha arrived at School');
  });
}
