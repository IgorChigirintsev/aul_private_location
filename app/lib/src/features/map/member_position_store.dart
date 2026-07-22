import 'dart:async';

import '../../domain/location_fix.dart';
import 'member_positions.dart';

/// Every circle member's most recent decrypted position, keyed by device id.
///
/// TWO producers feed this, and that is the whole reason it exists:
///
///  * the POLLER delivers whole snapshots — every device, each joined with the
///    roster, the member's profile, and their current precision mode;
///  * the SOCKET delivers one fix at a time, the moment it happens, with none of
///    that join (a ping event carries a device id and ciphertext, nothing more).
///
/// They overlap constantly: a ping arrives live and then shows up again in the
/// next poll. So the "newest capture per device wins" rule lives HERE, once,
/// instead of being re-derived by each producer — which is what "don't
/// double-apply positions" means in practice. Out-of-order delivery is safe by
/// construction, and applying the same position twice is a no-op.
///
/// Mirrors the web positions store (web/src/store/positions.ts), which has the
/// same two producers and the same rule.
class MemberPositionStore {
  final _byDevice = <String, MemberPosition>{};
  final _controller = StreamController<Map<String, MemberPosition>>.broadcast();
  bool _disposed = false;

  /// The current snapshot (empty until the first poll or ping lands).
  Map<String, MemberPosition> get positions => Map.unmodifiable(_byDevice);

  /// Broadcast stream of snapshots, newest last.
  Stream<Map<String, MemberPosition>> get stream => _controller.stream;

  /// Applies a POLL snapshot.
  ///
  /// The poll is authoritative about two things and not a third. It decides who
  /// is in the picture (a device missing here has dropped out, so it goes), and
  /// it carries the freshest metadata (name, avatar, and the precision mode that
  /// greys a paused member out). It does NOT get to decide the position: a fix
  /// the socket delivered while this request was in flight is newer than the one
  /// it is answering with. So a newer live fix survives the poll that would
  /// otherwise walk the marker backwards.
  void bulk(Map<String, MemberPosition> snapshot) {
    if (_disposed) return;
    final next = <String, MemberPosition>{};
    for (final entry in snapshot.entries) {
      final existing = _byDevice[entry.key];
      final polled = entry.value;
      next[entry.key] =
          existing != null && existing.updatedAt.isAfter(polled.updatedAt)
          ? polled.copyWith(fix: existing.fix) // poll's metadata, live fix
          : polled;
    }
    _byDevice
      ..clear()
      ..addAll(next);
    _emit();
  }

  /// Applies ONE live fix from the realtime socket.
  ///
  /// Ignored when it is not newer than what we already hold for the device. The
  /// metadata comes from whatever the last poll joined for this device, so a
  /// member keeps their name and face between polls; a device seen live before it
  /// has ever been polled shows up straight away with its device id as the label,
  /// and the next poll dresses it properly.
  void applyFix(String deviceId, LocationFix fix) {
    if (_disposed) return;
    final existing = _byDevice[deviceId];
    if (existing != null && !fix.capturedAt.isAfter(existing.updatedAt)) {
      return; // older or identical — the newest capture stands
    }
    _byDevice[deviceId] =
        existing?.copyWith(fix: fix) ??
        MemberPosition(deviceId: deviceId, fix: fix);
    _emit();
  }

  /// Drops everything — on a circle switch, where the previous circle's members
  /// have no business appearing.
  void reset() {
    if (_disposed || _byDevice.isEmpty) return;
    _byDevice.clear();
    _emit();
  }

  void _emit() {
    if (!_controller.isClosed) _controller.add(positions);
  }

  /// Closes the stream. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _byDevice.clear();
    _controller.close();
  }
}
