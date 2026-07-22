import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../controller.dart';
import '../../theme.dart';
import 'share_controller.dart';
import 'share_session.dart';

/// Opens the live-share sheet.
Future<void> showShareSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => const ShareSheet(),
);

/// Creates a time-boxed link that lets ONE outsider — no account, no app — watch
/// the user's live location, and manages the ones already running.
///
/// The honest bits are not fine print: the link shows a live location to whoever
/// opens it FIRST, and it stops at the deadline or the moment it is revoked.
class ShareSheet extends ConsumerStatefulWidget {
  const ShareSheet({super.key});

  @override
  ConsumerState<ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends ConsumerState<ShareSheet> {
  int _ttl = kShareTtlDefaultSeconds;

  /// The session just created here — the one whose link is worth showing big.
  String? _fresh;
  String? _copied;

  /// Drives the countdowns. Local to the sheet: nothing else needs a 1 Hz
  /// rebuild, and it stops the moment the sheet closes.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    unawaited(ref.read(shareControllerProvider.notifier).refresh());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  String? _linkFor(String id) {
    final key = ref.read(shareControllerProvider).keys[id];
    final origin = ref.read(controllerProvider).serverUrl;
    if (key == null || origin == null) return null;
    return shareLink(origin, id, key);
  }

  Future<void> _create() async {
    final id = await ref.read(shareControllerProvider.notifier).create(_ttl);
    if (!mounted || id == null) return;
    setState(() => _fresh = id);
  }

  Future<void> _copy(String id) async {
    final link = _linkFor(id);
    if (link == null) return;
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted) return;
    setState(() => _copied = id);
    Timer(const Duration(milliseconds: 1500), () {
      if (mounted && _copied == id) setState(() => _copied = null);
    });
  }

  Future<void> _revoke(String id) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        content: Text(l10n.shareRevokeConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AulColors.danger),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(l10n.shareRevoke),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(shareControllerProvider.notifier).revoke(id);
    if (mounted && _fresh == id) setState(() => _fresh = null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = ref.watch(shareControllerProvider);
    final now = DateTime.now();
    final live = s.live(now);
    final freshLink = _fresh == null ? null : _linkFor(_fresh!);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.podcasts_outlined, color: AulColors.primary),
                  const SizedBox(width: 8),
                  Text(
                    l10n.shareTitle,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                l10n.shareIntro,
                style: const TextStyle(
                  color: AulColors.textSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.shareDuration,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final choice in kShareTtlChoicesSeconds)
                    ChoiceChip(
                      label: Text(l10n.shareMinutes(choice ~/ 60)),
                      selected: _ttl == choice,
                      onSelected: s.loading
                          ? null
                          : (_) => setState(() => _ttl = choice),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: s.loading ? null : _create,
                  icon: const Icon(Icons.add_link, size: 18),
                  label: Text(
                    s.loading ? l10n.shareCreating : l10n.shareCreate,
                  ),
                ),
              ),
              if (s.error)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    l10n.shareError,
                    style: const TextStyle(
                      color: AulColors.danger,
                      fontSize: 12,
                    ),
                  ),
                ),
              if (freshLink != null) ...[
                const SizedBox(height: 16),
                _FreshLink(
                  link: freshLink,
                  copied: _copied == _fresh,
                  onCopy: () => _copy(_fresh!),
                ),
              ],
              const SizedBox(height: 20),
              Text(
                l10n.shareActive,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              if (live.isEmpty)
                Text(
                  l10n.shareNone,
                  style: const TextStyle(
                    color: AulColors.textSecondary,
                    fontSize: 13,
                  ),
                )
              else
                for (final session in live)
                  _SessionRow(
                    countdown: formatCountdown(
                      msUntilDeadline(session.expiresAt, now),
                    ),
                    viewerBound: session.viewerBound,
                    hasKey: s.keys.containsKey(session.id),
                    copied: _copied == session.id,
                    onCopy: () => _copy(session.id),
                    onRevoke: () => _revoke(session.id),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The link just created, shown big with a Copy button — plus the plain truth
/// about what the part after `#` is.
class _FreshLink extends StatelessWidget {
  const _FreshLink({
    required this.link,
    required this.copied,
    required this.onCopy,
  });

  final String link;
  final bool copied;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(
          color: AulColors.textSecondary.withValues(alpha: .3),
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.shareLinkTitle,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 8),
          SelectableText(
            link,
            maxLines: 2,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: onCopy,
              icon: Icon(copied ? Icons.check : Icons.copy, size: 16),
              label: Text(copied ? l10n.copied : l10n.copy),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.shareNote,
            style: const TextStyle(
              color: AulColors.textSecondary,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

/// One running session: how long it has left, whether anyone has claimed it,
/// and the two things that can be done about it.
class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.countdown,
    required this.viewerBound,
    required this.hasKey,
    required this.copied,
    required this.onCopy,
    required this.onRevoke,
  });

  final String countdown;
  final bool viewerBound;

  /// False for a session created on another device: its link cannot be shown
  /// here (the key is not on this device), but it can still be revoked.
  final bool hasKey;
  final bool copied;
  final VoidCallback onCopy;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(
            color: AulColors.textSecondary.withValues(alpha: .3),
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(Icons.podcasts, size: 16, color: AulColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.shareEndsIn(countdown),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    viewerBound ? l10n.shareClaimed : l10n.shareUnclaimed,
                    style: const TextStyle(
                      color: AulColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                  if (!hasKey)
                    Text(
                      l10n.shareNoKeyHere,
                      style: const TextStyle(
                        color: AulColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
            if (hasKey)
              IconButton(
                tooltip: copied ? l10n.copied : l10n.copy,
                icon: Icon(copied ? Icons.check : Icons.copy, size: 18),
                onPressed: onCopy,
              ),
            TextButton(
              onPressed: onRevoke,
              style: TextButton.styleFrom(foregroundColor: AulColors.danger),
              child: Text(l10n.shareRevoke),
            ),
          ],
        ),
      ),
    );
  }
}
