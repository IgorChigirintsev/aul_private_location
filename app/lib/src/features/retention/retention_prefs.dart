import 'package:shared_preferences/shared_preferences.dart';

/// The opt-in retention features. Each is CLIENT-SIDE and E2EE-preserving:
/// computed from already-decrypted data or on-device state, so the server never
/// gains new plaintext.
enum RetentionFeature {
  /// Arrival/left notifications from the client-side geofence engine.
  arrival,

  /// Honest, dismissible reminders ("tracking off", "battery low").
  reengage,

  /// Background push (FCM): let the circle's notifications reach this device
  /// while Aul is closed. Separate from [arrival] on purpose, and mirroring the
  /// web's separate `pushEnabled` pref — [arrival] is about being buzzed for
  /// YOUR OWN crossings, this is about handing the server a token it can wake.
  /// Someone may well want one and not the other.
  push,
}

/// A [SharedPreferences]-backed store of the per-feature USER opt-in booleans.
///
/// Anti-stalking invariant: every feature defaults to **false** — nothing is
/// enabled until the user chooses in. A feature only actually activates when
/// this local opt-in is true AND the server's `retention_features_enabled`
/// kill-switch is on (that combination lives in the retention controller).
class RetentionPrefs {
  RetentionPrefs(this._prefs);

  final SharedPreferences _prefs;

  static const _kArrival = 'retention.arrivalEnabled';
  static const _kReengage = 'retention.reengageEnabled';
  static const _kPush = 'retention.pushEnabled';
  static const _kServerEnabled = 'retention.serverEnabled';

  static String _keyFor(RetentionFeature f) => switch (f) {
    RetentionFeature.arrival => _kArrival,
    RetentionFeature.reengage => _kReengage,
    RetentionFeature.push => _kPush,
  };

  /// The user's opt-in for [f]. Defaults to false (opted OUT).
  bool enabled(RetentionFeature f) => _prefs.getBool(_keyFor(f)) ?? false;

  Future<void> setEnabled(RetentionFeature f, bool value) =>
      _prefs.setBool(_keyFor(f), value);

  bool get arrivalEnabled => enabled(RetentionFeature.arrival);
  bool get reengageEnabled => enabled(RetentionFeature.reengage);
  bool get pushEnabled => enabled(RetentionFeature.push);

  // --- the server kill-switch, mirrored for the isolates ---

  /// The operator's `retention_features_enabled` as last seen by the FOREGROUND.
  ///
  /// The switch itself lives on the server and [RetentionController] holds it in
  /// memory — which is no use to the headless location isolate, the one that
  /// actually evaluates crossings. It has no Riverpod and no session; fetching
  /// `/v1/server-info` on the fix path would be a request per fix to answer a
  /// question whose answer changes about never. So the foreground writes what it
  /// last learned here and the isolate reads it.
  ///
  /// Defaults to **false**, preserving the anti-stalking invariant: a device
  /// that has never once heard the server say yes relays nothing and notifies
  /// nobody. The cost is that the switch is one refresh stale — flipping it OFF
  /// server-side stops this device's relays at its next foreground launch, not
  /// instantly. Sharpening that would mean trusting the isolate to fetch it,
  /// which is the request-per-fix we just refused.
  bool get serverEnabled => _prefs.getBool(_kServerEnabled) ?? false;

  Future<void> setServerEnabled(bool value) =>
      _prefs.setBool(_kServerEnabled, value);

  /// Re-reads the backing store. SharedPreferences caches its whole map at
  /// [SharedPreferences.getInstance] time, per isolate — so a long-lived
  /// background service would otherwise answer with whatever the opt-ins were
  /// when it started, and a user who switched arrivals off mid-drive would keep
  /// being buzzed until Android happened to restart it.
  Future<void> reload() => _prefs.reload();
}
