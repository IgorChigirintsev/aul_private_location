import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../theme.dart';
import 'share_controller.dart';
import 'share_session.dart';
import 'share_sheet.dart';

/// The home screen's standing admission that a live share is running.
///
/// A share is the one thing here that shows a NON-member where the user is, so
/// it does not get to be invisible just because the sheet is closed: while any
/// session is live this sits at the top of the screen, counting down, and taps
/// straight through to the revoke button.
class ShareBanner extends ConsumerStatefulWidget {
  const ShareBanner({super.key});

  @override
  ConsumerState<ShareBanner> createState() => _ShareBannerState();
}

class _ShareBannerState extends ConsumerState<ShareBanner> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Only to move the countdown; it costs nothing while nothing is live.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = ref.watch(shareControllerProvider);
    final now = DateTime.now();
    final live = s.live(now);
    final next = s.nextDeadline; // soonest deadline — the one to count down
    if (live.isEmpty || next == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: AulColors.amber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => showShareSheet(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.podcasts, size: 18, color: AulColors.amber),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    live.length == 1
                        ? l10n.shareBannerSharing
                        : l10n.shareBannerSharingMany(live.length),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  formatCountdown(msUntilDeadline(next, now)),
                  style: const TextStyle(
                    color: AulColors.textSecondary,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: AulColors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
