import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../data/api/models.dart';
import '../theme.dart';
import 'update_controller.dart';

/// A non-intrusive in-app update prompt shown at the top of Home. On first build
/// it kicks off a best-effort startup check (errors are swallowed — being
/// offline is normal). It renders nothing until a newer version is found.
class UpdateBanner extends ConsumerStatefulWidget {
  const UpdateBanner({super.key});

  @override
  ConsumerState<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends ConsumerState<UpdateBanner> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(updateControllerProvider).phase == UpdatePhase.idle) {
        ref.read(updateControllerProvider.notifier).check();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(updateControllerProvider);
    if (!s.showPrompt) return const SizedBox.shrink();
    final info = s.available!;
    final ctrl = ref.read(updateControllerProvider.notifier);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: UpdatePromptCard(state: s, info: info, ctrl: ctrl),
    );
  }
}

/// The prompt body, shared by the Home banner and the About screen.
class UpdatePromptCard extends StatelessWidget {
  const UpdatePromptCard({
    super.key,
    required this.state,
    required this.info,
    required this.ctrl,
  });

  final UpdateState state;
  final AppVersionInfo info;
  final UpdateController ctrl;

  @override
  Widget build(BuildContext context) {
    final v = info;
    final l10n = AppLocalizations.of(context);
    final isError = state.phase == UpdatePhase.error;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isError ? Icons.error_outline : Icons.system_update,
                  color: isError
                      ? AulColors.danger
                      : Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isError ? l10n.updateProblem : l10n.updateAvailable,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (isError)
              Text(
                state.error ?? l10n.updateGenericError,
                style: TextStyle(
                  color: state.integrityFailure
                      ? AulColors.danger
                      : AulColors.textSecondary,
                  fontWeight: state.integrityFailure
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
              )
            else ...[
              Text(
                l10n.updateReadyToInstall(v.versionName),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (v.changelog != null && v.changelog!.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  v.changelog!,
                  style: const TextStyle(
                    color: AulColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ],
            const SizedBox(height: 12),
            _actions(context),
          ],
        ),
      ),
    );
  }

  Widget _actions(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    switch (state.phase) {
      case UpdatePhase.downloading:
        return _PendingRow(label: l10n.updateDownloading);
      case UpdatePhase.installing:
        return _PendingRow(label: l10n.updateInstalling);
      case UpdatePhase.error:
        return Row(
          children: [
            TextButton(onPressed: ctrl.dismiss, child: Text(l10n.later)),
            const Spacer(),
            FilledButton(
              onPressed: ctrl.startUpdate,
              child: Text(l10n.tryAgain),
            ),
          ],
        );
      default:
        return Row(
          children: [
            TextButton(onPressed: ctrl.dismiss, child: Text(l10n.later)),
            const Spacer(),
            FilledButton(
              onPressed: ctrl.startUpdate,
              child: Text(l10n.updateNow),
            ),
          ],
        );
    }
  }
}

class _PendingRow extends StatelessWidget {
  const _PendingRow({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      const SizedBox(width: 12),
      Text(label, style: const TextStyle(color: AulColors.textSecondary)),
    ],
  );
}
