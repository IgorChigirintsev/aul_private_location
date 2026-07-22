import '../../crypto/aul_crypto.dart';
import '../../crypto/share_codec.dart';
import '../../data/api/api_client.dart';
import '../../domain/location_fix.dart';
import 'share_keys.dart';
import 'share_session.dart';

/// The per-fix live-share feed, as a seam.
///
/// [BackgroundReporter] depends on this rather than on the real thing so its
/// tests keep needing no vault, no libsodium and no network — the reporter's job
/// is the pipeline, and the sealing/deadline logic is tested on its own.
abstract interface class FixShareFeeder {
  Future<void> onFix(LocationFix fix);
}

/// Feeds every live share link from the headless location isolate — the ONE
/// place in the app that does so.
///
/// THE PROBLEM. A share link needs a position roughly every few seconds for as
/// long as it lives; positions arrive on exactly one path, the native service's
/// fix callback, which lands in this isolate. The foreground used to be the
/// feeder, off a method channel nothing ever called, so no link was ever fed a
/// single position. It could not be fixed in place either: the whole point of a
/// share is that it keeps running with the app closed, which is where the
/// foreground is not.
///
/// So the isolate feeds them, and it needs three things per session — the id,
/// K_share, and the deadline. All three come from [ShareKeyStore] (the vault),
/// which the foreground writes when a share is created or revoked. The cache is
/// re-read on EVERY fix rather than once, because unlike the place cache it
/// changes while this isolate is alive: a share created thirty seconds ago must
/// be fed now, not after the next service restart. That read is local — the
/// keystore, no radio — and happens on a path that is already about to do
/// network I/O.
///
/// The server list is refreshed on a TTL on top of that ([kShareRefreshInterval],
/// matching the web's shareReporter), which is what notices a revoke issued from
/// another device. It is best-effort: offline, the cached sessions keep being
/// fed until their deadlines, which is the behaviour worth having.
class BackgroundShares implements FixShareFeeder {
  BackgroundShares({
    required ShareKeyStore store,
    required AulCrypto crypto,
    required AulApi api,
    Duration ttl = kShareRefreshInterval,
    DateTime Function()? clock,
  }) : _store = store,
       _crypto = crypto,
       _api = api,
       _ttl = ttl,
       _now = clock ?? DateTime.now;

  final ShareKeyStore _store;
  final AulCrypto _crypto;
  final AulApi _api;
  final Duration _ttl;
  final DateTime Function() _now;

  /// When a refresh was last ATTEMPTED, successful or not — so an offline device
  /// waits out the TTL rather than retrying on every single fix.
  DateTime? _attemptedAt;

  @override
  Future<void> onFix(LocationFix fix) async {
    final now = _now().toUtc();
    var cache = await _store.load();
    // No link to feed: no refresh, no request, nothing. Sharing costs the phone
    // exactly nothing when nobody is sharing.
    if (cache.sessions.isEmpty) return;

    if (_due(cache.at, now)) {
      _attemptedAt = now;
      if (await _refresh(now)) cache = await _store.load();
    }

    final codec = ShareCodec(_crypto);
    for (final s in cache.sessions) {
      // THE DEADLINE, ENFORCED ON THE DEVICE. The server expires the session as
      // well, but this list is up to a TTL stale, and "the server would have
      // rejected it anyway" is not a reason to send someone's position past the
      // end of the window they agreed to.
      if (!s.isLive(now)) continue;
      try {
        final key = _crypto.circleKeyFromBytes(fromBase64Url(s.keyB64Url));
        try {
          // RAW. Never `forMode`'d, and never gated on the circle's precision:
          // a share is its own opt-in with its own key, and the circle's mode
          // has no say over a link the user made deliberately. The circle's
          // coarsening happens in the reporter, against K_c, and never touches
          // this.
          final sealed = codec.seal(
            ShareFix(
              lat: fix.lat,
              lng: fix.lng,
              accuracy: fix.accuracy,
              // The PLATFORM's fix time, not now(): a settled fix must not be
              // relabelled "just now" on a stranger's map either.
              capturedAt: fix.capturedAt,
            ),
            key,
          );
          await _api.putSharePing(
            s.id,
            nonceB64: sealed.nonceB64,
            ciphertextB64: sealed.ciphertextB64,
            capturedAt: fix.capturedAt,
          );
        } finally {
          key.dispose();
        }
      } catch (_) {
        // Transient, or a corrupt key entry. The next fix retries; a share ping
        // is deliberately NOT queued like a circle ping — a position that is
        // minutes late is worse than useless to someone watching a link, and
        // the next one is seconds away.
        continue;
      }
    }
  }

  /// Whether the server list is due a refresh — backing off on the ATTEMPT as
  /// well as the last success, so a failure waits out the TTL like anything else.
  bool _due(DateTime? at, DateTime now) {
    final last = switch ((at, _attemptedAt)) {
      (null, final b) => b,
      (final a, null) => a,
      (final a?, final b?) => a.isAfter(b) ? a : b,
    };
    return last == null || now.difference(last) >= _ttl;
  }

  /// Reconciles the cache with the server: picks up a revoke from another
  /// device, and drops what has died. Returns whether it succeeded.
  Future<bool> _refresh(DateTime startedAt) async {
    try {
      final sessions = await _api.listShares();
      await _store.sync(sessions, startedAt, at: _now().toUtc());
      return true;
    } catch (_) {
      return false; // offline — the cached sessions keep their own deadlines
    }
  }
}
