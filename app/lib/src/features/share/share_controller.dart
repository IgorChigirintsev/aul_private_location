import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controller.dart';
import '../../data/api/models.dart';
import 'share_keys.dart';
import 'share_session.dart';

/// What the UI renders for live shares.
class ShareState {
  const ShareState({
    this.sessions = const [],
    this.keys = const {},
    this.loading = false,
    this.error = false,
  });

  /// The caller's own sessions, as of the last successful fetch.
  final List<ShareSession> sessions;

  /// sessionId → base64url(K_share), for the sessions created on THIS device.
  /// A session missing from here was made elsewhere: it can still be revoked,
  /// but its link cannot be shown and this device cannot feed it.
  final Map<String, String> keys;

  final bool loading;

  /// True when the last create attempt failed.
  final bool error;

  /// Sessions that are still live right now.
  List<ShareSession> live([DateTime? now]) =>
      sessions.where((s) => isShareLive(s, now)).toList();

  /// Whether a share is running — i.e. whether the app must admit on screen that
  /// a non-member is being shown this location.
  bool get hasLive => live().isNotEmpty;

  /// The soonest deadline among live sessions — the one a countdown should be
  /// about. Null when nothing is live.
  DateTime? get nextDeadline {
    final l = live();
    if (l.isEmpty) return null;
    return l.map((s) => s.expiresAt).reduce((a, b) => a.isBefore(b) ? a : b);
  }

  ShareState copyWith({
    List<ShareSession>? sessions,
    Map<String, String>? keys,
    bool? loading,
    bool? error,
  }) => ShareState(
    sessions: sessions ?? this.sessions,
    keys: keys ?? this.keys,
    loading: loading ?? this.loading,
    error: error ?? this.error,
  );
}

final shareControllerProvider = NotifierProvider<ShareController, ShareState>(
  ShareController.new,
);

/// Creates time-boxed links that let ONE outsider — no account, no app — watch
/// this device's live location, and keeps the UI honest about what is running.
///
/// The key that decrypts the position (K_share) is generated HERE, per session,
/// and goes into the link's fragment. It is NOT the circle key: a viewer sees
/// this one person for this one window and can never see the circle. The server
/// gets a session id and ciphertext, never the key.
///
/// IT DOES NOT FEED THE SESSIONS. Every session it creates is written to
/// [ShareKeyStore] — id, K_share, deadline — and the headless location isolate
/// reads that and does the sealing and the PUTs ([BackgroundShares]). This
/// class only creates, revokes, and renders. The split is not incidental: the
/// foreground never sees a fix (they land on `app.aul/bg`, in the isolate), and
/// a share whose feeding stopped when the app was backgrounded would be a share
/// that does not work, which is what shipped.
///
/// Positions come from the location stream the app already runs (the foreground
/// service, via [AppController.setShareNeedsLocation]) — sharing costs no extra
/// sensor, and needs no circle key or circle at all.
class ShareController extends Notifier<ShareState> {
  Timer? _refreshTimer;
  ShareKeyStore? _store;

  /// Set when this notifier is torn down (sign-out, provider scope disposal).
  /// Several paths here are fire-and-forget — a create kicks off a refresh, a
  /// timer tick lands mid-teardown — and touching `state` after disposal is an
  /// error, so every async continuation checks this before writing.
  bool _disposed = false;

  @override
  ShareState build() {
    // A sign-out (or a server switch) must not leave a timer feeding a session
    // with tokens that no longer exist.
    ref.listen(controllerProvider.select((s) => s.phase), (prev, next) {
      if (next == AuthPhase.signedIn && prev != AuthPhase.signedIn) {
        unawaited(refresh());
      } else if (next == AuthPhase.signedOut) {
        _stopTimers();
        state = const ShareState();
      }
    });
    ref.onDispose(() {
      _disposed = true;
      _stopTimers();
    });
    unawaited(_restore());
    return const ShareState();
  }

  ShareKeyStore _ensureStore() =>
      _store ??= ShareKeyStore(ref.read(vaultProvider));

  /// Reads the keys this device persisted, then asks the server what is still
  /// live. A restart mid-session lands here and picks the session back up.
  Future<void> _restore() async {
    final keys = await _ensureStore().loadKeys();
    if (_disposed) return;
    state = state.copyWith(keys: keys);
    if (state.keys.isEmpty) return; // nothing here could feed a session
    await refresh();
  }

  /// Re-reads the caller's sessions and prunes the keys of everything that has
  /// died. Best-effort: on a failed fetch the last snapshot (and every key) is
  /// kept, because a network blip must not orphan a live session.
  Future<void> refresh() async {
    if (_disposed) return;
    final api = ref.read(controllerProvider.notifier).api;
    if (api == null) return;
    final store = _ensureStore();
    // Stamped BEFORE the fetch goes out: a session created while it is in flight
    // cannot be in the answer, and must not be pruned as though it were dead.
    final startedAt = DateTime.now().toUtc();
    try {
      final sessions = await api.listShares();
      // The server drops expired sessions from the list, so a SUCCESSFUL fetch
      // is also the signal to forget the keys of everything that is gone — and
      // to refresh the deadlines the isolate enforces against.
      await store.sync(sessions, startedAt);
      final keys = await store.loadKeys();
      if (_disposed) return; // torn down mid-flight
      state = state.copyWith(sessions: sessions, keys: keys);
    } catch (_) {
      // offline / transient — keep what we have and let the timer retry
    }
    await _applyLiveness();
  }

  /// Creates a session with a fresh 32-byte K_share and returns its id, or null
  /// on failure (the error is surfaced on state).
  Future<String?> create(int ttlSeconds) async {
    if (_disposed) return null;
    final ctrl = ref.read(controllerProvider.notifier);
    final api = ctrl.api;
    if (api == null) return null;
    state = state.copyWith(loading: true, error: false);
    try {
      final crypto = await ctrl.crypto;
      // 32 fresh random bytes — a per-session key, never the circle key.
      final key = crypto.generateCircleKey();
      final String keyB64Url;
      try {
        keyB64Url = toBase64Url(key.extractBytes());
      } finally {
        key.dispose();
      }
      final session = await api.createShare(ttlSeconds);
      // Store the key BEFORE showing the link: a crash between the two would
      // otherwise leave a live session this device could no longer feed. This
      // write is also what hands the session to the location isolate — it is the
      // ONLY way the isolate can learn K_share, so the link is not live until it
      // lands.
      final store = _ensureStore();
      await store.add(session.id, keyB64Url, session.expiresAt);
      final keys = await store.loadKeys();
      if (_disposed) return null;
      state = state.copyWith(
        sessions: [...state.sessions, session],
        keys: keys,
        loading: false,
      );
      await _applyLiveness();
      unawaited(refresh());
      return session.id;
    } catch (_) {
      if (_disposed) return null;
      state = state.copyWith(loading: false, error: true);
      return null;
    }
  }

  /// Kills a session now and forgets its key.
  Future<void> revoke(String id) async {
    final api = ref.read(controllerProvider.notifier).api;
    try {
      await api?.revokeShare(id);
    } catch (_) {
      // already gone server-side — drop it locally anyway
    }
    // Forgetting the key is also what STOPS the isolate feeding this session:
    // it seals for whatever is in the store, so the entry has to go even if the
    // server call above failed.
    final store = _ensureStore();
    await store.forget(id);
    final keys = await store.loadKeys();
    if (_disposed) return;
    state = state.copyWith(
      sessions: [
        for (final s in state.sessions)
          if (s.id != id) s,
      ],
      keys: keys,
    );
    await _applyLiveness();
    unawaited(refresh());
  }

  /// Revokes every live session, for sign-out. A link that outlived its owner's
  /// session would keep showing a stranger where they are, so this is not
  /// best-effort about the local state: the keys go regardless.
  Future<void> revokeAllForSignOut() async {
    final api = ref.read(controllerProvider.notifier).api;
    for (final s in state.live()) {
      try {
        await api?.revokeShare(s.id);
      } catch (_) {
        // offline — the server still expires it at its deadline
      }
    }
    _stopTimers();
    // Clears K_share for every session, live or not: the isolate seals for
    // whatever is in this store, and it must not outlive the account.
    await _ensureStore().clear();
    if (_disposed) return;
    state = const ShareState();
  }

  /// Keeps the location need and the UI refresh matched to what is live.
  ///
  /// There is no ping timer here. The isolate seals on each fix it receives,
  /// which is the only cadence that exists — nothing in the foreground has a
  /// position to send on a timer, and a timer that fired while the app was
  /// backgrounded would not run at all.
  Future<void> _applyLiveness() async {
    if (_disposed) return;
    final live = state.hasLive;
    await ref.read(controllerProvider.notifier).setShareNeedsLocation(live);
    if (live) {
      // Only while the UI is up: this refresh is for the countdown and the
      // "viewer connected" badge. The isolate runs its own on the same interval,
      // because it must keep noticing revokes with the app closed.
      _refreshTimer ??= Timer.periodic(
        kShareRefreshInterval,
        (_) => unawaited(refresh()),
      );
    } else {
      _stopTimers();
    }
  }

  void _stopTimers() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }
}
