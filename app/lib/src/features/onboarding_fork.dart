import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../controller.dart';
import '../theme.dart';
import 'circles/circle_switcher.dart';

/// The no-circle "fork": shown once a user is signed in but is in no circle yet.
/// It offers an explicit choice of how to start, mirroring the web onboarding —
/// create a circle on our server (the primary path), join an existing one from
/// an invite link, or (coming soon) run their own server. There is nothing
/// useful to do on Home without a circle, so this replaces the empty Home
/// content until the first circle exists.
class OnboardingFork extends ConsumerWidget {
  const OnboardingFork({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.forkTitle,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.forkSubtitle,
          style: const TextStyle(color: AulColors.textSecondary),
        ),
        const SizedBox(height: 16),
        // Primary path: create a circle on our server.
        _ForkCard(
          icon: Icons.add_circle_outline,
          title: l10n.forkCreateTitle,
          body: l10n.forkCreateBody,
          action: FilledButton(
            onPressed: () => showCreateCircleDialog(context, ref),
            child: Text(l10n.forkCreateCta),
          ),
        ),
        const SizedBox(height: 12),
        // Join an existing circle from a pasted invite link. Reuses the exact
        // join-by-link flow (K_c rides in the link fragment, never sent).
        _ForkCard(
          icon: Icons.link,
          title: l10n.forkJoinTitle,
          body: l10n.forkJoinBody,
          action: OutlinedButton.icon(
            onPressed: () => showJoinCircleDialog(context, ref),
            icon: const Icon(Icons.link, size: 18),
            label: Text(l10n.forkJoinCta),
          ),
        ),
        // Self-host is deliberately NOT offered in the app: a phone can't host a
        // server. It lives only on desktop web (StartChoice), gated to ≥768px.
      ],
    );
  }
}

/// One option card in the fork. [disabled] dims the whole card for the
/// not-yet-available option; [badge] shows a "coming soon" pill by the title.
class _ForkCard extends StatelessWidget {
  const _ForkCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              body,
              style: const TextStyle(
                color: AulColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: action),
          ],
        ),
      ),
    );
  }
}

/// Prompts for a circle name and creates it on the server. Mirrors the circle
/// switcher's create action (same controller method, same strings), so a user
/// with no circle can take the primary path straight from the fork.
Future<void> showCreateCircleDialog(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context);
  final ctl = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(l10n.createCircle),
      content: TextField(
        controller: ctl,
        autofocus: true,
        decoration: InputDecoration(hintText: l10n.createCircleHint),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, ctl.text),
          child: Text(l10n.create),
        ),
      ],
    ),
  );
  if (name == null || name.trim().isEmpty || !context.mounted) return;
  final ok = await ref
      .read(controllerProvider.notifier)
      .createCircle(name.trim());
  if (!context.mounted) return;
  ref.invalidate(circleNamesProvider);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(ok ? l10n.circleCreated : l10n.circleActionFailed)),
  );
}

/// Opens the paste-an-invite-link dialog and joins by link. This is the exact
/// join-by-link flow used elsewhere on Home: `joinByLink` parses the link and
/// keeps K_c (which lives in the link fragment) local — it is never sent to the
/// server, and the link is never logged.
Future<void> showJoinCircleDialog(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context);
  final ctl = TextEditingController();
  final link = await showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(l10n.joinCircleTitle),
      content: TextField(
        controller: ctl,
        decoration: InputDecoration(hintText: l10n.joinCircleHint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, ctl.text),
          child: Text(l10n.join),
        ),
      ],
    ),
  );
  if (link == null || link.isEmpty) return;
  final ok = await ref.read(controllerProvider.notifier).joinByLink(link);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? l10n.joinedCircle : l10n.couldNotJoin)),
    );
  }
}
