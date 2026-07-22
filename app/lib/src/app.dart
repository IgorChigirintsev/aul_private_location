import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import 'controller.dart';
import 'features/home_screen.dart';
import 'features/locale_controller.dart';
import 'features/login_screen.dart';
import 'features/onboarding_screen.dart';
import 'features/permissions.dart';
import 'features/theme_controller.dart';
import 'theme.dart';

class AulApp extends ConsumerWidget {
  const AulApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // null locale = follow the system; a value pins the chosen language.
    final locale = ref.watch(localeControllerProvider);
    // ThemeMode.system = follow the device; light/dark pin it (Settings).
    final themeMode = ref.watch(themeControllerProvider);
    return MaterialApp(
      title: 'Aul', // brand — not localized
      debugShowCheckedModeBanner: false,
      theme: aulLightTheme(),
      darkTheme: aulDarkTheme(),
      themeMode: themeMode, // system by default; overridable in Settings
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const _Root(),
    );
  }
}

class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(controllerProvider);
    switch (s.phase) {
      case AuthPhase.loading:
        return const _Splash();
      case AuthPhase.signedOut:
        return const LoginScreen();
      case AuthPhase.signedIn:
        return const _SignedInFlow();
    }
  }
}

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

/// After sign-in, gate on the location permissions with the educational
/// onboarding; once ready (or skipped), show Home.
class _SignedInFlow extends StatefulWidget {
  const _SignedInFlow();
  @override
  State<_SignedInFlow> createState() => _SignedInFlowState();
}

class _SignedInFlowState extends State<_SignedInFlow> {
  final _perms = const AppPermissions();
  bool _checking = true;
  bool _needsOnboarding = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final ready = await _perms.ready();
    if (mounted) {
      setState(() {
        _checking = false;
        _needsOnboarding = !ready;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) return const _Splash();
    if (_needsOnboarding) {
      return OnboardingScreen(
        perms: _perms,
        onDone: () => setState(() => _needsOnboarding = false),
      );
    }
    return const HomeScreen();
  }
}
