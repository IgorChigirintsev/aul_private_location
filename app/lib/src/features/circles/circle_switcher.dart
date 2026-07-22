import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../l10n/app_localizations.dart';
import '../../controller.dart';
import '../../data/api/models.dart';
import '../../theme.dart';
import 'circles_dashboard_screen.dart';
import 'members_screen.dart';
import 'profile_editor_screen.dart';
import 'verify_devices_screen.dart';

/// Decrypted circle names (id → name) for the current circle list. Rebuilds when
/// the controller's circles change. Names that can't be decoded (no local key,
/// wrong key, or unset) are omitted so the UI shows a generic fallback. This is
/// invalidated by the switcher after rename/create/leave/delete.
final circleNamesProvider = FutureProvider<Map<String, String>>((ref) async {
  final circles = ref.watch(controllerProvider.select((s) => s.circles));
  final ctrl = ref.read(controllerProvider.notifier);
  final out = <String, String>{};
  for (final c in circles) {
    final name = await ctrl.decodeCircleName(c);
    if (name != null && name.trim().isNotEmpty) out[c.id] = name.trim();
  }
  return out;
});

/// App-bar control showing "Aul · [current circle]" that opens the circle
/// management sheet: switch between circles (decrypted names, an owner badge, a
/// check on the current one), open the members list / profile editor, and —
/// mirroring the web CircleSwitcher — rename (owner), leave, delete (owner),
/// create a new circle, or join by link. A sole owner who tries to leave is
/// offered a delete-instead confirm (the server refuses their leave).
class CircleSwitcher extends ConsumerWidget {
  const CircleSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final selected = ref.watch(
      controllerProvider.select((s) => s.selectedCircle),
    );
    final names = ref.watch(circleNamesProvider).value ?? const {};
    final label = selected == null
        ? null
        : (names[selected.id] ?? l10n.circleFallback);

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => _openSheet(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Aul', style: TextStyle(fontWeight: FontWeight.w800)),
            if (label != null) ...[
              const SizedBox(width: 6),
              const Text('·', style: TextStyle(color: AulColors.textSecondary)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
            const Icon(Icons.arrow_drop_down, size: 22),
          ],
        ),
      ),
    );
  }

  // --- the management bottom sheet ---

  Future<void> _openSheet(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) {
        final s = ref.read(controllerProvider);
        final names = ref.read(circleNamesProvider).value ?? const {};
        final selected = s.selectedCircle;
        final isOwner = selected?.role == 'owner';
        String nameOf(CircleSummary c) => names[c.id] ?? l10n.circleFallback;
        void close() => Navigator.of(sheetCtx).pop();

        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: Text(
                    l10n.circlesYours,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                      color: AulColors.textSecondary,
                    ),
                  ),
                ),
                for (final c in s.circles)
                  ListTile(
                    leading: const Icon(Icons.groups_outlined),
                    title: Text(nameOf(c)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (c.role == 'owner')
                          Text(
                            l10n.circleOwnerBadge,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AulColors.textSecondary,
                            ),
                          ),
                        if (c.id == selected?.id)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Icon(
                              Icons.check,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                      ],
                    ),
                    onTap: () {
                      close();
                      ref.read(controllerProvider.notifier).selectCircle(c.id);
                    },
                  ),
                if (s.circles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: Text(
                      l10n.noCirclesYet,
                      style: const TextStyle(color: AulColors.textSecondary),
                    ),
                  ),
                const Divider(height: 1),
                // "My circles" is about EVERY circle, not the selected one, so it
                // sits outside the selected-circle block.
                if (s.circles.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.tune),
                    title: Text(l10n.circlesDashTitle),
                    subtitle: Text(
                      l10n.circlesDashSubtitle,
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () {
                      close();
                      _openDashboard(context);
                    },
                  ),
                if (selected != null) ...[
                  ListTile(
                    leading: const Icon(Icons.person_add_alt),
                    title: Text(l10n.inviteTitle),
                    subtitle: Text(
                      l10n.inviteSubtitle,
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () {
                      close();
                      _invite(context, selected.id);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.people_alt_outlined),
                    title: Text(l10n.membersTitle),
                    onTap: () {
                      close();
                      _openMembers(context, ref, selected.id);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.badge_outlined),
                    title: Text(l10n.editProfile),
                    onTap: () {
                      close();
                      _openProfile(context, ref, selected.id);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.verified_user_outlined),
                    title: Text(l10n.verifyDevicesTitle),
                    onTap: () {
                      close();
                      _openVerify(context, ref, selected.id);
                    },
                  ),
                  if (isOwner)
                    ListTile(
                      leading: const Icon(Icons.edit_outlined),
                      title: Text(l10n.renameCircle),
                      onTap: () {
                        close();
                        _rename(context, ref);
                      },
                    ),
                  if (isOwner)
                    ListTile(
                      leading: const Icon(Icons.key_outlined),
                      title: Text(l10n.rotateKey),
                      onTap: () {
                        close();
                        _rotate(context, ref);
                      },
                    ),
                  ListTile(
                    leading: const Icon(Icons.logout, color: AulColors.danger),
                    title: Text(
                      l10n.leaveCircle,
                      style: const TextStyle(color: AulColors.danger),
                    ),
                    onTap: () {
                      close();
                      _leave(context, ref);
                    },
                  ),
                  if (isOwner)
                    ListTile(
                      leading: const Icon(
                        Icons.delete_outline,
                        color: AulColors.danger,
                      ),
                      title: Text(
                        l10n.deleteCircle,
                        style: const TextStyle(color: AulColors.danger),
                      ),
                      onTap: () {
                        close();
                        _delete(context, ref);
                      },
                    ),
                  const Divider(height: 1),
                ],
                ListTile(
                  leading: const Icon(Icons.add),
                  title: Text(l10n.createCircle),
                  onTap: () {
                    close();
                    _create(context, ref);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.link),
                  title: Text(l10n.joinByLink),
                  onTap: () {
                    close();
                    _join(context, ref);
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  // --- navigation ---

  void _openDashboard(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const CirclesDashboardScreen()));
  }

  void _openMembers(BuildContext context, WidgetRef ref, String circleId) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => MembersScreen(circleId: circleId)),
    );
  }

  void _openProfile(BuildContext context, WidgetRef ref, String circleId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProfileEditorScreen(circleId: circleId),
      ),
    );
  }

  void _openVerify(BuildContext context, WidgetRef ref, String circleId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VerifyDevicesScreen(circleId: circleId),
      ),
    );
  }

  /// Creates an invite and shows the link to share. Its own dialog because the
  /// link cannot exist before the round-trip that mints it.
  void _invite(BuildContext context, String circleId) {
    showDialog<void>(
      context: context,
      builder: (_) => _InviteDialog(circleId: circleId),
    );
  }

  // --- actions ---

  /// Owner-only: re-keys the circle (new K_c distributed to every member device;
  /// pre-rotation data stays readable). Confirms first, then reports success or
  /// failure — failure includes the no-key-on-this-device case (rotate returns
  /// false without touching anything).
  Future<void> _rotate(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final ok = await _confirm(
      context,
      title: l10n.rotateKeyTitle,
      body: l10n.rotateKeyBody,
      confirm: l10n.rotateKeyConfirm,
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final done = await ref
        .read(controllerProvider.notifier)
        .rotateSelectedCircleKey();
    messenger.showSnackBar(
      SnackBar(
        content: Text(done ? l10n.rotateKeySuccess : l10n.rotateKeyFailure),
      ),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final selected = ref.read(controllerProvider).selectedCircle;
    if (selected == null) return;
    final current = ref.read(circleNamesProvider).value?[selected.id];
    final name = await _promptName(
      context,
      title: l10n.renameCircle,
      hint: l10n.renameCircleHint,
      confirm: l10n.rename,
      initial: current ?? '',
    );
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(controllerProvider.notifier)
          .renameSelectedCircle(name.trim());
      ref.invalidate(circleNamesProvider);
      messenger.showSnackBar(SnackBar(content: Text(l10n.circleRenamed)));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.circleActionFailed)));
    }
  }

  Future<void> _leave(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final ok = await _confirm(
      context,
      title: l10n.leaveCircleTitle,
      body: l10n.leaveCircleBody,
      confirm: l10n.leave,
      danger: true,
    );
    if (ok != true || !context.mounted) return;
    final res = await ref
        .read(controllerProvider.notifier)
        .leaveSelectedCircle();
    if (!context.mounted) return;
    switch (res) {
      case LeaveResult.left:
        ref.invalidate(circleNamesProvider);
        _toast(context, l10n.circleLeft);
      case LeaveResult.soleOwner:
        final del = await _confirm(
          context,
          title: l10n.soleOwnerTitle,
          body: l10n.soleOwnerBody,
          confirm: l10n.delete,
          danger: true,
        );
        if (del == true && context.mounted) await _doDelete(context, ref);
      case LeaveResult.error:
        _toast(context, l10n.circleActionFailed);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final selected = ref.read(controllerProvider).selectedCircle;
    if (selected == null) return;
    final name =
        ref.read(circleNamesProvider).value?[selected.id] ??
        l10n.circleFallback;
    final ok = await _confirm(
      context,
      title: l10n.deleteCircleTitle,
      body: l10n.deleteCircleBody(name),
      confirm: l10n.delete,
      danger: true,
    );
    if (ok == true && context.mounted) await _doDelete(context, ref);
  }

  Future<void> _doDelete(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    try {
      await ref.read(controllerProvider.notifier).deleteSelectedCircle();
      if (!context.mounted) return;
      ref.invalidate(circleNamesProvider);
      _toast(context, l10n.circleDeleted);
    } catch (_) {
      if (context.mounted) _toast(context, l10n.circleActionFailed);
    }
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final name = await _promptName(
      context,
      title: l10n.createCircle,
      hint: l10n.createCircleHint,
      confirm: l10n.create,
      initial: '',
    );
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    final ok = await ref
        .read(controllerProvider.notifier)
        .createCircle(name.trim());
    if (!context.mounted) return;
    ref.invalidate(circleNamesProvider);
    _toast(context, ok ? l10n.circleCreated : l10n.circleActionFailed);
  }

  Future<void> _join(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final link = await _promptName(
      context,
      title: l10n.joinCircleTitle,
      hint: l10n.joinCircleHint,
      confirm: l10n.join,
      initial: '',
    );
    if (link == null || link.trim().isEmpty || !context.mounted) return;
    final ok = await ref
        .read(controllerProvider.notifier)
        .joinByLink(link.trim());
    if (!context.mounted) return;
    ref.invalidate(circleNamesProvider);
    _toast(context, ok ? l10n.joinedCircle : l10n.couldNotJoin);
  }
}

/// Creates an invite and shows the shareable link, mirroring the web
/// `InviteDialog`. The link is minted on open (a `POST` to the server) and the
/// circle key K_c is appended as the URL fragment — it never touches the server.
///
/// The note under the link is not fine print: whoever holds the WHOLE link can
/// join this circle and decrypt what it shares. That is the honest description
/// of what the user is about to paste into a messenger.
class _InviteDialog extends ConsumerStatefulWidget {
  const _InviteDialog({required this.circleId});

  final String circleId;

  @override
  ConsumerState<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends ConsumerState<_InviteDialog> {
  String? _link;
  bool _failed = false;
  bool _copied = false;
  Timer? _copyReset;

  @override
  void initState() {
    super.initState();
    unawaited(_create());
  }

  @override
  void dispose() {
    _copyReset?.cancel();
    super.dispose();
  }

  Future<void> _create() async {
    final link = await ref
        .read(controllerProvider.notifier)
        .createInviteLink(widget.circleId);
    if (!mounted) return;
    setState(() {
      _link = link;
      _failed = link == null;
    });
  }

  Future<void> _copy() async {
    final link = _link;
    if (link == null) return;
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted) return;
    setState(() => _copied = true);
    _copyReset?.cancel();
    _copyReset = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final link = _link;
    return AlertDialog(
      title: Text(l10n.inviteTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_failed)
            Text(
              l10n.inviteError,
              style: const TextStyle(color: AulColors.danger),
            )
          else if (link == null)
            Text(
              l10n.inviteCreating,
              style: const TextStyle(color: AulColors.textSecondary),
            )
          else ...[
            // A scannable QR of the SAME invite link, mirroring the web
            // InviteDialog. It encodes exactly the copyable string below — K_c
            // rides in the URL fragment either way, so the QR exposes nothing
            // the link didn't. Never logged (E2EE: the payload carries the key).
            Center(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                // Tightly sized so the AlertDialog's intrinsic-height pass stops
                // here instead of descending into QrImageView's internal
                // LayoutBuilder (which cannot answer intrinsic queries).
                child: SizedBox(
                  width: 200,
                  height: 200,
                  child: QrImageView(
                    data: link,
                    version: QrVersions.auto,
                    size: 200,
                    backgroundColor: Colors.white,
                    // Fail loudly in a widget rather than throwing during paint
                    // if the link were ever too long to encode.
                    errorStateBuilder: (context, _) => Center(
                      child: Text(
                        l10n.inviteError,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AulColors.danger),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              link,
              maxLines: 3,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.inviteNote,
              style: const TextStyle(
                fontSize: 12,
                color: AulColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.close),
        ),
        if (link != null)
          FilledButton.icon(
            onPressed: _copy,
            icon: Icon(_copied ? Icons.check : Icons.copy, size: 16),
            label: Text(_copied ? l10n.copied : l10n.copy),
          ),
      ],
    );
  }
}

/// Small text-entry dialog used for rename / create / join. Returns the entered
/// text, or null if cancelled.
Future<String?> _promptName(
  BuildContext context, {
  required String title,
  required String hint,
  required String confirm,
  required String initial,
}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context).cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, ctl.text),
          child: Text(confirm),
        ),
      ],
    ),
  );
}

/// A yes/no confirmation dialog. Returns true when confirmed. [danger] tints the
/// confirm button with the danger colour (leave / delete).
Future<bool?> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String confirm,
  bool danger = false,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(AppLocalizations.of(context).cancel),
        ),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: AulColors.danger)
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
