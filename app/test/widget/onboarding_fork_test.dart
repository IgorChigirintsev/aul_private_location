import 'package:aul/l10n/app_localizations.dart';
import 'package:aul/src/controller.dart';
import 'package:aul/src/features/onboarding_fork.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A hermetic controller for the no-circle state: signed in, in no circle. The
/// fork should be what a brand-new signed-in user sees.
class _FakeController extends AppController {
  @override
  AppSession build() =>
      const AppSession(phase: AuthPhase.signedIn, email: 'me@example.com');
}

Widget _wrap(Widget child) => ProviderScope(
  overrides: [controllerProvider.overrideWith(() => _FakeController())],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: ListView(children: const [OnboardingFork()])),
  ),
);

void main() {
  testWidgets('the fork renders the two start options (no self-host)', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const OnboardingFork()));
    await tester.pumpAndSettle();

    // Create (primary) and Join. Self-host was dropped — a phone can't host a
    // server, so the fork offers only these two.
    expect(find.text('Create a circle'), findsWidgets); // title + CTA
    expect(find.text('Join a circle'), findsOneWidget);
    expect(find.text('Join with a link'), findsOneWidget);
    expect(find.text('Run your own server'), findsNothing);
    expect(find.text('Coming soon'), findsNothing);
  });

  testWidgets('tapping Join opens the paste-invite-link dialog', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const OnboardingFork()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Join with a link'));
    await tester.pumpAndSettle();

    // The exact join-by-link dialog: a field prompting to paste the invite link.
    expect(find.text('Join a circle'), findsWidgets);
    expect(find.text('Paste your invite link'), findsOneWidget);
    expect(find.widgetWithText(TextField, ''), findsOneWidget);
  });

  testWidgets('tapping Create opens the name-your-circle dialog', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const OnboardingFork()));
    await tester.pumpAndSettle();

    // Tap the CTA button specifically (the title text also reads "Create a
    // circle").
    await tester.tap(find.widgetWithText(FilledButton, 'Create a circle'));
    await tester.pumpAndSettle();

    expect(find.text('Name your circle'), findsOneWidget);
  });
}
