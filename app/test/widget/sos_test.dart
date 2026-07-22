import 'package:aul/l10n/app_localizations.dart';
import 'package:aul/src/features/sos_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('SOS fires only after long-press + confirmation', (tester) async {
    var confirmed = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(child: SosButton(onConfirmed: () => confirmed = true)),
        ),
      ),
    );

    // A plain tap must NOT trigger SOS (avoids accidents).
    await tester.tap(find.byType(SosButton));
    await tester.pumpAndSettle();
    expect(find.text('Send SOS?'), findsNothing);
    expect(confirmed, isFalse);

    // Long-press shows the confirmation.
    await tester.longPress(find.byType(SosButton));
    await tester.pumpAndSettle();
    expect(find.text('Send SOS?'), findsOneWidget);

    // Cancelling does not fire.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(confirmed, isFalse);

    // Long-press again and confirm.
    await tester.longPress(find.byType(SosButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send SOS'));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });

  testWidgets('a disabled SOS cannot fire and says why', (tester) async {
    var confirmed = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SosButton(
              enabled: false,
              onConfirmed: () => confirmed = true,
            ),
          ),
        ),
      ),
    );

    // No circle key on this device: the long-press must not even offer to send.
    await tester.longPress(find.byType(SosButton));
    await tester.pumpAndSettle();
    expect(find.text('Send SOS?'), findsNothing);
    expect(confirmed, isFalse);

    // A tap explains rather than silently doing nothing. (Scoped to the
    // snackbar: the long-press above also surfaced the tooltip, which says the
    // same thing.)
    await tester.tap(find.byType(SosButton));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.textContaining('No circle key on this device'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a tap on the enabled button explains the hold gesture', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(child: SosButton(onConfirmed: () {})),
        ),
      ),
    );

    await tester.tap(find.byType(SosButton));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.textContaining('Hold the SOS button'),
      ),
      findsOneWidget,
    );
  });
}
