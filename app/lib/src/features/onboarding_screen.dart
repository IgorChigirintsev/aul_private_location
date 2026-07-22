import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme.dart';
import 'permissions.dart';

/// Progressive, educational permission onboarding. Each step explains WHY before
/// requesting, and the reporter is always visible (no hidden mode).
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.onDone,
    this.perms = const AppPermissions(),
  });

  final VoidCallback onDone;
  final AppPermissions perms;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0;
  bool _busy = false;

  Future<void> _next() async {
    setState(() => _busy = true);
    switch (_step) {
      case 0:
        await widget.perms.requestNotifications();
        break;
      case 1:
        await widget.perms.requestWhileInUse();
        break;
      case 2:
        await widget.perms.requestBackground();
        break;
      case 3:
        await widget.perms.requestIgnoreBatteryOptimizations();
        break;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (_step < 3) {
        _step++;
      } else {
        widget.onDone();
      }
    });
  }

  static const _stepCount = 4;

  List<({IconData icon, String title, String body, String cta})> _steps(
    AppLocalizations l10n,
  ) => [
    (
      icon: Icons.notifications_active_outlined,
      title: l10n.onboardingNotifTitle,
      body: l10n.onboardingNotifBody,
      cta: l10n.onboardingNotifCta,
    ),
    (
      icon: Icons.my_location_outlined,
      title: l10n.onboardingLocationTitle,
      body: l10n.onboardingLocationBody,
      cta: l10n.onboardingLocationCta,
    ),
    (
      icon: Icons.security_outlined,
      title: l10n.onboardingBackgroundTitle,
      body: l10n.onboardingBackgroundBody,
      cta: l10n.onboardingBackgroundCta,
    ),
    (
      icon: Icons.battery_charging_full_outlined,
      title: l10n.onboardingBatteryTitle,
      body: l10n.onboardingBatteryBody,
      cta: l10n.onboardingBatteryCta,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final steps = _steps(l10n);
    final s = steps[_step];
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 8),
              Row(
                children: [
                  for (var i = 0; i < _stepCount; i++)
                    Expanded(
                      child: Container(
                        height: 4,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: i <= _step
                              ? Theme.of(context).colorScheme.primary
                              : AulColors.border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
              const Spacer(),
              Icon(
                s.icon,
                size: 72,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                s.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                s.body,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AulColors.textSecondary,
                  height: 1.5,
                ),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _busy ? null : _next,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(s.cta),
              ),
              TextButton(
                onPressed: _busy ? null : widget.onDone,
                child: Text(l10n.onboardingSkip),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
