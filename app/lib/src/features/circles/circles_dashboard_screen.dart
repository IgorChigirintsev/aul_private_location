import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../controller.dart';
import '../../data/api/models.dart';
import '../../domain/location_fix.dart';
import '../../theme.dart';
import 'members_screen.dart' show decodeAvatarDataUrl;
import 'precision_control.dart';

/// One row of the circles dashboard: everything about ONE circle, resolved with
/// THAT circle's own key and its own server state.
///
/// K_c is per-circle, so the nickname and avatar here are the ones the user chose
/// in this circle — never the selected circle's. Likewise [visible] and
/// [circleMuted] are read per circle, so a row always describes itself.
class CircleDashboardRow {
  const CircleDashboardRow({
    required this.circle,
    required this.name,
    required this.nick,
    required this.avatarBytes,
    required this.mutes,
  });

  final CircleSummary circle;

  /// The circle's decrypted name, or null when it has none / can't be opened
  /// (no local key) — the UI then shows a generic fallback.
  final String? name;

  /// The user's nickname in THIS circle, or null when they set none here.
  final String? nick;

  /// The user's avatar in THIS circle, decoded from the sealed profile's data
  /// URL; null for the coloured-initial fallback.
  final Uint8List? avatarBytes;

  /// The caller's own mute set for this circle.
  final Mutes mutes;

  String get id => circle.id;
  bool get isOwner => circle.role == 'owner';

  /// What THIS circle sees: its own precision_mode. Per-circle state on the
  /// server (`circle_members.precision_mode`), so City here while another circle
  /// stays Precise is a normal, reachable arrangement — not a conflict.
  ///
  /// This control and the home screen's are two views of ONE server value: the
  /// home screen edits the SELECTED circle's, this row edits its own.
  PrecisionMode get precision => PrecisionMode.fromWire(circle.precisionMode);

  /// Whether this circle sees the user's location at all: precision_mode ≠
  /// paused. Paused is exactly what the old off state meant, so the row keeps
  /// saying the same thing about the same value — it can now also say "City".
  bool get visible => precision != PrecisionMode.paused;

  /// Whether the whole circle is muted (its members' notifications are stopped
  /// server-side before they reach this account).
  bool get circleMuted => mutes.circleMuted;
}

/// Builds a dashboard row per circle, resolving each one against ITS OWN key and
/// mute set. Pure orchestration over injected lookups, so it can be exercised
/// without Riverpod, crypto, or a network — and so the "per circle, not from the
/// selected one" rule is testable.
///
/// [myUserId] picks the caller's own member row out of each circle; when it is
/// null (or absent from a circle), the row falls back to no nickname/avatar
/// rather than borrowing another member's.
Future<List<CircleDashboardRow>> buildCircleDashboardRows({
  required List<CircleSummary> circles,
  required String? myUserId,
  required Future<String?> Function(CircleSummary circle) decodeName,
  required Future<List<Member>> Function(String circleId) membersOf,
  required Future<({String nick, String? avatar})?> Function(
    String circleId,
    String? profileEnc,
  )
  openProfile,
  required Future<Mutes> Function(String circleId) mutesOf,
}) async {
  final rows = <CircleDashboardRow>[];
  for (final c in circles) {
    final name = await decodeName(c);

    Member? mine;
    if (myUserId != null) {
      for (final m in await membersOf(c.id)) {
        if (m.userId == myUserId) {
          mine = m;
          break;
        }
      }
    }
    // Opened with c.id's keyring — this circle's profile, not the selected
    // circle's.
    final profile = mine == null
        ? null
        : await openProfile(c.id, mine.profileEnc);
    final nick = profile?.nick.trim() ?? '';

    rows.add(
      CircleDashboardRow(
        circle: c,
        name: (name != null && name.trim().isNotEmpty) ? name.trim() : null,
        nick: nick.isNotEmpty ? nick : null,
        avatarBytes: decodeAvatarDataUrl(profile?.avatar),
        mutes: await mutesOf(c.id),
      ),
    );
  }
  return rows;
}

/// The dashboard rows for the current circle list, wired to the controller.
/// Rebuilds whenever the circles change (a join/leave, or a precision write that
/// refreshes the list).
final circleDashboardRowsProvider = FutureProvider<List<CircleDashboardRow>>((
  ref,
) async {
  final circles = ref.watch(controllerProvider.select((s) => s.circles));
  final myUserId = ref.watch(controllerProvider.select((s) => s.userId));
  final ctrl = ref.read(controllerProvider.notifier);
  return buildCircleDashboardRows(
    circles: circles,
    myUserId: myUserId,
    decodeName: ctrl.decodeCircleName,
    membersOf: ctrl.membersOf,
    openProfile: ctrl.openMemberProfile,
    mutesOf: ctrl.mutesOf,
  );
});

/// "My circles": every circle the user is in, and what each one costs them —
/// whether it sees their location, and whether its members can reach them with
/// notifications. Reached from the circle switcher sheet.
///
/// Each row shows the circle's decrypted name plus the user's OWN nickname and
/// avatar in that circle, decrypted with that circle's own key.
class CirclesDashboardScreen extends ConsumerWidget {
  const CirclesDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final rows = ref.watch(circleDashboardRowsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.circlesDashTitle)),
      body: rows.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => _centered(l10n.circlesDashEmpty),
        data: (list) {
          if (list.isEmpty) return _centered(l10n.circlesDashEmpty);
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(circleDashboardRowsProvider);
              await ref.read(circleDashboardRowsProvider.future);
            },
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: list.length + 1,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (_, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      l10n.circlesDashSubtitle,
                      style: const TextStyle(
                        color: AulColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  );
                }
                return _CircleRow(row: list[i - 1]);
              },
            ),
          );
        },
      ),
    );
  }

  Widget _centered(String text) => ListView(
    padding: const EdgeInsets.all(32),
    children: [
      const SizedBox(height: 80),
      Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: AulColors.textSecondary),
      ),
    ],
  );
}

/// One circle: identity in that circle, then the two switches that decide what it
/// costs. Each switch owns its own in-flight flag so a slow write on one circle
/// never blocks the others.
class _CircleRow extends ConsumerStatefulWidget {
  const _CircleRow({required this.row});
  final CircleDashboardRow row;

  @override
  ConsumerState<_CircleRow> createState() => _CircleRowState();
}

class _CircleRowState extends ConsumerState<_CircleRow> {
  bool _precisionBusy = false;
  bool _muteBusy = false;

  /// Optimistic overrides so the control moves under the thumb, then settles on
  /// what the server actually stored (or springs back on failure).
  PrecisionMode? _precisionOverride;
  Mutes? _mutesOverride;

  CircleDashboardRow get row => widget.row;
  PrecisionMode get _precision => _precisionOverride ?? row.precision;
  Mutes get _mutes => _mutesOverride ?? row.mutes;

  /// Writes THIS circle's precision_mode — Precise, City, or Paused — and only
  /// this one. Every other circle keeps whatever it was on, which is the point:
  /// the work circle can sit on City while family stays Precise.
  ///
  /// The same server value the home screen's control writes for the selected
  /// circle, and the one that greys out a paused member's marker for everyone
  /// else.
  Future<void> _setPrecision(PrecisionMode next) async {
    if (_precisionBusy || next == _precision) return;
    setState(() {
      _precisionBusy = true;
      _precisionOverride = next;
    });
    final ok = await ref
        .read(controllerProvider.notifier)
        .setCirclePrecision(row.id, next);
    if (!mounted) return;
    setState(() {
      _precisionBusy = false;
      // On success the refreshed circle list carries the truth; drop the
      // override so the row shows it. On failure spring back.
      _precisionOverride = null;
    });
    if (!ok) _toast(AppLocalizations.of(context).circlesDashActionFailed);
  }

  /// "Notifications" ⇒ circle_muted. Muting is server-side: the fan-out skips
  /// muted recipients, so this stops other members' notifications reaching the
  /// user rather than hiding them here.
  Future<void> _toggleNotifications(bool on) async {
    if (_muteBusy) return;
    final next = _mutes.withCircleMuted(!on);
    setState(() {
      _muteBusy = true;
      _mutesOverride = next;
    });
    final stored = await ref
        .read(controllerProvider.notifier)
        .setMutes(row.id, next);
    if (!mounted) return;
    setState(() {
      _muteBusy = false;
      // Settle on the server's echo, not on what we hoped it stored.
      _mutesOverride = stored ?? row.mutes;
    });
    if (stored == null) {
      _toast(AppLocalizations.of(context).circlesDashActionFailed);
    }
  }

  void _toast(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final primary = Theme.of(context).colorScheme.primary;
    final name = row.name ?? l10n.circleFallback;
    final muted = _mutes.circleMuted;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Avatar(
                  // The initial falls back to the circle's name when the user set
                  // no nickname here, so the row is never a blank disc.
                  seed: row.nick ?? name,
                  bytes: row.avatarBytes,
                  primary: primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        row.nick != null
                            ? l10n.circlesDashYouAs(row.nick!)
                            : l10n.circlesDashYouNoNick,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AulColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                if (row.isOwner)
                  Text(
                    l10n.circleOwnerBadge,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AulColors.textSecondary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            _PrecisionTile(
              title: l10n.circlesDashPrecisionTitle,
              description: precisionDescription(l10n, _precision),
              value: _precision,
              onChanged: _precisionBusy ? null : _setPrecision,
            ),
            const SizedBox(height: 8),
            _SwitchTile(
              title: l10n.circlesDashNotificationsTitle,
              description: muted
                  ? l10n.circlesDashNotificationsOff
                  : l10n.circlesDashNotificationsOn,
              value: !muted,
              onChanged: _muteBusy ? null : _toggleNotifications,
            ),
          ],
        ),
      ),
    );
  }
}

/// The per-circle Precise/City/Paused control, in the same tile shell as the
/// notifications switch beside it: title, the plain-words consequence, then the
/// control. Full width on its own row — three labels don't fit next to a title.
class _PrecisionTile extends StatelessWidget {
  const _PrecisionTile({
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String description;
  final PrecisionMode value;
  final ValueChanged<PrecisionMode>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(height: 2),
          Text(
            description,
            style: const TextStyle(
              color: AulColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          // The segments announce their own selected state; the label names WHICH
          // setting this is, so it isn't read out as three bare buttons.
          Semantics(
            label: title,
            child: SizedBox(
              width: double.infinity,
              child: PrecisionSegmented(value: value, onChanged: onChanged),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: const TextStyle(
                    color: AulColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // The Switch announces its own on/off state; the label names WHICH
          // setting it is, so it isn't read out as a bare "switch".
          Semantics(
            label: title,
            child: Switch(value: value, onChanged: onChanged),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.seed,
    required this.bytes,
    required this.primary,
  });

  final String seed;
  final Uint8List? bytes;
  final Color primary;

  @override
  Widget build(BuildContext context) {
    final b = bytes;
    if (b != null) {
      return CircleAvatar(radius: 22, backgroundImage: MemoryImage(b));
    }
    final initial = seed.trim().isEmpty ? '?' : seed.trim()[0].toUpperCase();
    return CircleAvatar(
      radius: 22,
      backgroundColor: primary.withValues(alpha: 0.12),
      child: Text(
        initial,
        style: TextStyle(color: primary, fontWeight: FontWeight.w700),
      ),
    );
  }
}
