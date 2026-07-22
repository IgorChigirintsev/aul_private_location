import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../controller.dart';
import '../../data/api/api_client.dart';
import '../notifications/notification_service.dart';
import '../push/push_messaging.dart';
import 'retention_prefs.dart';

/// Snapshot of the retention feature gating the UI renders.
///
/// A feature is ACTIVE iff [serverEnabled] (the operator kill-switch from
/// `GET /v1/server-info`) AND its per-feature user opt-in are both true. Every
/// opt-in defaults false, so nothing activates until the user chooses in.
class RetentionState {
  const RetentionState({
    this.serverEnabled = false,
    this.fcmEnabled = false,
    this.arrivalEnabled = false,
    this.reengageEnabled = false,
    this.pushEnabled = false,
    this.loaded = false,
  });

  final bool serverEnabled;

  /// The operator configured FCM credentials (`fcm_enabled` from
  /// `GET /v1/server-info`). A SECOND gate on top of [serverEnabled], because a
  /// server can perfectly well allow the retention features and still have no
  /// way to deliver a push: offering the switch there would register a token
  /// nothing could ever wake. Mirrors the web hiding its push toggle when the
  /// operator configured no VAPID keys.
  final bool fcmEnabled;

  final bool arrivalEnabled;
  final bool reengageEnabled;
  final bool pushEnabled;

  /// True once the local opt-ins have been read from storage.
  final bool loaded;

  bool enabled(RetentionFeature f) => switch (f) {
    RetentionFeature.arrival => arrivalEnabled,
    RetentionFeature.reengage => reengageEnabled,
    RetentionFeature.push => pushEnabled,
  };

  /// Whether [f] may act: the user opted in AND the server permits it. Push
  /// carries the extra [fcmEnabled] gate — nothing else does.
  bool active(RetentionFeature f) =>
      serverEnabled && enabled(f) && (f != RetentionFeature.push || fcmEnabled);

  bool get arrivalActive => active(RetentionFeature.arrival);
  bool get reengageActive => active(RetentionFeature.reengage);
  bool get pushActive => active(RetentionFeature.push);

  /// Whether the push switch is worth showing at all.
  bool get pushAvailable => serverEnabled && fcmEnabled;

  RetentionState copyWith({
    bool? serverEnabled,
    bool? fcmEnabled,
    bool? arrivalEnabled,
    bool? reengageEnabled,
    bool? pushEnabled,
    bool? loaded,
  }) => RetentionState(
    serverEnabled: serverEnabled ?? this.serverEnabled,
    fcmEnabled: fcmEnabled ?? this.fcmEnabled,
    arrivalEnabled: arrivalEnabled ?? this.arrivalEnabled,
    reengageEnabled: reengageEnabled ?? this.reengageEnabled,
    pushEnabled: pushEnabled ?? this.pushEnabled,
    loaded: loaded ?? this.loaded,
  );
}

final retentionProvider = NotifierProvider<RetentionController, RetentionState>(
  RetentionController.new,
);

/// Owns retention opt-in state: loads the local opt-ins, fetches the server
/// kill-switch, and persists toggles. Keeps the anti-stalking defaults (all OFF)
/// and never activates a feature the server has disabled.
class RetentionController extends Notifier<RetentionState> {
  RetentionPrefs? _prefs;

  /// Whether this session has already handed the server an FCM token. Guards
  /// against re-registering on every server-flag refresh; cleared when the user
  /// opts out, so opting back in registers again.
  bool _pushSynced = false;

  @override
  RetentionState build() {
    // Re-read the server kill-switch whenever the signed-in server changes.
    ref.listen(controllerProvider.select((s) => s.serverUrl), (prev, next) {
      if (next != null && next != prev) refreshServerFlag();
    });
    _load();
    return const RetentionState();
  }

  Future<RetentionPrefs> _ensurePrefs() async =>
      _prefs ??= RetentionPrefs(await SharedPreferences.getInstance());

  Future<void> _load() async {
    final prefs = await _ensurePrefs();
    state = state.copyWith(
      arrivalEnabled: prefs.arrivalEnabled,
      reengageEnabled: prefs.reengageEnabled,
      pushEnabled: prefs.pushEnabled,
      loaded: true,
    );
    await refreshServerFlag(); // registers push too, once the flags allow it
  }

  /// Re-reads the server kill-switch. Best-effort: if the server is unreachable
  /// or we are signed out, the last-known value is kept (defaults OFF), so
  /// features stay disabled rather than silently activating.
  Future<void> refreshServerFlag() async {
    final url = ref.read(controllerProvider).serverUrl;
    if (url == null) return;
    try {
      final api = AulApi(baseUrl: url, vault: ref.read(vaultProvider));
      final info = await api.serverInfo();
      // Mirrored to disk BEFORE the mounted check: the background isolate reads
      // the kill-switch from there and has no other way to learn it, and a
      // sign-out racing this call must not cost it the answer. Persisting a flag
      // is safe when the provider is gone; touching state is not.
      (await _ensurePrefs()).setServerEnabled(info.retentionFeaturesEnabled);
      // The provider can be disposed while this call is in flight — a sign-out
      // is exactly that — and touching state/ref afterwards throws.
      if (!ref.mounted) return;
      state = state.copyWith(
        serverEnabled: info.retentionFeaturesEnabled,
        fcmEnabled: info.fcmEnabled,
      );
    } catch (_) {
      // offline / not signed in — keep current value (OFF by default)
    }
    if (!ref.mounted) return;
    await _syncPush();
  }

  /// Hands the server this device's current token once the flags say push may
  /// run at all.
  ///
  /// This hangs off the flag refresh rather than off [_load] because of the
  /// order things actually happen in: a cold start reads the local opt-in
  /// immediately, but `serverUrl` (and so `fcm_enabled`) only arrives once the
  /// session has been restored — so at [_load] time `pushActive` is still false
  /// even for a user who opted in long ago. Registering here instead catches
  /// both that restore and a later sign-in.
  ///
  /// Re-registering each launch is the point, not a wart: an FCM token rotates
  /// (app restore, cleared storage), and a token the server still holds but FCM
  /// no longer routes here is a subscription that fails silently forever. The
  /// call is idempotent server-side, and [_pushSynced] keeps it to once a
  /// session.
  Future<void> _syncPush() async {
    if (!state.pushActive || _pushSynced) return;
    // NOT userInitiated: nobody is watching a prompt, and this fires on every
    // launch — including offline ones. A failure here must leave the opt-in
    // alone and simply be retried, or a single flight-mode start would silently
    // switch push off for good.
    await _registerPush(userInitiated: false);
  }

  /// The signed-in API client, or null when signed out.
  AulApi? _api() {
    final url = ref.read(controllerProvider).serverUrl;
    if (url == null) return null;
    return AulApi(baseUrl: url, vault: ref.read(vaultProvider));
  }

  /// Registers this device's FCM token.
  ///
  /// When [userInitiated] (the user just flipped the switch) a failure flips the
  /// opt-in back OFF and persists it: they refused the permission prompt, or
  /// there is no Firebase in this build, and a switch left ON would promise
  /// notifications that can never arrive. Mirrors the web, which only stores
  /// `pushEnabled` when the browser really subscribed.
  ///
  /// When NOT [userInitiated] (the launch resync) a failure is left alone — it
  /// is far more likely to be a flat network than a decision, and silently
  /// revoking a preference the user set is the one outcome worth avoiding.
  Future<void> _registerPush({required bool userInitiated}) async {
    final api = _api();
    if (api == null) return;
    final token = await ref.read(pushMessagingProvider).register(api);
    _pushSynced = token != null;
    if (token != null || !userInitiated) return;
    // Permission prompts and network calls take time; the user may have signed
    // out meanwhile. The pref below is still worth persisting, the state is not.
    if (ref.mounted) state = state.copyWith(pushEnabled: false);
    final prefs = await _ensurePrefs();
    await prefs.setEnabled(RetentionFeature.push, false);
  }

  /// Flips a feature's local opt-in and persists it. Turning one ON prepares the
  /// notification channel + permission so the first alert can actually appear.
  Future<void> toggle(RetentionFeature f, bool value) async {
    final prefs = await _ensurePrefs();
    await prefs.setEnabled(f, value);
    state = switch (f) {
      RetentionFeature.arrival => state.copyWith(arrivalEnabled: value),
      RetentionFeature.reengage => state.copyWith(reengageEnabled: value),
      RetentionFeature.push => state.copyWith(pushEnabled: value),
    };
    // Push owns its own permission prompt (the FCM plugin's), and has a server
    // side to tell either way — so it does not take the branch below.
    if (f == RetentionFeature.push) {
      if (value) {
        await _registerPush(userInitiated: true);
      } else {
        _pushSynced = false; // opting back in must register again
        await ref.read(pushMessagingProvider).unregister(_api());
      }
      return;
    }
    if (value) {
      final notifications = ref.read(notificationServiceProvider);
      await notifications.init();
      await notifications.requestPermission();
    }
  }
}
