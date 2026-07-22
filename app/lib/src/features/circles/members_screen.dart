import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../controller.dart';
import '../../data/api/models.dart';
import '../../domain/location_fix.dart';
import '../../theme.dart';
import '../map/accuracy.dart';
import '../map/freshness.dart';
import '../map/map_screen.dart';
import '../map/member_positions.dart';
import '../realtime/realtime_controller.dart';
import 'verify_devices_screen.dart';

/// A member row ready to render: the raw [member], the display [name] (nickname
/// if set, else the email), the decoded [avatarBytes] (from the per-circle
/// profile's data-URL avatar, or null for the coloured-initial fallback), and
/// their latest decrypted [position] — the source of the battery and "updated N
/// ago" line.
class MemberRow {
  const MemberRow(this.member, this.name, this.avatarBytes, {this.position});
  final Member member;
  final String name;
  final Uint8List? avatarBytes;

  /// This member's freshest position, or null when none of their devices has a
  /// ping this device can open. Everything shown from it — coordinates, battery,
  /// capture time — came out of a payload sealed under K_c; the server relayed it
  /// without being able to read any of it.
  final MemberPosition? position;
}

/// Decodes a `data:image/...;base64,` avatar data URL into raw bytes for a
/// [MemoryImage]. Returns null when the input is null/malformed.
Uint8List? decodeAvatarDataUrl(String? dataUrl) {
  if (dataUrl == null) return null;
  final comma = dataUrl.indexOf(',');
  if (comma < 0) return null;
  try {
    return base64.decode(dataUrl.substring(comma + 1));
  } catch (_) {
    return null;
  }
}

/// The selected circle's members: avatar (decoded from the sealed per-circle
/// profile) or a coloured initial, nickname (falling back to the email), a role
/// badge, and a "(you)" marker on the current user. Everything is decrypted on
/// device with the circle key — the server only relays ciphertext.
class MembersScreen extends ConsumerStatefulWidget {
  const MembersScreen({super.key, required this.circleId});

  final String circleId;

  @override
  ConsumerState<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends ConsumerState<MembersScreen> {
  late Future<List<MemberRow>> _future;

  /// The caller's own mute set for this circle. Loaded alongside the members and
  /// kept here so a toggle re-renders only this screen. [Mutes.none] until it
  /// loads: an unread mute set must never render as "muted".
  Mutes _mutes = Mutes.none;

  /// User ids with a mute write in flight, so a row's bell disables itself
  /// without freezing the rest of the list.
  final Set<String> _muting = {};

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<MemberRow>> _load() async {
    final ctrl = ref.read(controllerProvider.notifier);
    final members = await ctrl.membersOf(widget.circleId);
    final mutes = await ctrl.mutesOf(widget.circleId);
    // Positions arrive keyed by DEVICE; this screen lists PEOPLE. A member with a
    // phone and a laptop has two — the freshest one is the answer to "where are
    // they, and what's their battery".
    final positions = positionsByUser(await _positions());
    final rows = <MemberRow>[];
    for (final m in members) {
      final profile = await ctrl.openMemberProfile(
        widget.circleId,
        m.profileEnc,
      );
      final nick = profile?.nick.trim() ?? '';
      rows.add(
        MemberRow(
          m,
          nick.isNotEmpty ? nick : m.email,
          decodeAvatarDataUrl(profile?.avatar),
          position: positions[m.userId],
        ),
      );
    }
    if (mounted) setState(() => _mutes = mutes);
    return rows;
  }

  /// The circle's positions: whatever the realtime socket has already delivered
  /// into the shared store, else a fresh fetch.
  ///
  /// The store is normally warm — the socket runs while the app is open — so
  /// opening this screen usually costs no request at all. It is empty on a cold
  /// open (or when the socket never connected), and then this fetches, which is
  /// the same decrypt path the map's poller uses. A failed fetch (null) yields no
  /// battery/ago lines rather than an error: they are an enrichment of the
  /// members list, not the point of it.
  ///
  /// The shared store speaks for the SELECTED circle only — that is the circle
  /// the socket subscribes to. For any other circle this fetches and keeps the
  /// result to itself, rather than showing one circle's battery levels on
  /// another's roster.
  Future<Map<String, MemberPosition>> _positions() async {
    final selectedId = ref.read(controllerProvider).selectedCircle?.id;
    final shared = widget.circleId == selectedId;
    final store = ref.read(memberPositionStoreProvider);
    if (shared && store.positions.isNotEmpty) return store.positions;

    final fetched = await ref
        .read(controllerProvider.notifier)
        .loadMemberPositions(widget.circleId);
    if (fetched == null) return const {};
    // Feed the store so the map (and the next open of this screen) start warm —
    // but only when it is this circle's store to feed.
    if (shared) store.bulk(fetched);
    return fetched;
  }

  Future<void> _refresh() async {
    final next = _load();
    setState(() => _future = next);
    await next;
  }

  /// Mutes/unmutes ONE member. The PUT replaces the whole set, so the next state
  /// is built from the current one with the pure helper — never hand-assembled.
  /// The server then stops fanning that member's notifications out to this
  /// account; it is not local suppression.
  Future<void> _toggleMute(MemberRow row, bool muted) async {
    final userId = row.member.userId;
    if (_muting.contains(userId)) return;
    final l10n = AppLocalizations.of(context);
    final previous = _mutes;
    final next = _mutes.withMemberMuted(userId, muted);
    setState(() {
      _muting.add(userId);
      _mutes = next; // optimistic: the bell moves under the thumb
    });
    final stored = await ref
        .read(controllerProvider.notifier)
        .setMutes(widget.circleId, next);
    if (!mounted) return;
    setState(() {
      _muting.remove(userId);
      // Settle on the server's echo of what it actually stored; on failure, spring
      // back rather than claiming a mute that isn't there.
      _mutes = stored ?? previous;
    });
    if (stored == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.membersMuteFailed)));
    }
  }

  /// Removes a member (owner-only), then offers the key rotation that actually
  /// cuts them off: removal alone leaves them holding K_c (no forward secrecy),
  /// so they could still read data sent from now on.
  Future<void> _remove(MemberRow row) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ctrl = ref.read(controllerProvider.notifier);
    final confirmed = await _confirm(
      title: l10n.membersRemoveTitle,
      body: l10n.membersRemoveConfirm(row.name),
      confirmLabel: l10n.membersRemoveAction,
      danger: true,
    );
    if (!confirmed) return;
    try {
      await ctrl.removeMemberFrom(widget.circleId, row.member.userId);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.membersRemoveFailed)));
      return;
    }
    await _refresh();
    if (!mounted) return;
    final rotate = await _confirm(
      title: l10n.rotateKeyTitle,
      body: l10n.membersRotateAfterRemove,
      confirmLabel: l10n.rotateKeyConfirm,
    );
    if (!rotate) return;
    final ok = await ctrl.rotateSelectedCircleKey();
    messenger.showSnackBar(
      SnackBar(
        content: Text(ok ? l10n.rotateKeySuccess : l10n.rotateKeyFailure),
      ),
    );
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
    bool danger = false,
  }) async {
    final l10n = AppLocalizations.of(context);
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: danger
                ? TextButton.styleFrom(foregroundColor: AulColors.danger)
                : null,
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return res ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final myEmail = ref.watch(controllerProvider.select((s) => s.email));
    final myUserId = ref.watch(controllerProvider.select((s) => s.userId));

    // The socket says someone joined, left, or changed how they share — refetch,
    // so this list stops being a snapshot of whenever it was opened. Without a
    // socket nothing fires and pull-to-refresh is still the way, which is exactly
    // the fallback the poller is elsewhere.
    ref.listen(realtimeProvider.select((r) => r.members), (_, _) {
      unawaited(_refresh());
    });
    // My role in THIS circle decides whether removal is offered at all (the
    // server enforces it too).
    final amOwner = ref.watch(
      controllerProvider.select(
        (s) =>
            s.circles
                .where((c) => c.id == widget.circleId)
                .map((c) => c.role == 'owner')
                .firstOrNull ??
            false,
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.membersTitle),
        actions: [
          IconButton(
            tooltip: l10n.verifyDevicesTitle,
            icon: const Icon(Icons.verified_user_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => VerifyDevicesScreen(circleId: widget.circleId),
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<MemberRow>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return _centeredMessage(l10n.membersError);
            }
            final rows = snap.data ?? const <MemberRow>[];
            if (rows.isEmpty) {
              return _centeredMessage(l10n.membersEmpty);
            }
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: rows.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final row = rows[i];
                // Identify "you" by user id first (it survives a relaunch, and it
                // is what the server matches a self-mute against), falling back to
                // the email of the signed-in session.
                final isMe = myUserId != null
                    ? row.member.userId == myUserId
                    : (myEmail != null && row.member.email == myEmail);
                final muted = _mutes.isMemberMuted(row.member.userId);
                final pos = row.position;
                return _MemberTile(
                  row: row,
                  isMe: isMe,
                  muted: muted,
                  // Tapping a member opens the map centred + zoomed on their
                  // latest decrypted position. A member we have no position for
                  // is not tappable — there is nowhere to fly to. Mirrors the web
                  // MembersPanel row `onClick` → `useMapFocus.focus`.
                  onTap: pos == null
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => MapScreen(
                              circleId: widget.circleId,
                              focusLat: pos.fix.lat,
                              focusLng: pos.fix.lng,
                            ),
                          ),
                        ),
                  // Never on yourself: the server rejects a self-mute with 400,
                  // and the fan-out already excludes your own devices.
                  onToggleMute: isMe ? null : () => _toggleMute(row, !muted),
                  muteBusy: _muting.contains(row.member.userId),
                  // Owners can remove anyone but themselves (leaving is the
                  // self-serve path, and a sole owner must delete instead).
                  onRemove: amOwner && !isMe ? () => _remove(row) : null,
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// A scrollable centered message so pull-to-refresh still works on empty/error.
  Widget _centeredMessage(String text) => ListView(
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

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.row,
    required this.isMe,
    required this.muted,
    this.onTap,
    this.onToggleMute,
    this.muteBusy = false,
    this.onRemove,
  });

  final MemberRow row;
  final bool isMe;

  /// Opens the map focused on this member. Null when they have no known position
  /// — a subtle no-op rather than a fly-to nowhere.
  final VoidCallback? onTap;

  /// Whether this member's notifications are stopped before they reach the user.
  final bool muted;

  /// Non-null for every member EXCEPT the user themselves — the server rejects a
  /// self-mute with 400.
  final VoidCallback? onToggleMute;
  final bool muteBusy;

  /// Non-null only when the viewer is an owner and this row isn't them.
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final primary = Theme.of(context).colorScheme.primary;
    final isOwner = row.member.role == 'owner';
    final position = row.position;
    // A position older than the shared freshness threshold is presented as stale,
    // not current: an amber "updated N ago" and a "Stale" chip, so a last-known
    // dot for a member who has gone quiet (offline, no signal, or the realtime
    // server is gone) never reads as a live location. Below the threshold nothing
    // changes. Presentation only — the decrypted capture time drives it.
    final now = DateTime.now();
    final stale = position != null && isStale(position.updatedAt, now);
    final agoColor = stale ? AulColors.amber : AulColors.textSecondary;

    return Card(
      clipBehavior:
          Clip.antiAlias, // keep the tap ripple inside the rounded card
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              _Avatar(name: row.name, bytes: row.avatarBytes, primary: primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            row.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (isMe) ...[
                          const SizedBox(width: 6),
                          Text(
                            l10n.profileYou,
                            style: const TextStyle(
                              color: AulColors.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isOwner ? l10n.circleOwnerBadge : l10n.circleRoleMember,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AulColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    // How this member shares, when they were last heard from, and
                    // how sure their phone is about where it is. "Precise" with no
                    // fix for two hours is a very different thing from "Precise,
                    // just now", and a ±40 m fix is a different thing from a
                    // ±1.2 km one. The row wraps between these facts (never inside
                    // one) so "±40 m" never strands its unit on its own line —
                    // mirrors the web MembersPanel.
                    Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          _precisionLabel(l10n, row.member.precisionMode),
                          style: const TextStyle(
                            fontSize: 12,
                            color: AulColors.textSecondary,
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.place_outlined,
                              size: 12,
                              color: agoColor,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              position == null
                                  ? l10n.membersNoPosition
                                  : formatAgo(l10n, position.updatedAt, now),
                              style: TextStyle(
                                fontSize: 12,
                                color: agoColor,
                                fontWeight: stale
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                        if (stale)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: AulColors.amber.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              l10n.staleBadge,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AulColors.amber,
                              ),
                            ),
                          ),
                        if (position != null &&
                            isUsableAccuracy(position.fix.accuracy))
                          Text(
                            _accuracyLabel(
                              l10n,
                              context,
                              position.fix.accuracy!,
                            ),
                            style: const TextStyle(
                              fontSize: 12,
                              color: AulColors.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (position?.battery != null) ...[
                _Battery(pct: position!.battery!, primary: primary),
                const SizedBox(width: 4),
              ],
              if (onToggleMute != null)
                IconButton(
                  tooltip: muted
                      ? l10n.membersUnmute(row.name)
                      : l10n.membersMute(row.name),
                  icon: Icon(
                    muted
                        ? Icons.notifications_off_outlined
                        : Icons.notifications_outlined,
                  ),
                  color: muted ? AulColors.danger : AulColors.textSecondary,
                  onPressed: muteBusy ? null : onToggleMute,
                ),
              if (onRemove != null)
                IconButton(
                  tooltip: l10n.membersRemove,
                  icon: const Icon(Icons.person_remove_outlined),
                  color: AulColors.textSecondary,
                  onPressed: onRemove,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How a member shares, as this circle sees it. Server metadata (the members
/// list carries precision_mode), not something read out of their last ping — a
/// paused member sends no pings, so their last one would claim its old mode
/// forever.
/// The "±N m" / "±N,N km" figure for a member's reported location uncertainty.
/// The number + unit split lives in [accuracyParts] (shared with the map halo);
/// this only localizes the unit and stitches them together, in the active
/// locale's number notation. Mirrors the web `formatAccuracy`.
String _accuracyLabel(
  AppLocalizations l10n,
  BuildContext context,
  double accuracy,
) {
  final parts = accuracyParts(
    accuracy,
    Localizations.localeOf(context).languageCode,
  );
  final unit = parts.isKilometers ? l10n.unitKilometers : l10n.unitMeters;
  return l10n.membersAccuracy(parts.value, unit);
}

String _precisionLabel(AppLocalizations l10n, String wire) =>
    switch (PrecisionMode.fromWire(wire)) {
      PrecisionMode.precise => l10n.precisionPrecise,
      PrecisionMode.city => l10n.precisionCity,
      PrecisionMode.paused => l10n.precisionPaused,
    };

/// A member's battery, coloured by how worrying it is: red at/below 15, amber
/// at/below 30 (the web's thresholds, so the same phone reads the same on both).
///
/// It came out of the sealed ping — the server never saw it.
class _Battery extends StatelessWidget {
  const _Battery({required this.pct, required this.primary});

  final int pct;
  final Color primary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final color = batteryColor(pct, primary: primary);
    final label = l10n.batteryPercent(pct);
    return Semantics(
      // The icon carries meaning the bare number doesn't; without this a screen
      // reader announces "72%" of nothing in particular.
      label: '${l10n.batteryLabel}: $label',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.battery_std_outlined, size: 14, color: color),
          const SizedBox(width: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.name,
    required this.bytes,
    required this.primary,
  });

  final String name;
  final Uint8List? bytes;
  final Color primary;

  @override
  Widget build(BuildContext context) {
    final b = bytes;
    if (b != null) {
      return CircleAvatar(radius: 22, backgroundImage: MemoryImage(b));
    }
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
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
