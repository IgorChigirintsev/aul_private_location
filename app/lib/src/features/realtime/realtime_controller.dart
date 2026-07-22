import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controller.dart';
import '../map/member_position_store.dart';
import 'realtime_client.dart';

/// The live positions of the selected circle's members, fed by BOTH the realtime
/// socket and the map poller. App-scoped rather than owned by the map screen: the
/// socket runs whenever the app is open, so positions arrive before the map is
/// ever opened, and the members screen reads the same store for battery +
/// "updated N ago".
final memberPositionStoreProvider = Provider<MemberPositionStore>((ref) {
  final store = MemberPositionStore();
  ref.onDispose(store.dispose);
  return store;
});

/// What the realtime connection has to tell the UI.
///
/// Everything except [connected] is a REVISION COUNTER, not data: the socket says
/// "the members changed", and the screen that shows members refetches through its
/// existing, authenticated, decrypting path. This keeps one way of loading each
/// thing — the socket decides WHEN, never WHAT — and keeps the app correct when
/// the socket is down, which is exactly when polling has to carry it.
///
/// Positions are the one exception, and they go to [memberPositionStoreProvider]
/// rather than through here: a ping carries the position itself, so refetching it
/// would throw away the very thing that arrived.
class RealtimeSignals {
  const RealtimeSignals({
    this.connected = false,
    this.sos = 0,
    this.places = 0,
    this.members = 0,
    this.disconnectedSince,
  });

  /// Whether the socket is up. False means the app is running on polling alone —
  /// slower, but not broken.
  final bool connected;

  /// When the socket most recently dropped, or null while [connected]. Frozen at
  /// the FIRST moment of an outage (a repeated 'false' keeps it), so the
  /// connection banner can say "last connected N ago" — the honest staleness a
  /// viewer needs when a self-hosted box goes offline.
  final DateTime? disconnectedSince;

  /// Bumped when an SOS is raised or resolved in the selected circle.
  final int sos;

  /// Bumped when the selected circle's places change.
  final int places;

  /// Bumped when the selected circle's membership OR anyone's precision mode
  /// changes — both are read from the same members list, and precision is what
  /// greys out a paused member's marker for everyone else.
  final int members;

  RealtimeSignals copyWith({
    bool? connected,
    int? sos,
    int? places,
    int? members,
    DateTime? disconnectedSince,
    bool clearDisconnectedSince = false,
  }) => RealtimeSignals(
    connected: connected ?? this.connected,
    sos: sos ?? this.sos,
    places: places ?? this.places,
    members: members ?? this.members,
    disconnectedSince: clearDisconnectedSince
        ? null
        : (disconnectedSince ?? this.disconnectedSince),
  );
}

final realtimeProvider = NotifierProvider<RealtimeController, RealtimeSignals>(
  RealtimeController.new,
);

/// Keeps one [RealtimeClient] connected to the SELECTED circle for as long as the
/// app is open, and turns its events into signals the screens watch. Mirrors
/// where the web wires its client (the Dashboard, for the selected circle).
///
/// Something must watch this provider for the socket to exist at all; the home
/// screen does, and every other screen is pushed on top of it.
class RealtimeController extends Notifier<RealtimeSignals> {
  RealtimeClient? _client;

  /// Guards against a slow connect landing after the circle already changed. Each
  /// [build] takes the next number; a connect that finishes holding a stale one
  /// throws its client away instead of installing it over the current circle's.
  int _generation = 0;

  @override
  RealtimeSignals build() {
    final circleId = ref.watch(
      controllerProvider.select((s) => s.selectedCircle?.id),
    );
    final signedIn = ref.watch(
      controllerProvider.select((s) => s.phase == AuthPhase.signedIn),
    );

    final generation = ++_generation;
    // Runs before each rebuild as well as on final teardown: the old circle's
    // socket and keyring never outlive the switch.
    ref.onDispose(() {
      _client?.dispose();
      _client = null;
    });

    if (signedIn && circleId != null) {
      unawaited(_connect(circleId, generation));
    }
    return const RealtimeSignals();
  }

  Future<void> _connect(String circleId, int generation) async {
    final ctrl = ref.read(controllerProvider.notifier);
    // The previous circle's members have no business on this circle's map.
    ref.read(memberPositionStoreProvider).reset();

    final client = await ctrl.createRealtimeClient(
      circleId,
      handlers: RealtimeHandlers(
        onPosition: (deviceId, fix) {
          if (generation != _generation) return;
          ref.read(memberPositionStoreProvider).applyFix(deviceId, fix);
        },
        onSos: (_) => _bump(generation, (s) => s.copyWith(sos: s.sos + 1)),
        onSosResolved: (_) =>
            _bump(generation, (s) => s.copyWith(sos: s.sos + 1)),
        onPlaceUpdated: () =>
            _bump(generation, (s) => s.copyWith(places: s.places + 1)),
        onMemberChanged: () =>
            _bump(generation, (s) => s.copyWith(members: s.members + 1)),
        // Someone changed how they share. The circle list carries precision_mode
        // for THIS user's own control; the members list carries everyone's, and
        // that is what the map greys a paused member out from.
        onPrecision: () {
          if (generation != _generation) return;
          unawaited(ctrl.refreshCircles());
          _bump(generation, (s) => s.copyWith(members: s.members + 1));
        },
        // A rotated key was just re-sealed to this device. Opening it now is what
        // keeps the map from going blank until the next launch.
        onKeyEnvelope: () {
          if (generation != _generation) return;
          unawaited(ctrl.syncKeys());
        },
        onStatus: (connected) => _bump(generation, (s) {
          if (connected) {
            return s.copyWith(connected: true, clearDisconnectedSince: true);
          }
          // Stamp the drop on the true→false transition only; a repeated 'false'
          // (a failed reconnect) keeps the original moment.
          return s.copyWith(
            connected: false,
            disconnectedSince: s.connected
                ? DateTime.now()
                : s.disconnectedSince,
          );
        }),
      ),
    );
    if (client == null) return;
    // The circle changed (or we were torn down) while the keyring loaded — this
    // client is already obsolete, and disposing it frees the keys it holds.
    if (generation != _generation) {
      client.dispose();
      return;
    }
    _client = client;
    client.connect();
  }

  /// Applies a state change, unless this callback belongs to a client whose
  /// circle is no longer selected (its events would be answering the wrong
  /// question) or whose provider is already gone (setting state then throws).
  void _bump(int generation, RealtimeSignals Function(RealtimeSignals) next) {
    if (generation != _generation) return;
    state = next(state);
  }
}
