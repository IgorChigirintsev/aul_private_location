import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../controller.dart';
import '../domain/location_fix.dart';
import '../theme.dart';
import 'about_screen.dart';
import 'circles/circle_switcher.dart';
import 'circles/members_screen.dart';
import 'circles/precision_control.dart';
import 'circles/profile_editor_screen.dart';
import 'debug_screen.dart';
import 'map/map_screen.dart';
import 'onboarding_fork.dart';
import 'realtime/connection_banner.dart';
import 'realtime/realtime_controller.dart';
import 'share/share_banner.dart';
import 'share/share_sheet.dart';
import 'sos/cross_circle_sos.dart';
import 'sos/sos_center.dart';
import 'sos_button.dart';
import 'update_banner.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(controllerProvider);
    final ctrl = ref.read(controllerProvider.notifier);
    final l10n = AppLocalizations.of(context);

    final selected = s.selectedCircle;

    // Watching this is what OPENS the realtime socket, and holding the watch here
    // is what keeps it open: home is the screen everything else is pushed on top
    // of, so the connection lives for as long as the signed-in app does — the
    // same place the web wires its client (the Dashboard). It follows the
    // selected circle on its own.
    //
    // It is deliberately not surfaced: "connected" is not the user's problem.
    // When the socket is down the app polls, which is what it always did.
    ref.watch(realtimeProvider);

    return Scaffold(
      appBar: AppBar(
        title: const CircleSwitcher(),
        actions: [
          IconButton(
            tooltip: l10n.mapTitle,
            icon: const Icon(Icons.map_outlined),
            onPressed: selected == null
                ? null
                : () => _openMap(context, selected.id),
          ),
          IconButton(
            tooltip: l10n.whoCanSeeMe,
            icon: const Icon(Icons.visibility_outlined),
            onPressed: () => _showWhoSeesMe(context, s.circles.length),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'about') {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const AboutScreen()));
              } else if (v == 'debug') {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const DebugScreen()));
              } else if (v == 'signout') {
                ctrl.signOut();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'about', child: Text(l10n.aboutTitle)),
              PopupMenuItem(value: 'debug', child: Text(l10n.debugTitle)),
              PopupMenuItem(value: 'signout', child: Text(l10n.signOut)),
            ],
          ),
        ],
      ),
      body: ListView(
        // The bottom padding clears the SOS action floating over this list, so
        // the last control is never trapped underneath it.
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 104),
        children: [
          const UpdateBanner(),
          const ShareBanner(),
          // No circle yet: instead of a half-usable Home, show the explicit
          // "how do you want to start?" fork (create / join / self-host).
          if (s.circles.isEmpty) ...[
            const SizedBox(height: 8),
            const OnboardingFork(),
          ] else ...[
            // Honest, client-inferred: when the realtime socket is down the app
            // is on polling alone and an offline server can't say so, so this owns
            // up to it rather than letting a last-known dot read as live. Collapses
            // to nothing the moment the socket is back.
            const ConnectionBanner(),
            SosCenter(circleId: selected?.id),
            const CrossCircleSosBanner(),
            if (s.sosActive) ...[
              _SosActiveBanner(onCancel: ctrl.cancelSos),
              const SizedBox(height: 16),
            ],
            _SharingCard(
              sharing: s.sharing,
              // The precision control acts on the SELECTED circle — precision is
              // per-circle, so there is no one mode to show when there is no
              // circle selected to have one.
              circleId: selected?.id,
              circleName: selected == null
                  ? null
                  : (ref.watch(circleNamesProvider).value?[selected.id] ??
                        l10n.circleFallback),
              precision: s.precision,
              canShare: s.circles.isNotEmpty,
              multiCircle: s.circles.length > 1,
              onToggle: () =>
                  s.sharing ? ctrl.stopSharing() : ctrl.startSharing(),
              onShareLink: () => showShareSheet(context),
            ),
            const SizedBox(height: 16),
            _CirclesCard(
              count: s.circles.length,
              circleName: selected == null
                  ? null
                  : (ref.watch(circleNamesProvider).value?[selected.id] ??
                        l10n.circleFallback),
              onMap: selected == null
                  ? null
                  : () => _openMap(context, selected.id),
              onMembers: selected == null
                  ? null
                  : () => _openMembers(context, selected.id),
              onProfile: selected == null
                  ? null
                  : () => _openProfile(context, selected.id),
              onJoin: () => showJoinCircleDialog(context, ref),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                l10n.homeSharingFooter,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AulColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ],
      ),
      // Bottom-right, floating over the content and clear of everything else on
      // this screen: an emergency control that has to be found is not one.
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: SosButton(
        enabled: ref.watch(hasCircleKeyProvider).value ?? false,
        onConfirmed: () => _raiseSos(context, ref),
      ),
    );
  }

  Future<void> _raiseSos(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final ok = await ref.read(controllerProvider.notifier).raiseSos();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? l10n.sosSentSuccess : l10n.sosSentFailure)),
    );
  }

  void _openMembers(BuildContext context, String circleId) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => MembersScreen(circleId: circleId)),
    );
  }

  void _openMap(BuildContext context, String circleId) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => MapScreen(circleId: circleId)));
  }

  void _openProfile(BuildContext context, String circleId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProfileEditorScreen(circleId: circleId),
      ),
    );
  }

  void _showWhoSeesMe(BuildContext context, int circles) {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.whoCanSeeMe,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              circles == 0
                  ? l10n.whoCanSeeMeNobody
                  : l10n.whoCanSeeMeCircles(circles),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _SharingCard extends ConsumerStatefulWidget {
  const _SharingCard({
    required this.sharing,
    required this.circleId,
    required this.circleName,
    required this.precision,
    required this.canShare,
    required this.multiCircle,
    required this.onToggle,
    required this.onShareLink,
  });

  final bool sharing;

  /// The selected circle — the one the precision control writes. Null when the
  /// user is in no circle, and then there is no mode to set.
  final String? circleId;

  /// The selected circle's decrypted name, for saying WHOSE view is being set.
  final String? circleName;

  final PrecisionMode precision;
  final bool canShare;

  /// Whether there is more than one circle — i.e. whether "this only changes THIS
  /// circle" is a distinction worth drawing for this user.
  final bool multiCircle;

  final VoidCallback onToggle;

  /// Opens the live-share sheet. Deliberately NOT gated on [canShare]: a share
  /// link is its own opt-in with its own key and needs no circle at all.
  final VoidCallback onShareLink;

  @override
  ConsumerState<_SharingCard> createState() => _SharingCardState();
}

class _SharingCardState extends ConsumerState<_SharingCard> {
  bool _busy = false;

  /// Optimistic override so the segment moves under the thumb, then settles on
  /// the server's value (or springs back on failure).
  PrecisionMode? _override;

  PrecisionMode get _precision => _override ?? widget.precision;

  /// Sets the SELECTED circle's precision — that circle's and no other's. The
  /// old control wrote this one choice to every circle at once, which is what
  /// made "City for work, Precise for family" impossible to express.
  Future<void> _setPrecision(PrecisionMode next) async {
    if (_busy || next == _precision) return;
    setState(() {
      _busy = true;
      _override = next;
    });
    final ok = await ref.read(controllerProvider.notifier).setPrecision(next);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _override = null; // settle on the refreshed circle list, or spring back
    });
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).precisionChangeFailed),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final l10n = AppLocalizations.of(context);
    final sharing = widget.sharing;
    final canShare = widget.canShare;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  sharing ? Icons.share_location : Icons.location_off,
                  color: sharing ? primary : AulColors.textSecondary,
                ),
                const SizedBox(width: 8),
                Text(
                  sharing ? l10n.sharingOn : l10n.sharingOff,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Names the circle this control speaks for. Without that, a per-circle
            // setting rendered as a bare row of buttons reads exactly like the
            // global one it replaced — and the user would have no way to tell that
            // their other circles are on something else.
            if (widget.circleName != null) ...[
              Text(
                l10n.homePrecisionFor(widget.circleName!),
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: PrecisionSegmented(
                value: _precision,
                // No circle ⇒ no per-circle mode to write.
                onChanged: _busy || widget.circleId == null
                    ? null
                    : _setPrecision,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              precisionDescription(l10n, _precision),
              style: const TextStyle(
                color: AulColors.textSecondary,
                fontSize: 12,
              ),
            ),
            if (widget.multiCircle)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l10n.homePrecisionPerCircleHint,
                  style: const TextStyle(
                    color: AulColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: canShare ? widget.onToggle : null,
              style: sharing
                  ? FilledButton.styleFrom(
                      backgroundColor: AulColors.textSecondary,
                    )
                  : null,
              child: Text(sharing ? l10n.stopSharing : l10n.startSharing),
            ),
            if (!canShare)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.joinCircleFirst,
                  style: const TextStyle(
                    color: AulColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
            const Divider(height: 24),
            OutlinedButton.icon(
              onPressed: widget.onShareLink,
              icon: const Icon(Icons.podcasts_outlined, size: 18),
              label: Text(l10n.shareTitle),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                l10n.shareHomeHint,
                style: const TextStyle(
                  color: AulColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SosActiveBanner extends StatelessWidget {
  const _SosActiveBanner({required this.onCancel});
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Card(
      color: AulColors.danger,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.sosActiveBanner,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            TextButton(
              onPressed: onCancel,
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: Text(l10n.cancel),
            ),
          ],
        ),
      ),
    );
  }
}

class _CirclesCard extends StatelessWidget {
  const _CirclesCard({
    required this.count,
    required this.circleName,
    required this.onMap,
    required this.onMembers,
    required this.onProfile,
    required this.onJoin,
  });

  final int count;

  /// Decrypted name of the selected circle, or null when the user has no circle.
  final String? circleName;
  final VoidCallback? onMap;
  final VoidCallback? onMembers;
  final VoidCallback? onProfile;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.groups_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        count == 0
                            ? l10n.noCirclesYet
                            : (circleName ?? l10n.circleFallback),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (count > 0)
                        Text(
                          l10n.circlesCount(count),
                          style: const TextStyle(
                            color: AulColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (onMap != null)
                  OutlinedButton.icon(
                    onPressed: onMap,
                    icon: const Icon(Icons.map_outlined, size: 18),
                    label: Text(l10n.mapTitle),
                  ),
                if (onMembers != null)
                  OutlinedButton.icon(
                    onPressed: onMembers,
                    icon: const Icon(Icons.people_alt_outlined, size: 18),
                    label: Text(l10n.membersTitle),
                  ),
                if (onProfile != null)
                  OutlinedButton.icon(
                    onPressed: onProfile,
                    icon: const Icon(Icons.badge_outlined, size: 18),
                    label: Text(l10n.editProfile),
                  ),
                OutlinedButton.icon(
                  onPressed: onJoin,
                  icon: const Icon(Icons.link, size: 18),
                  label: Text(l10n.joinByLink),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
