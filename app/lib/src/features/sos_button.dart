import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme.dart';

/// SOS trigger: long-press (to avoid accidental taps) → confirmation → fire.
///
/// A distinct floating action anchored bottom-right of the main screen, red
/// (danger is reserved for SOS only, per the design system) and never folded
/// into a card or the app bar: in an emergency the control has to be exactly
/// where the thumb already is, not somewhere that has to be found.
///
/// [enabled] is false when no circle on this device holds a key — pressing then
/// could only fail, so the button says so instead of pretending. Kept as its own
/// widget so it is easy to widget-test.
class SosButton extends StatelessWidget {
  const SosButton({super.key, required this.onConfirmed, this.enabled = true});

  final VoidCallback onConfirmed;

  /// Whether an SOS could actually be sealed and sent (a circle key is present).
  final bool enabled;

  Future<void> _confirm(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.sosSendTitle),
        content: Text(l10n.sosSendBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AulColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.sosSend),
          ),
        ],
      ),
    );
    if (ok == true) onConfirmed();
  }

  /// A tap explains rather than fires: the gesture is deliberately a long-press,
  /// so a tap is either an accident or someone who doesn't know that yet.
  void _explain(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(enabled ? l10n.sosHoldHint : l10n.sosNoKeyHint),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final color = enabled ? AulColors.danger : AulColors.textSecondary;
    return Semantics(
      button: true,
      enabled: enabled,
      label: l10n.sosSemantic,
      child: Tooltip(
        message: enabled ? l10n.sosHold : l10n.sosNoKeyHint,
        child: GestureDetector(
          onLongPress: enabled ? () => _confirm(context) : null,
          onTap: () => _explain(context),
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: enabled
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.4),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            // The icon carries the whole meaning: "SOS" reads the same in every
            // language, and a 72 px circle has no room for a truthful label in
            // all of them. The hold instruction lives in the tooltip, the
            // semantics label, and the snackbar a tap gets.
            child: const Icon(Icons.sos, color: Colors.white, size: 32),
          ),
        ),
      ),
    );
  }
}
