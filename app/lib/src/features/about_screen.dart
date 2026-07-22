import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../theme.dart';
import 'locale_controller.dart';
import 'retention/retention_controller.dart';
import 'theme_controller.dart';
import 'retention/retention_prefs.dart';
import 'update_banner.dart';
import 'update_controller.dart';

/// About & updates. Shows the installed version and lets the user manually check
/// for and install a newer build (Android sideload only).
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(currentVersionProvider);
    final supported = ref.watch(selfUpdateSupportedProvider);
    final update = ref.watch(updateControllerProvider);
    final ctrl = ref.read(updateControllerProvider.notifier);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.aboutTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Aul', // brand — not localized
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.aboutTagline,
                    style: const TextStyle(color: AulColors.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  _versionRow(l10n, version),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (!supported)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  l10n.updatesManagedByStore,
                  style: const TextStyle(color: AulColors.textSecondary),
                ),
              ),
            )
          else ...[
            // When an update is available (or mid-install / errored), show the
            // same prompt the Home banner uses.
            if (update.showPrompt && update.available != null)
              UpdatePromptCard(
                state: update,
                info: update.available!,
                ctrl: ctrl,
              )
            else
              _CheckCard(
                state: update,
                onCheck: () => ctrl.check(manual: true),
              ),
          ],
          const SizedBox(height: 16),
          const _RetentionSection(),
          const SizedBox(height: 16),
          const _LanguageSection(),
          const _ThemeSection(),
        ],
      ),
    );
  }

  Widget _versionRow(
    AppLocalizations l10n,
    AsyncValue<CurrentVersion> version,
  ) {
    final text = version.when(
      data: (v) => l10n.aboutVersionValue(v.versionName, v.versionCode),
      loading: () => '…',
      error: (_, _) => l10n.aboutVersionUnknown,
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          l10n.aboutVersionLabel,
          style: const TextStyle(color: AulColors.textSecondary),
        ),
        Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _CheckCard extends StatelessWidget {
  const _CheckCard({required this.state, required this.onCheck});
  final UpdateState state;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final checking = state.phase == UpdatePhase.checking;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.phase == UpdatePhase.upToDate)
              _StatusLine(
                icon: Icons.check_circle_outline,
                color: AulColors.success,
                text: l10n.updateUpToDate,
              )
            else if (state.phase == UpdatePhase.error)
              _StatusLine(
                icon: Icons.error_outline,
                color: AulColors.danger,
                text: state.error ?? l10n.updateCheckError,
              )
            else
              Text(
                l10n.updateCheckPrompt,
                style: const TextStyle(color: AulColors.textSecondary),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: checking ? null : onCheck,
              child: checking
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.updateCheckButton),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opt-in controls for the retention features. Every toggle defaults OFF
/// and requires the server kill-switch to be on to actually activate; when the
/// server has turned the features off the toggles are disabled with a note.
class _RetentionSection extends ConsumerWidget {
  const _RetentionSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(retentionProvider);
    final ctrl = ref.read(retentionProvider.notifier);
    final l10n = AppLocalizations.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.locationExtras,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.locationExtrasSubtitle,
              style: const TextStyle(
                color: AulColors.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
            if (!r.serverEnabled)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  l10n.serverDisabledFeatures,
                  style: const TextStyle(
                    color: AulColors.textSecondary,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            _FeatureSwitch(
              title: l10n.arrivalAlertsTitle,
              subtitle: l10n.arrivalAlertsSubtitle,
              value: r.arrivalEnabled,
              enabled: r.serverEnabled,
              onChanged: (v) => ctrl.toggle(RetentionFeature.arrival, v),
            ),
            _FeatureSwitch(
              title: l10n.trackingRemindersTitle,
              subtitle: l10n.trackingRemindersSubtitle,
              value: r.reengageEnabled,
              enabled: r.serverEnabled,
              onChanged: (v) => ctrl.toggle(RetentionFeature.reengage, v),
            ),
            // Hidden, not merely disabled, when the operator configured no FCM:
            // there is no push to opt into, so offering the switch and then
            // failing would be the worse of the two.
            if (r.pushAvailable)
              _FeatureSwitch(
                title: l10n.pushAlertsTitle,
                subtitle: l10n.pushAlertsSubtitle,
                value: r.pushEnabled,
                enabled: true,
                onChanged: (v) => ctrl.toggle(RetentionFeature.push, v),
              ),
          ],
        ),
      ),
    );
  }
}

/// Language picker: System (follow the device) / English / Русский. Persisted
/// via [localeControllerProvider]; null = follow the system.
class _LanguageSection extends ConsumerWidget {
  const _LanguageSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final ctrl = ref.read(localeControllerProvider.notifier);
    // Encode the tri-state (system / en / ru) as a nullable language code.
    final selected = ref.watch(localeControllerProvider)?.languageCode;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.language,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            _ChoiceOption(
              label: l10n.languageSystem,
              selected: selected == null,
              onTap: () => ctrl.setLocale(null),
            ),
            _ChoiceOption(
              label: l10n.languageEnglish,
              selected: selected == 'en',
              onTap: () => ctrl.setLocale(const Locale('en')),
            ),
            _ChoiceOption(
              label: l10n.languageRussian,
              selected: selected == 'ru',
              onTap: () => ctrl.setLocale(const Locale('ru')),
            ),
          ],
        ),
      ),
    );
  }
}

/// Theme picker: System (follow the device) / Light / Dark. Persisted via
/// [themeControllerProvider]; [ThemeMode.system] follows the device.
class _ThemeSection extends ConsumerWidget {
  const _ThemeSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final ctrl = ref.read(themeControllerProvider.notifier);
    final mode = ref.watch(themeControllerProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.themeLabel,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            _ChoiceOption(
              label: l10n.themeSystem,
              selected: mode == ThemeMode.system,
              onTap: () => ctrl.setMode(ThemeMode.system),
            ),
            _ChoiceOption(
              label: l10n.themeLight,
              selected: mode == ThemeMode.light,
              onTap: () => ctrl.setMode(ThemeMode.light),
            ),
            _ChoiceOption(
              label: l10n.themeDark,
              selected: mode == ThemeMode.dark,
              onTap: () => ctrl.setMode(ThemeMode.dark),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChoiceOption extends StatelessWidget {
  const _ChoiceOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    trailing: selected
        ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
        : null,
    onTap: onTap,
  );
}

class _FeatureSwitch extends StatelessWidget {
  const _FeatureSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text(
      subtitle,
      style: const TextStyle(color: AulColors.textSecondary, fontSize: 12),
    ),
    // Off when the server disabled the features; the value is still shown so the
    // user knows their stored preference.
    value: enabled && value,
    onChanged: enabled ? onChanged : null,
  );
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.icon,
    required this.color,
    required this.text,
  });
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, color: color, size: 20),
      const SizedBox(width: 8),
      Expanded(child: Text(text)),
    ],
  );
}
