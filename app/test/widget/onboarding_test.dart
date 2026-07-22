import 'package:aul/l10n/app_localizations.dart';
import 'package:aul/src/features/onboarding_screen.dart';
import 'package:aul/src/features/permissions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

/// Fake that grants everything without touching platform channels.
class _FakePerms extends AppPermissions {
  const _FakePerms();
  @override
  Future<PermissionStatus> requestNotifications() async =>
      PermissionStatus.granted;
  @override
  Future<PermissionStatus> requestWhileInUse() async =>
      PermissionStatus.granted;
  @override
  Future<PermissionStatus> requestBackground() async =>
      PermissionStatus.granted;
  @override
  Future<bool> requestIgnoreBatteryOptimizations() async => true;
}

void main() {
  testWidgets('onboarding walks all four steps then completes', (tester) async {
    var done = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: OnboardingScreen(
          perms: const _FakePerms(),
          onDone: () => done = true,
        ),
      ),
    );

    // Step 1: notifications (visible-notification honesty).
    expect(find.text('A visible, honest notification'), findsOneWidget);
    await tester.tap(find.text('Allow notifications'));
    await tester.pumpAndSettle();

    // Step 2: while-in-use location.
    expect(find.text('Location while using the app'), findsOneWidget);
    await tester.tap(find.text('Allow location'));
    await tester.pumpAndSettle();

    // Step 3: background.
    expect(find.text('Keep sharing in your pocket'), findsOneWidget);
    await tester.tap(find.text('Allow in background'));
    await tester.pumpAndSettle();

    // Step 4: battery optimization → finish.
    expect(find.textContaining('Don’t let the system sleep'), findsOneWidget);
    await tester.tap(find.text('Finish setup'));
    await tester.pumpAndSettle();

    expect(done, isTrue);
  });

  testWidgets('skip completes onboarding immediately', (tester) async {
    var done = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: OnboardingScreen(
          perms: const _FakePerms(),
          onDone: () => done = true,
        ),
      ),
    );
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    expect(done, isTrue);
  });
}
