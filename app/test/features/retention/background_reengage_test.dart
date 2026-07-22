import 'package:aul/src/domain/location_fix.dart';
import 'package:aul/src/features/notifications/notification_service.dart';
import 'package:aul/src/features/retention/background_reengage.dart';
import 'package:aul/src/features/retention/reengagement_monitor.dart';
import 'package:aul/src/features/retention/retention_prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNotificationService notif;

  /// Builds the evaluator over prefs in the state [opts] describes, exactly as
  /// the isolate would reassemble it — there is no Riverpod there, so both gates
  /// come out of SharedPreferences.
  Future<BackgroundReengagement> build({
    required bool serverEnabled,
    required bool reengageEnabled,
  }) async {
    SharedPreferences.setMockInitialValues({
      'flutter.retention.serverEnabled': serverEnabled,
      'flutter.retention.reengageEnabled': reengageEnabled,
    });
    notif = FakeNotificationService();
    return BackgroundReengagement(
      monitor: ReengagementMonitor(notif),
      prefs: RetentionPrefs(await SharedPreferences.getInstance()),
    );
  }

  LocationFix fix({int? batt}) => LocationFix(
    lat: 43.2,
    lng: 76.8,
    battery: batt,
    capturedAt: DateTime.utc(2026, 7, 16, 12),
  );

  test('a low battery on a fix posts the reminder', () async {
    // The whole feature, end to end from the isolate's point of view: `batt`
    // rides in on a location fix, and a notification comes out.
    final r = await build(serverEnabled: true, reengageEnabled: true);

    await r.onFix(fix(batt: 9));

    expect(notif.shown, hasLength(1));
    expect(notif.shown.single.id, NotifId.batteryLow);
  });

  test('a healthy battery says nothing', () async {
    final r = await build(serverEnabled: true, reengageEnabled: true);
    await r.onFix(fix(batt: 80));
    expect(notif.shown, isEmpty);
  });

  test(
    'a fix with no battery level says nothing rather than guessing',
    () async {
      final r = await build(serverEnabled: true, reengageEnabled: true);
      await r.onFix(fix());
      expect(notif.shown, isEmpty);
    },
  );

  test('the user opt-in is required — it defaults to OFF', () async {
    final r = await build(serverEnabled: true, reengageEnabled: false);
    await r.onFix(fix(batt: 3));
    expect(notif.shown, isEmpty);
  });

  test("the operator's kill-switch is required", () async {
    // Anti-stalking invariant: a device that has never heard the server say yes
    // notifies nobody, whatever the local opt-in says.
    final r = await build(serverEnabled: false, reengageEnabled: true);
    await r.onFix(fix(batt: 3));
    expect(notif.shown, isEmpty);
  });

  test('a persisting low battery reminds once, not once a fix', () async {
    final r = await build(serverEnabled: true, reengageEnabled: true);

    await r.onFix(fix(batt: 9));
    await r.onFix(fix(batt: 8));
    await r.onFix(fix(batt: 7));

    expect(notif.shown, hasLength(1), reason: 'anti-nagware');
  });

  test('an opt-out mid-drive is honoured without a service restart', () async {
    // The service outlives the UI: its prefs snapshot is frozen at whatever the
    // opt-ins were when Android last started it, hours ago. Without the reload
    // this evaluator does, turning the reminder off would do nothing until the
    // OS happened to restart the isolate.
    final r = await build(serverEnabled: true, reengageEnabled: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('retention.reengageEnabled', false);

    await r.onFix(fix(batt: 5));

    expect(notif.shown, isEmpty);
  });
}
