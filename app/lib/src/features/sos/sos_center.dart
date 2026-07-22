import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../controller.dart';
import '../../domain/sos_alert.dart';
import '../../theme.dart';
import '../realtime/realtime_controller.dart';

/// The SOS centre: shows the selected circle's active SOS alerts, decrypted
/// under K_c — a red banner per alert with who/when, the message + last-known
/// location when it decrypts, or a metadata-only banner when it doesn't so no
/// emergency is ever silently missed — each with a Resolve action. Mirrors the
/// web SosBanner.
///
/// The realtime socket delivers an SOS the moment it is raised (or resolved).
/// The ~30 s poll stays underneath it: an emergency alert is the LAST thing that
/// may depend on a socket being up, so it is checked on a timer regardless.
///
/// This only covers alerts while the app is OPEN, and only for the selected
/// circle. Being told about an SOS in a backgrounded app needs push (FCM), which
/// is not wired up.
///
/// Shows nothing when there are no active alerts. The decode/undecryptable path
/// lives in [SosCodec] and is unit-tested separately; this widget is the
/// polling + rendering shell.
class SosCenter extends ConsumerStatefulWidget {
  const SosCenter({super.key, required this.circleId});

  /// The circle to watch, or null (no selected circle) to show nothing.
  final String? circleId;

  @override
  ConsumerState<SosCenter> createState() => _SosCenterState();
}

class _SosCenterState extends ConsumerState<SosCenter> {
  static const _pollInterval = Duration(seconds: 30);

  Timer? _timer;
  List<SosAlert> _alerts = const [];
  final Set<String> _resolving = {};

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(_pollInterval, (_) => unawaited(_refresh()));
  }

  @override
  void didUpdateWidget(covariant SosCenter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.circleId != widget.circleId) {
      setState(() => _alerts = const []);
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final circleId = widget.circleId;
    if (circleId == null) {
      if (mounted && _alerts.isNotEmpty) setState(() => _alerts = const []);
      return;
    }
    final alerts = await ref
        .read(controllerProvider.notifier)
        .loadSosAlerts(circleId);
    // Guard against a circle switch (or teardown) mid-fetch.
    if (!mounted || circleId != widget.circleId) return;
    setState(() => _alerts = alerts);
  }

  Future<void> _resolve(SosAlert alert) async {
    final circleId = widget.circleId;
    if (circleId == null) return;
    // Optimistically drop it; a failed resolve re-surfaces on the next poll.
    setState(() {
      _resolving.add(alert.id);
      _alerts = _alerts.where((a) => a.id != alert.id).toList();
    });
    try {
      await ref
          .read(controllerProvider.notifier)
          .resolveSosAlert(circleId, alert.id);
    } catch (_) {
      // best effort — the next poll reconciles with the server
    } finally {
      if (mounted) setState(() => _resolving.remove(alert.id));
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    // An SOS was raised or resolved. Refetch through the normal decrypting path
    // rather than trusting the event's payload — the alert list is the thing that
    // decides whether a banner is shown, and one loading path means one behaviour
    // whether the news arrived over the socket or the timer.
    ref.listen(realtimeProvider.select((r) => r.sos), (_, _) {
      unawaited(_refresh());
    });

    if (_alerts.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final a in _alerts)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _SosAlertBanner(
              alert: a,
              resolving: _resolving.contains(a.id),
              onResolve: () => _resolve(a),
            ),
          ),
      ],
    );
  }
}

/// A single red SOS banner: title, decrypted message + last-known location (or a
/// metadata-only line when the payload can't be opened), the time it was raised,
/// and a Resolve action. Danger colour is reserved for SOS per the design system.
class _SosAlertBanner extends StatelessWidget {
  const _SosAlertBanner({
    required this.alert,
    required this.resolving,
    required this.onResolve,
  });

  final SosAlert alert;
  final bool resolving;
  final VoidCallback onResolve;

  String _subtitle(AppLocalizations l10n) {
    if (!alert.decrypted) return l10n.sosCenterEncrypted;
    final msg = alert.message?.trim();
    final base = (msg == null || msg.isEmpty) ? l10n.sosCenterNoMessage : msg;
    if (alert.hasLocation) {
      final coords =
          '${alert.lat!.toStringAsFixed(4)}, ${alert.lng!.toStringAsFixed(4)}';
      return '$base · $coords';
    }
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = TimeOfDay.fromDateTime(alert.createdAt.toLocal());
    final time = t.format(context);
    return Card(
      color: AulColors.danger,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.warning_amber_rounded, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.sosCenterTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _subtitle(l10n),
                    style: const TextStyle(color: Colors.white),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    time,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: resolving ? null : onResolve,
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              icon: const Icon(Icons.check, size: 18),
              label: Text(l10n.sosCenterResolve),
            ),
          ],
        ),
      ),
    );
  }
}
