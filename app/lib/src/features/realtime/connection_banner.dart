import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../theme.dart';
import '../map/freshness.dart';
import 'realtime_controller.dart';

/// An honest, CLIENT-INFERRED "live updates paused" banner.
///
/// The realtime socket is the only thing that moves a marker the instant it
/// happens; when it is down the app falls back to polling — and, worse, an
/// offline or unreachable server cannot announce that it is gone. So a viewer can
/// sit looking at a last-known dot with a fresh-reading "3 min ago" while nothing
/// has actually arrived for an hour. This banner is the app concluding the
/// connection is down from the one thing it can see for itself: whether ITS OWN
/// socket is connected ([RealtimeSignals.connected]).
///
/// It appears only after [showDelay] of continuous disconnection, so the ordinary
/// second-or-two of a cold-start connect (or a momentary blip) never flashes it,
/// and it disappears the instant the socket is back. The copy is deliberately
/// generic — as true for a self-hosted server that was switched off as for a
/// phone that lost signal — and names neither.
///
/// It carries its own gate only loosely: it is placed where a circle already
/// exists and the user is signed in (Home's has-circle body, the map), so it does
/// not need to re-derive "there is something to be connected to".
class ConnectionBanner extends ConsumerStatefulWidget {
  const ConnectionBanner({
    super.key,
    this.showDelay = const Duration(seconds: 4),
  });

  /// How long the socket must stay down before the banner shows. Long enough that
  /// a normal reconnect stays quiet; short enough that a real outage is owned up
  /// to promptly. Zero in tests.
  final Duration showDelay;

  @override
  ConsumerState<ConnectionBanner> createState() => _ConnectionBannerState();
}

class _ConnectionBannerState extends ConsumerState<ConnectionBanner> {
  bool _visible = false;
  Timer? _timer;

  /// Refreshes the "last connected N ago" age while the banner is up — the socket
  /// is down, so no realtime signal arrives to rebuild it otherwise.
  Timer? _ageTimer;

  @override
  void dispose() {
    _timer?.cancel();
    _ageTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = ref.watch(realtimeProvider.select((r) => r.connected));
    final since = ref.watch(
      realtimeProvider.select((r) => r.disconnectedSince),
    );

    if (connected) {
      // Back on the socket: drop the arming timer, the age refresher, and the
      // banner together. Safe to mutate here — we return nothing, no rebuild owed.
      _timer?.cancel();
      _timer = null;
      _ageTimer?.cancel();
      _ageTimer = null;
      _visible = false;
      return const SizedBox.shrink();
    }

    // Disconnected. Arm the reveal exactly once; a pending timer or an
    // already-shown banner needs no second one.
    if (!_visible && _timer == null) {
      _timer = Timer(widget.showDelay, () {
        _timer = null;
        if (mounted) setState(() => _visible = true);
      });
    }
    if (!_visible) return const SizedBox.shrink();

    // Keep the age ticking while the banner is visible.
    _ageTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });

    final l10n = AppLocalizations.of(context);
    final ago = since == null ? null : formatAgo(l10n, since, DateTime.now());
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: AulColors.amber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(
                  Icons.cloud_off_outlined,
                  size: 18,
                  color: AulColors.amber,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.liveUpdatesPaused,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    // The load-bearing line for a safety app: HOW stale the map may
                    // be. Omitted only before the first successful connect (no age
                    // to show yet).
                    if (ago != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          l10n.connectionStale(ago),
                          style: const TextStyle(
                            fontSize: 12,
                            color: AulColors.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
