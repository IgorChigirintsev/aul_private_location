import 'package:aul/l10n/app_localizations.dart';
import 'package:aul/src/features/circles/circle_switcher.dart';
import 'package:aul/src/features/sos/cross_circle_sos.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives the provider state directly — no polling, no server — so the test pins
/// the BANNER: it appears (and names the other circle) exactly when a non-selected
/// circle has an active SOS, and renders nothing otherwise.
class _FakeCross extends CrossCircleSos {
  _FakeCross(this._ids);
  final Set<String> _ids;

  @override
  Set<String> build() => _ids; // no timer/sweep in the test
}

void main() {
  Widget harness(ProviderContainer c) => UncontrolledProviderScope(
    container: c,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: CrossCircleSosBanner()),
    ),
  );

  ProviderContainer withIds(Set<String> ids) {
    final c = ProviderContainer(
      overrides: [
        crossCircleSosProvider.overrideWith(() => _FakeCross(ids)),
        circleNamesProvider.overrideWith((ref) async => const {'c2': 'Bishkek'}),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  testWidgets('names the other circle with an active SOS, in red', (
    tester,
  ) async {
    await tester.pumpWidget(harness(withIds({'c2'})));
    await tester.pumpAndSettle(); // resolve the circle-names future

    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.textContaining('Bishkek'), findsOneWidget);
  });

  testWidgets('renders nothing when no other circle has an SOS', (tester) async {
    await tester.pumpWidget(harness(withIds({})));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    expect(find.byType(Card), findsNothing);
  });
}
