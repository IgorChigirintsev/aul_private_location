import 'dart:convert';
import 'dart:typed_data';

import 'secret_store.dart';

/// A stored session's tokens.
class SessionTokens {
  const SessionTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime accessExpiresAt;

  bool get accessExpired => DateTime.now().toUtc().isAfter(
    accessExpiresAt.subtract(const Duration(seconds: 30)),
  );

  Map<String, dynamic> toJson() => {
    'a': accessToken,
    'r': refreshToken,
    'e': accessExpiresAt.toUtc().toIso8601String(),
  };

  factory SessionTokens.fromJson(Map<String, dynamic> j) => SessionTokens(
    accessToken: j['a'] as String,
    refreshToken: j['r'] as String,
    accessExpiresAt: DateTime.parse(j['e'] as String),
  );
}

/// Typed accessors over a [SecretStore] for identity keys, per-circle keys,
/// session tokens, and the device id. Binary values are base64-encoded. The
/// private identity key and circle keys NEVER leave the device.
class KeyVault {
  KeyVault(this._store);

  final SecretStore _store;

  static const _kIdentityPub = 'identity_pub';
  static const _kIdentitySec = 'identity_sec';
  static const _kSession = 'session';
  static const _kDeviceId = 'device_id';
  static const _kUserId = 'user_id';
  static const _kEmail = 'email';
  static const _kServerUrl = 'server_url';
  static const _kTargets = 'reporting_targets';
  static const _kGeofenceInside = 'geofence_inside';
  static const _kGeofencePlaces = 'geofence_places';
  static const _kShareSessions = 'share_sessions';
  static const _circlePrefix = 'circle_key_';

  // --- identity keypair ---

  Future<void> saveIdentity(Uint8List publicKey, Uint8List secretKey) async {
    await _store.put(_kIdentityPub, base64.encode(publicKey));
    await _store.put(_kIdentitySec, base64.encode(secretKey));
  }

  Future<({Uint8List publicKey, Uint8List secretKey})?> loadIdentity() async {
    final pub = await _store.get(_kIdentityPub);
    final sec = await _store.get(_kIdentitySec);
    if (pub == null || sec == null) return null;
    return (publicKey: base64.decode(pub), secretKey: base64.decode(sec));
  }

  Future<bool> hasIdentity() async => (await _store.get(_kIdentityPub)) != null;

  // --- per-circle key ring K_c (all epochs, oldest → newest) ---
  //
  // A circle's keys are stored as ONE entry: a JSON list of base64 keys ordered
  // oldest → newest. The last element is the current key used for SEALING; the
  // whole ring is used for DECRYPTING so data sealed under a pre-rotation key
  // still opens after a rotation (parity with the web keyring). A legacy entry
  // written by an older build — a single bare-base64 key — is read transparently
  // as a 1-element ring (base64 never begins with '[', so the two formats are
  // unambiguous) and is upgraded to the JSON form on the next write.

  /// Reads a circle's key ring (oldest → newest); empty when none is stored.
  /// Tolerates the legacy single-key format.
  Future<List<Uint8List>> loadCircleKeys(String circleId) async {
    final v = await _store.get('$_circlePrefix$circleId');
    if (v == null) return const [];
    if (v.startsWith('[')) {
      final list = (jsonDecode(v) as List).cast<String>();
      return [for (final b in list) base64.decode(b)];
    }
    return [base64.decode(v)]; // legacy single-key entry → 1-element ring
  }

  /// The NEWEST key for [circleId] (the one to SEAL with), or null when none.
  Future<Uint8List?> loadCircleKey(String circleId) async {
    final ring = await loadCircleKeys(circleId);
    return ring.isEmpty ? null : ring.last;
  }

  /// EVERY circle key this device holds, across every circle and every epoch.
  ///
  /// For the one caller that cannot know which circle it needs: the FCM push
  /// handler. A data-only push carries just the sealed blob — no circle id, no
  /// key epoch, because telling the server which circle an event belongs to is
  /// exactly the metadata Aul refuses to leak. So the receiver tries the whole
  /// bunch of keys and lets Poly1305 pick the lock (mirrors the web's
  /// `keystore.loadAllCircleKeys`). Order within a circle stays oldest → newest;
  /// across circles it is whatever the store enumerates, which is fine — the
  /// AEAD tag is what decides, not the order.
  ///
  /// A corrupt entry is skipped rather than thrown: one unreadable circle must
  /// not cost the user every other circle's notifications.
  Future<List<Uint8List>> loadAllCircleKeys() async {
    final all = await _store.readAll();
    final out = <Uint8List>[];
    for (final e in all.entries) {
      if (!e.key.startsWith(_circlePrefix)) continue;
      try {
        final v = e.value;
        if (v.startsWith('[')) {
          for (final b in (jsonDecode(v) as List).cast<String>()) {
            out.add(base64.decode(b));
          }
        } else {
          out.add(base64.decode(v)); // legacy single-key entry
        }
      } catch (_) {
        continue; // unreadable entry — skip it, keep the other circles working
      }
    }
    return out;
  }

  /// Appends [key] to the ring as the new newest key, unless the ring already
  /// contains it (dedup by bytes — safe to call repeatedly for the same key).
  Future<void> addCircleKey(String circleId, Uint8List key) async {
    final ring = List<Uint8List>.of(await loadCircleKeys(circleId));
    if (ring.any((k) => _bytesEqual(k, key))) return;
    ring.add(key);
    await _store.put(
      '$_circlePrefix$circleId',
      jsonEncode([for (final k in ring) base64.encode(k)]),
    );
  }

  /// Adds [key] to the circle's ring (set when empty, append otherwise). Retained
  /// as the historical name; identical to [addCircleKey].
  Future<void> saveCircleKey(String circleId, Uint8List key) =>
      addCircleKey(circleId, key);

  /// Clears a circle's entire key ring (leave / delete).
  Future<void> removeCircleKey(String circleId) =>
      _store.remove('$_circlePrefix$circleId');

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // --- session ---

  Future<void> saveSession(SessionTokens t) =>
      _store.put(_kSession, jsonEncode(t.toJson()));

  Future<SessionTokens?> loadSession() async {
    final v = await _store.get(_kSession);
    if (v == null) return null;
    return SessionTokens.fromJson(jsonDecode(v) as Map<String, dynamic>);
  }

  Future<void> clearSession() => _store.remove(_kSession);

  // --- device id ---

  Future<void> saveDeviceId(String id) => _store.put(_kDeviceId, id);
  Future<String?> loadDeviceId() => _store.get(_kDeviceId);

  // --- own identity (who "you" are in a members list) ---
  //
  // Persisted at sign-in so a RESTORED session still knows which member row is
  // the user's own. That matters beyond the "(you)" marker: muting yourself is
  // rejected by the server (400), so the UI must be able to tell itself apart
  // before it offers a mute toggle.

  Future<void> saveUserId(String id) => _store.put(_kUserId, id);
  Future<String?> loadUserId() => _store.get(_kUserId);

  Future<void> saveEmail(String email) => _store.put(_kEmail, email);
  Future<String?> loadEmail() => _store.get(_kEmail);

  // --- server URL + reporting targets (read by the background isolate) ---

  Future<void> saveServerUrl(String url) => _store.put(_kServerUrl, url);
  Future<String?> loadServerUrl() => _store.get(_kServerUrl);

  /// Persists the circles this device reports to, each with its precision, so
  /// the headless service isolate knows what to seal for.
  Future<void> saveReportingTargets(List<Map<String, dynamic>> targets) =>
      _store.put(_kTargets, jsonEncode(targets));

  Future<List<Map<String, dynamic>>> loadReportingTargets() async {
    final v = await _store.get(_kTargets);
    if (v == null) return const [];
    return (jsonDecode(v) as List).cast<Map<String, dynamic>>();
  }

  // --- geofence state (written ONLY by the background isolate) ---
  //
  // Both of these live here rather than in the drift queue database for the same
  // two reasons: they are location-derived data, which this store keeps
  // encrypted at rest exactly as `queued_pings` keeps ciphertext-only; and
  // [wipe] then clears them on sign-out for free, so a second account cannot
  // inherit the first one's fences. See tracking/geofence_state.dart.

  /// The place ids this device was last evaluated to be INSIDE. Survives the
  /// service restarts Android performs at will — without it, every restart
  /// re-announces an arrival at a place the user never left.
  Future<Set<String>> loadGeofenceInside() async {
    final v = await _store.get(_kGeofenceInside);
    if (v == null) return <String>{};
    try {
      return (jsonDecode(v) as List).cast<String>().toSet();
    } catch (_) {
      return <
        String
      >{}; // corrupt — better to re-seed than to crash the isolate
    }
  }

  Future<void> saveGeofenceInside(Set<String> placeIds) =>
      _store.put(_kGeofenceInside, jsonEncode(placeIds.toList()));

  /// The cached places the background isolate evaluates crossings against,
  /// STILL SEALED — the JSON holds each place's `ciphertextB64` exactly as the
  /// server served it, plus the circle it belongs to. The isolate opens them
  /// with K_c from this same vault; nothing here is a coordinate in cleartext.
  Future<Map<String, dynamic>?> loadGeofencePlaces() async {
    final v = await _store.get(_kGeofencePlaces);
    if (v == null) return null;
    try {
      return jsonDecode(v) as Map<String, dynamic>;
    } catch (_) {
      return null; // corrupt — the isolate refetches
    }
  }

  Future<void> saveGeofencePlaces(Map<String, dynamic> cache) =>
      _store.put(_kGeofencePlaces, jsonEncode(cache));

  // --- live-share sessions (written by the UI, read by BOTH isolates) ---
  //
  // K_share lives HERE, next to K_c, and not in SharedPreferences where an
  // earlier build kept it. It is key material of exactly the same kind: it opens
  // this device's live position. This store is encrypted at rest, and [wipe]
  // clears it on sign-out for free, so a second account cannot inherit the
  // first's feedable sessions. Same reasoning as the geofence cache above.
  //
  // It is a CACHE the foreground seeds and the location isolate re-reads, for
  // the same reason the place cache is one: the isolate is the only thing that
  // sees a fix, it has no Riverpod, and K_share cannot be re-fetched from
  // anywhere — the server has never seen it and never will.

  /// The live-share sessions this device can feed: `{at, sessions:[{id,k,exp,a}]}`.
  Future<Map<String, dynamic>?> loadShareSessions() async {
    final v = await _store.get(_kShareSessions);
    if (v == null) return null;
    try {
      return jsonDecode(v) as Map<String, dynamic>;
    } catch (_) {
      return null; // corrupt — better unfeedable than half-parsed
    }
  }

  Future<void> saveShareSessions(Map<String, dynamic> cache) =>
      _store.put(_kShareSessions, jsonEncode(cache));

  Future<void> clearShareSessions() => _store.remove(_kShareSessions);

  /// Wipes everything (sign-out / account removal).
  Future<void> wipe() => _store.clear();
}
