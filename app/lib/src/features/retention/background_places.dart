import 'package:sodium/sodium.dart';

import '../../crypto/aul_crypto.dart';
import '../../crypto/place_codec.dart';
import '../../data/api/api_client.dart';
import '../../data/key_vault.dart';
import '../../domain/place.dart';

/// The fences to evaluate crossings against, however they are obtained.
///
/// A seam, so the gate logic in [BackgroundArrivalEvaluator] can be tested
/// without a vault, libsodium or a network — the caching and decryption below
/// are a separate concern with separate tests.
abstract interface class PlaceSource {
  /// Makes [places] current, if it can. Called on every fix, so it must be cheap
  /// when there is nothing to do, and must NOT throw when offline.
  Future<void> ensureLoaded(DateTime now);

  /// The places to evaluate against.
  List<Place> get places;
}

/// The circle's places, as seen by the headless location isolate.
///
/// THE PROBLEM. Crossings need places; places are E2EE blobs on the server. The
/// isolate can decrypt them — it holds K_c through the same vault the FCM
/// handler uses — but it has to get them from somewhere, and there were only two
/// honest options:
///
///  * **Fetch on every wake.** Always current, and unaffordable: a fix arrives
///    about once a minute, so this is ~1400 authenticated round-trips a day, on
///    the phone's radio, to re-learn a list that changes maybe monthly. Worse,
///    it makes the feature require the network — a phone in a lift or out of
///    coverage would stop noticing arrivals, when the whole reason the queue
///    exists is that Aul keeps working offline.
///  * **Read a cache the foreground writes.** Free and offline-proof, and stale:
///    add a place on the web, never open the app, and the fence does not exist.
///
/// SO: cache, plus a **TTL refresh the isolate does itself** (default 15
/// minutes). That answers "what if a place was added while backgrounded?" — it
/// starts working within a quarter of an hour, with no app launch — at a cost of
/// four requests an hour rather than sixty. The refresh is best-effort and never
/// gates evaluation: offline, the cached fences keep firing, which is the
/// behaviour worth having. It is also cheap in context — [BackgroundReporter]
/// already flushes the queue over the network on the very same fix path.
///
/// WHAT IS CACHED IS STILL SEALED. The vault stores each place's `ciphertextB64`
/// exactly as the server served it, and this class opens it in memory with K_c
/// per fix batch. So the cache leaks nothing the server does not already hold —
/// no coordinate is ever written to the device in cleartext. The one exception
/// is [whoIn]'s display name, which is decrypted profile text; it lives in the
/// keystore, encrypted at rest, for the same reason the circle keys do.
class BackgroundPlaces implements PlaceSource {
  BackgroundPlaces({
    required KeyVault vault,
    required AulCrypto crypto,
    AulApi? api,
    Duration ttl = const Duration(minutes: 15),
  }) : _vault = vault,
       _crypto = crypto,
       _api = api,
       _ttl = ttl;

  final KeyVault _vault;
  final AulCrypto _crypto;
  final AulApi? _api;
  final Duration _ttl;

  /// The sealed cache rows: circleId → (placeId, version, ciphertext).
  List<_SealedPlace> _sealed = const [];

  /// circleId → this member's name there, resolved by the foreground (which is
  /// the only one that fetches member profiles). Never refreshed here: a
  /// nickname change while backgrounded is a cosmetic staleness, and chasing it
  /// would cost a members fetch per circle to relabel a notification.
  Map<String, String> _who = const {};

  /// The account email, the last-resort label when no nickname is cached.
  String? _email;

  DateTime? _at;

  /// When a refresh was last ATTEMPTED, successful or not. See [ensureLoaded].
  DateTime? _attemptedAt;

  /// Whether the keystore has been consulted this isolate. Separate from [_at]
  /// because "there was no cache" is a real answer worth remembering — without
  /// it, a device that has never synced would re-read secure storage on every
  /// single fix to be told nothing, forever.
  bool _readCacheOnce = false;

  /// The decrypted places, opened fresh from [_sealed] on each [places] call's
  /// backing refresh. Cached in memory only, for the life of the isolate.
  List<Place> _places = const [];
  Map<String, String> _circleOf = const {};

  /// The places to evaluate crossings against. Empty until [ensureLoaded].
  @override
  List<Place> get places => _places;

  /// Which circle owns [placeId] — the only circle a crossing may be told about.
  String? circleOf(String placeId) => _circleOf[placeId];

  /// This member's display name in [circleId]: the cached nickname, else the
  /// account email, else empty (the relay still names the place and the time).
  String whoIn(String circleId) => _who[circleId] ?? _email ?? '';

  /// Loads the cache, then refreshes it from the server when it is older than
  /// the TTL. Safe to call on every fix: the load happens once, and the refresh
  /// only when it has actually expired.
  @override
  Future<void> ensureLoaded(DateTime now) async {
    if (!_readCacheOnce) {
      _readCacheOnce = true;
      await _readCache();
    }
    // Backs off on the ATTEMPT, not just on success — and on whichever of the
    // two is LATER. Both halves matter: a device that has never synced and is
    // offline has `_at == null` forever, while one whose cache has merely gone
    // stale keeps an `_at` in the past. Either way, gating on success alone
    // would retry on every single fix, burning the radio once a minute to go on
    // failing. A failure waits out the TTL like anything else.
    final last = _latest(_at, _attemptedAt);
    if (last == null || now.difference(last) >= _ttl) {
      _attemptedAt = now;
      await _refresh(now);
    }
  }

  /// The later of two instants, either of which may be absent.
  static DateTime? _latest(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  Future<void> _readCache() async {
    _email = await _vault.loadEmail();
    final raw = await _vault.loadGeofencePlaces();
    if (raw == null) {
      // No cache at all. Leave _at null so ensureLoaded refreshes immediately —
      // a first run must not sit blind for a TTL.
      return;
    }
    try {
      _who = (raw['who'] as Map).cast<String, String>();
      _sealed = [
        for (final p in (raw['places'] as List).cast<Map<String, dynamic>>())
          _SealedPlace(
            circleId: p['c'] as String,
            id: p['id'] as String,
            version: (p['v'] as num).toInt(),
            ciphertextB64: p['ct'] as String,
          ),
      ];
      _at = DateTime.fromMillisecondsSinceEpoch(
        (raw['at'] as num).toInt(),
        isUtc: true,
      );
      await _open();
    } catch (_) {
      _sealed = const [];
      _at = null; // malformed — treat as no cache and refetch
    }
  }

  /// Refetches every reporting circle's places and rewrites the cache. Best
  /// effort throughout: a circle that fails keeps whatever was cached for it,
  /// and a total failure leaves [_places] exactly as it was.
  Future<void> _refresh(DateTime now) async {
    final api = _api;
    if (api == null) return;
    final targets = await _vault.loadReportingTargets();
    if (targets.isEmpty) return;

    final fetched = <_SealedPlace>[];
    var anyOk = false;
    for (final t in targets) {
      final circleId = t['id'] as String?;
      if (circleId == null) continue;
      try {
        for (final rp in await api.listPlaces(circleId)) {
          fetched.add(
            _SealedPlace(
              circleId: circleId,
              id: rp.id,
              version: rp.version,
              ciphertextB64: rp.ciphertextB64,
            ),
          );
        }
        anyOk = true;
      } catch (_) {
        // Offline / transient. Keep this circle's cached fences below.
        for (final s in _sealed) {
          if (s.circleId == circleId) fetched.add(s);
        }
      }
    }
    if (!anyOk) return; // nothing was reachable — don't stamp the cache fresh

    _sealed = fetched;
    _at = now;
    await _open();
    await _vault.saveGeofencePlaces({
      'at': now.toUtc().millisecondsSinceEpoch,
      'who': _who,
      'places': [
        for (final s in _sealed)
          {'c': s.circleId, 'id': s.id, 'v': s.version, 'ct': s.ciphertextB64},
      ],
    });
  }

  /// Opens the sealed rows with each circle's key ring. A place no key opens
  /// (rotated away, or a circle this device was removed from) is simply skipped:
  /// a fence we cannot read is a fence we cannot honestly evaluate.
  Future<void> _open() async {
    final byCircle = <String, List<_SealedPlace>>{};
    for (final s in _sealed) {
      (byCircle[s.circleId] ??= []).add(s);
    }
    final codec = PlaceCodec(_crypto);
    final out = <Place>[];
    final owners = <String, String>{};
    for (final entry in byCircle.entries) {
      final keyring = <SecureKey>[];
      try {
        for (final raw in await _vault.loadCircleKeys(entry.key)) {
          try {
            keyring.add(_crypto.circleKeyFromBytes(raw));
          } catch (_) {
            continue; // not a well-formed K_c
          }
        }
        if (keyring.isEmpty) continue;
        for (final s in entry.value) {
          final p = codec.open(
            id: s.id,
            version: s.version,
            ciphertextB64: s.ciphertextB64,
            keyring: keyring,
          );
          if (p == null) continue;
          out.add(p);
          owners[p.id] = entry.key;
        }
      } finally {
        for (final k in keyring) {
          k.dispose();
        }
      }
    }
    _places = out;
    _circleOf = owners;
  }
}

/// A cached place as the server served it — opaque until K_c opens it.
class _SealedPlace {
  const _SealedPlace({
    required this.circleId,
    required this.id,
    required this.version,
    required this.ciphertextB64,
  });

  final String circleId;
  final String id;
  final int version;
  final String ciphertextB64;
}
