import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../controller.dart';
import '../data/db/connection.dart';
import '../theme.dart';

/// Debug / battery-accounting screen (spec §9). Shows the offline-queue depth
/// and reporting config so a tester can watch a typical day and confirm the
/// ≤3 %/day battery target. Full per-day counters live in the service isolate;
/// this reads the shared queue DB.
class DebugScreen extends ConsumerStatefulWidget {
  const DebugScreen({super.key});

  @override
  ConsumerState<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends ConsumerState<DebugScreen> {
  int? _pending;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await openQueueDatabase();
    final count = await db.pendingCount();
    await db.close();
    if (mounted) setState(() => _pending = count);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(controllerProvider);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.debugTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _row(l10n.debugSharing, s.sharing ? l10n.debugOn : l10n.debugOff),
            _row(l10n.debugPrecision, s.precision.wire),
            _row(l10n.debugCircles, '${s.circles.length}'),
            _row(l10n.debugQueuedPings, '${_pending ?? '…'}'),
            _row(l10n.debugServer, s.serverUrl ?? '—'),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  l10n.debugCadenceInfo,
                  style: const TextStyle(
                    color: AulColors.textSecondary,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(k, style: const TextStyle(color: AulColors.textSecondary)),
        Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
  );
}
