import 'package:aul/src/features/retention/retention_controller.dart';
import 'package:aul/src/features/retention/retention_prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every opt-in defaults OFF and persists when set', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = RetentionPrefs(await SharedPreferences.getInstance());

    expect(prefs.arrivalEnabled, isFalse);
    expect(prefs.reengageEnabled, isFalse);
    for (final f in RetentionFeature.values) {
      expect(prefs.enabled(f), isFalse);
    }

    await prefs.setEnabled(RetentionFeature.arrival, true);
    expect(prefs.arrivalEnabled, isTrue);
    expect(prefs.reengageEnabled, isFalse); // others untouched

    // Survives a reload from storage.
    final reloaded = RetentionPrefs(await SharedPreferences.getInstance());
    expect(reloaded.arrivalEnabled, isTrue);
    expect(reloaded.reengageEnabled, isFalse);
  });

  test(
    'RetentionState: a feature is active iff serverEnabled AND its opt-in',
    () {
      const off = RetentionState();
      for (final f in RetentionFeature.values) {
        expect(off.enabled(f), isFalse); // defaults OFF
        expect(off.active(f), isFalse);
      }
      expect(off.serverEnabled, isFalse);

      const optInOnly = RetentionState(arrivalEnabled: true);
      expect(optInOnly.arrivalActive, isFalse); // server kill-switch off

      const serverOnly = RetentionState(serverEnabled: true);
      expect(serverOnly.arrivalActive, isFalse); // user opted out

      const both = RetentionState(serverEnabled: true, arrivalEnabled: true);
      expect(both.arrivalActive, isTrue);
      expect(both.active(RetentionFeature.arrival), isTrue);
      expect(both.reengageActive, isFalse);
    },
  );
}
