import 'package:aul/l10n/app_localizations.dart';
import 'package:aul/src/features/about_screen.dart';
import 'package:aul/src/features/retention/retention_controller.dart';
import 'package:aul/src/features/retention/retention_prefs.dart';
import 'package:aul/src/features/update_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A hermetic RetentionController with a fixed state and in-memory toggles — no
/// SharedPreferences, no server call.
class _FakeRetentionController extends RetentionController {
  _FakeRetentionController(this._initial);
  final RetentionState _initial;

  @override
  RetentionState build() => _initial;

  @override
  Future<void> toggle(RetentionFeature f, bool value) async {
    state = switch (f) {
      RetentionFeature.arrival => state.copyWith(arrivalEnabled: value),
      RetentionFeature.reengage => state.copyWith(reengageEnabled: value),
      RetentionFeature.push => state.copyWith(pushEnabled: value),
    };
  }
}

Widget _app(RetentionState initial) => ProviderScope(
  overrides: [
    // Keep the update section inert (no PackageInfo / network).
    selfUpdateSupportedProvider.overrideWithValue(false),
    currentVersionProvider.overrideWith(
      (_) async => const CurrentVersion(1, '1.0.0'),
    ),
    retentionProvider.overrideWith(() => _FakeRetentionController(initial)),
  ],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const AboutScreen(),
  ),
);

void main() {
  testWidgets('toggles render OFF by default and interactive when server-on', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const RetentionState(serverEnabled: true, loaded: true)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Location extras'), findsOneWidget);
    final switches = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .toList();
    expect(switches, hasLength(2));
    for (final s in switches) {
      expect(s.value, isFalse); // default OFF
      expect(s.onChanged, isNotNull); // interactive (server flag on)
    }
  });

  testWidgets('toggles are disabled when the server kill-switch is off', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const RetentionState(serverEnabled: false, loaded: true)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('turned these features off'), findsOneWidget);
    final switches = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .toList();
    expect(switches, hasLength(2));
    for (final s in switches) {
      expect(s.onChanged, isNull); // cannot be turned on
      expect(s.value, isFalse);
    }
  });

  group('background push toggle', () {
    testWidgets('hidden when the operator configured no FCM', (tester) async {
      // serverEnabled but fcm_enabled=false: there is no push to opt into, so
      // the switch is absent rather than offered and then failing.
      await tester.pumpWidget(
        _app(const RetentionState(serverEnabled: true, loaded: true)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Notifications while Aul is closed'), findsNothing);
      expect(find.byType(SwitchListTile), findsNWidgets(2));
    });

    testWidgets('hidden when the server kill-switch is off, even with FCM', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const RetentionState(
            serverEnabled: false,
            fcmEnabled: true,
            loaded: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Notifications while Aul is closed'), findsNothing);
    });

    testWidgets('offered, OFF by default, when the server can push', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const RetentionState(
            serverEnabled: true,
            fcmEnabled: true,
            loaded: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Notifications while Aul is closed'), findsOneWidget);
      final switches = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .toList();
      expect(switches, hasLength(3));
      // Anti-stalking default: opted OUT until the user chooses in.
      expect(switches.last.value, isFalse);
      expect(switches.last.onChanged, isNotNull);
    });

    testWidgets('flips on tap', (tester) async {
      await tester.pumpWidget(
        _app(
          const RetentionState(
            serverEnabled: true,
            fcmEnabled: true,
            loaded: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // It is the last row of a long scrolling page — scroll it in first.
      await tester.ensureVisible(
        find.text('Notifications while Aul is closed'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notifications while Aul is closed'));
      await tester.pumpAndSettle();

      final switches = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .toList();
      expect(switches.last.value, isTrue);
    });
  });
}
