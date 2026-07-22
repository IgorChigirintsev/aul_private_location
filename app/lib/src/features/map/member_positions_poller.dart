import 'dart:async';

import 'member_positions.dart';

/// Polls a circle's decrypted member positions on a fixed cadence and pushes
/// each snapshot onto a broadcast [stream]. The actual fetch+decrypt is injected
/// as [_fetch] (normally `AppController.loadMemberPositions(circleId)`) so this
/// class stays a plain, testable timer with no direct network/crypto coupling.
///
/// This is the FALLBACK under the realtime socket, and it carries the join the
/// socket cannot (roster, profiles, precision modes). It keeps running while the
/// socket is up: a socket can be down without saying so, and the two agree
/// through the position store's newest-wins rule rather than by taking turns.
///
/// A fetch that FAILS emits nothing — the last known snapshot stands and the next
/// tick retries. That is why [_fetch] returns null for "couldn't", distinct from
/// an empty map for "nobody is sharing": conflating them would let one flaky
/// request blank the map, including positions the socket had just delivered.
///
/// The timer is cancelled and the stream closed in [dispose]; call it from the
/// owning widget's teardown so no timer leaks.
class MemberPositionsPoller {
  MemberPositionsPoller({
    required Future<Map<String, MemberPosition>?> Function() fetch,
    this.interval = const Duration(seconds: 17),
  }) : _fetch = fetch;

  /// Fetches a snapshot, or null when it could not be fetched at all.
  final Future<Map<String, MemberPosition>?> Function() _fetch;

  /// Poll cadence — ~15–20 s, matching the reporter's live/normal fan-out so the
  /// map stays fresh without hammering the server. This is the floor on
  /// freshness, not the norm: with the socket up, a move shows up as it happens
  /// and this is just the safety net underneath.
  final Duration interval;

  Timer? _timer;
  final _controller = StreamController<Map<String, MemberPosition>>.broadcast();
  bool _disposed = false;

  /// The most recent snapshot (empty until the first successful fetch).
  Map<String, MemberPosition> latest = const {};

  /// Broadcast stream of position snapshots, newest last.
  Stream<Map<String, MemberPosition>> get stream => _controller.stream;

  /// Fetches once immediately, then every [interval]. Safe to call once.
  void start() {
    _tick();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  /// Forces an out-of-band refresh (e.g. pull-to-refresh / recenter).
  Future<void> refresh() => _tick();

  Future<void> _tick() async {
    final Map<String, MemberPosition>? next;
    try {
      next = await _fetch();
    } catch (_) {
      return; // keep the last known snapshot; the next tick retries
    }
    // null ⇒ the fetch failed. Emitting an empty snapshot here would read as
    // "nobody is sharing" and blank the map on one dropped request.
    if (_disposed || next == null) return;
    latest = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  /// Cancels the timer and closes the stream. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _controller.close();
  }
}
