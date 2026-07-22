import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../controller.dart';
import '../../theme.dart';
import '../circles/circle_switcher.dart';

/// Circle ids — OTHER than the selected one — that currently have an ACTIVE SOS.
///
/// The realtime socket the app holds is scoped to the SELECTED circle (it carries
/// only that circle's keyring), so an SOS raised in another circle the user
/// belongs to would otherwise go unseen while the app is open. This polls each
/// non-selected circle's active-SOS list and surfaces the fact. The app can't
/// decrypt the other circle's alert (no keyring for it), but it CAN say "SOS in
/// that circle — tap to open", which is the safety-critical part; opening that
/// circle loads its keyring and shows the alert in full.
final crossCircleSosProvider = NotifierProvider<CrossCircleSos, Set<String>>(
  CrossCircleSos.new,
);

/// How often to sweep the user's other circles for an active SOS while the app is
/// open. The in-circle SOS is realtime; this cross-circle awareness is secondary,
/// so a modest cadence keeps it cheap (one GET per non-selected circle).
const Duration _kSweep = Duration(seconds: 30);

class CrossCircleSos extends Notifier<Set<String>> {
  Timer? _timer;
  bool _disposed = false;

  @override
  Set<String> build() {
    _disposed = false;
    final s = ref.watch(
      controllerProvider.select(
        (v) => (
          signedIn: v.phase == AuthPhase.signedIn,
          selected: v.selectedCircle?.id,
          n: v.circles.length, // re-sweep when the circle set changes
        ),
      ),
    );

    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
      _timer = null;
    });

    _timer?.cancel();
    if (!s.signedIn) return const {};

    _timer = Timer.periodic(_kSweep, (_) => unawaited(_sweep(s.selected)));
    unawaited(_sweep(s.selected));
    return const {};
  }

  Future<void> _sweep(String? selectedId) async {
    final ctrl = ref.read(controllerProvider.notifier);
    final circles = ref.read(controllerProvider).circles;
    final found = <String>{};
    for (final c in circles) {
      if (c.id == selectedId) continue; // the selected circle shows its SOS in-place
      try {
        // GET /sos returns only ACTIVE alerts, so a non-empty list means this
        // circle has one right now. Best-effort: a failed fetch just omits it.
        if ((await ctrl.loadSosAlerts(c.id)).isNotEmpty) found.add(c.id);
      } catch (_) {
        /* transient — the next sweep retries */
      }
    }
    if (!_disposed) state = found;
  }
}

/// A red, tappable banner shown on Home when a circle OTHER than the selected one
/// has an active SOS. Tapping it switches to that circle, where the alert opens in
/// full (with its keyring). Hidden when there is nothing to raise.
class CrossCircleSosBanner extends ConsumerWidget {
  const CrossCircleSosBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ids = ref.watch(crossCircleSosProvider);
    if (ids.isEmpty) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final names = ref.watch(circleNamesProvider).value ?? const {};
    final labels = ids.map((id) => names[id] ?? l10n.circleFallback).join(', ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        color: AulColors.danger,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () =>
              ref.read(controllerProvider.notifier).selectCircle(ids.first),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.sosInOtherCircle(labels),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
