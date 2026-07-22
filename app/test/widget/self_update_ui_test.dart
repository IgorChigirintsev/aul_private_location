import 'package:aul/l10n/app_localizations.dart';
import 'package:aul/src/data/api/api_client.dart';
import 'package:aul/src/data/api/models.dart';
import 'package:aul/src/data/key_vault.dart';
import 'package:aul/src/data/secret_store.dart';
import 'package:aul/src/features/self_update.dart';
import 'package:aul/src/features/update_banner.dart';
import 'package:aul/src/features/update_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake that returns a canned "latest version" without any network or platform
/// channel. It extends [UpdateService] but overrides the only method the check
/// path calls, so the underlying [AulApi] is never actually used.
class _FakeUpdateService extends UpdateService {
  _FakeUpdateService(this._latest)
    : super(
        AulApi(baseUrl: 'http://test', vault: KeyVault(InMemorySecretStore())),
      );

  final AppVersionInfo? _latest;

  @override
  Future<AppVersionInfo?> checkForUpdate(int currentVersionCode) async {
    final latest = _latest;
    if (latest == null) return null;
    return latest.versionCode > currentVersionCode ? latest : null;
  }
}

ProviderContainer _container({AppVersionInfo? latest}) => ProviderContainer(
  overrides: [
    // Enable the Android-only feature on the test host.
    selfUpdateSupportedProvider.overrideWithValue(true),
    // Installed build 1 — no PackageInfo platform channel.
    currentVersionProvider.overrideWith(
      (_) async => const CurrentVersion(1, '1.0.0'),
    ),
    updateServiceProvider.overrideWithValue(_FakeUpdateService(latest)),
  ],
);

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const Scaffold(body: UpdateBanner()),
  ),
);

void main() {
  testWidgets('shows the update prompt when a newer version is available', (
    tester,
  ) async {
    final container = _container(
      latest: AppVersionInfo(
        versionCode: 2,
        versionName: '1.1.0',
        apkUrl: 'https://example.com/aul.apk',
        sha256: 'ab' * 32,
        changelog: 'Faster sync and bug fixes.',
      ),
    );
    addTearDown(container.dispose);

    // Drive the check deterministically before the widget builds.
    await container.read(updateControllerProvider.notifier).check();
    expect(
      container.read(updateControllerProvider).phase,
      UpdatePhase.available,
    );

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    expect(find.text('Update available'), findsOneWidget);
    expect(find.textContaining('1.1.0'), findsOneWidget);
    expect(find.text('Faster sync and bug fixes.'), findsOneWidget);
    expect(find.text('Update now'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget);
  });

  testWidgets('shows no prompt when there is no newer version', (tester) async {
    // Server reports the same build we already run → checkForUpdate() → null.
    final container = _container(
      latest: const AppVersionInfo(versionCode: 1, versionName: '1.0.0'),
    );
    addTearDown(container.dispose);

    await container.read(updateControllerProvider.notifier).check();
    expect(container.read(updateControllerProvider).phase, UpdatePhase.idle);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    expect(find.text('Update available'), findsNothing);
    expect(find.text('Update now'), findsNothing);
  });

  testWidgets('Later dismisses the prompt', (tester) async {
    final container = _container(
      latest: const AppVersionInfo(versionCode: 2, versionName: '1.1.0'),
    );
    addTearDown(container.dispose);

    await container.read(updateControllerProvider.notifier).check();
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    expect(find.text('Update available'), findsOneWidget);

    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();

    expect(find.text('Update available'), findsNothing);
    expect(container.read(updateControllerProvider).phase, UpdatePhase.idle);
  });
}
