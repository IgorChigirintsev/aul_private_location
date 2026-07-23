import 'package:aul/l10n/app_localizations.dart';
import 'package:aul/src/controller.dart';
import 'package:aul/src/defaults.dart';
import 'package:aul/src/features/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Signed out — the state a first-time user actually meets.
class _FakeController extends AppController {
  @override
  AppSession build() => const AppSession(phase: AuthPhase.signedOut);
}

Widget _wrap() => ProviderScope(
  overrides: [controllerProvider.overrideWith(() => _FakeController())],
  child: const MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: LoginScreen(),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// The field shipped blank, which made a first run a dead end: nothing on the
  /// screen said what a "server" was, and submitting empty surfaced only
  /// "network error" — indistinguishable from the app being broken.
  testWidgets('the server field arrives filled in, not blank', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text(kDefaultServerUrl), findsOneWidget);
  });

  /// helperText, unlike hintText, is visible while the field is unfocused —
  /// which is exactly when someone is deciding whether to touch it at all.
  testWidgets('the server field explains itself without being focused', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(
      find.text("Aul's public server. Change it only if you host your own."),
      findsOneWidget,
    );
  });

  /// The full picker lives in About, which is reachable only AFTER signing in.
  /// Anyone whose device resolved to the wrong language was stuck until then.
  testWidgets('the language can be changed before signing in', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.language), findsOneWidget);

    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();

    expect(find.text('System'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Русский'), findsOneWidget);
  });
}
