import 'package:aul/l10n/app_localizations.dart';
import 'package:aul/src/features/sos_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps [child] inside a MaterialApp pinned to [locale] with the app's
/// localization delegates wired up.
Widget _localized(Locale locale, Widget child) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('renders Russian strings under Locale(ru)', (tester) async {
    await tester.pumpWidget(
      _localized(const Locale('ru'), SosButton(onConfirmed: () {})),
    );
    await tester.pumpAndSettle();

    // The hold instruction is translated, and the English original is gone. It
    // lives in the tooltip/semantics now that the button is a 72 px floating
    // action with no room for a caption in every language.
    expect(find.byTooltip('Удерживайте для SOS'), findsOneWidget);
    expect(find.byTooltip('Hold for SOS'), findsNothing);

    // The confirmation dialog is Russian too.
    await tester.longPress(find.byType(SosButton));
    await tester.pumpAndSettle();
    expect(find.text('Отправить SOS?'), findsOneWidget);
    expect(find.text('Отправить SOS'), findsOneWidget);
  });

  testWidgets('renders English strings under Locale(en)', (tester) async {
    await tester.pumpWidget(
      _localized(const Locale('en'), SosButton(onConfirmed: () {})),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Hold for SOS'), findsOneWidget);

    await tester.longPress(find.byType(SosButton));
    await tester.pumpAndSettle();
    expect(find.text('Send SOS?'), findsOneWidget);
  });

  testWidgets('the disabled SOS explains itself in the active language', (
    tester,
  ) async {
    await tester.pumpWidget(
      _localized(
        const Locale('ru'),
        SosButton(onConfirmed: () {}, enabled: false),
      ),
    );
    await tester.pumpAndSettle();

    // Not "hold for SOS" — a button that cannot fire must not promise it will.
    expect(find.byTooltip('Удерживайте для SOS'), findsNothing);
    expect(
      find.byTooltip(
        'На этом устройстве нет ключа круга — зашифровать SOS пока не для кого.',
      ),
      findsOneWidget,
    );
  });
}
