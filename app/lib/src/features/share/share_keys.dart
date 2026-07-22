import '../../data/api/models.dart';
import '../../data/key_vault.dart';
import 'share_session.dart';

/// A live-share session as the DEVICE needs to remember it: the id to PUT to,
/// the key to seal under, and the deadline to stop at.
class CachedShare {
  const CachedShare({
    required this.id,
    required this.keyB64Url,
    required this.expiresAt,
    required this.addedAt,
  });

  final String id;

  /// base64url(K_share) — the exact encoding the link fragment carries.
  final String keyB64Url;

  final DateTime expiresAt;

  /// When THIS device stored the entry. Only used to keep a refresh from pruning
  /// a session created after its own fetch went out — see [ShareKeyStore.sync].
  final DateTime addedAt;

  /// Whether a position may still go out for this session at [now].
  ///
  /// Fails CLOSED, and is the device's own enforcement of the deadline: the
  /// server expires the session too, but the list this came from is up to a
  /// refresh interval stale, and not one position may go out after the end.
  bool isLive(DateTime now) => expiresAt.isAfter(now);

  Map<String, dynamic> toJson() => {
    'id': id,
    'k': keyB64Url,
    'exp': expiresAt.toUtc().millisecondsSinceEpoch,
    'a': addedAt.toUtc().millisecondsSinceEpoch,
  };

  static CachedShare? fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String?;
    final k = j['k'] as String?;
    final exp = (j['exp'] as num?)?.toInt();
    if (id == null || k == null || k.isEmpty || exp == null) return null;
    final added = (j['a'] as num?)?.toInt();
    return CachedShare(
      id: id,
      keyB64Url: k,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(exp, isUtc: true),
      addedAt: DateTime.fromMillisecondsSinceEpoch(added ?? 0, isUtc: true),
    );
  }
}

/// What the cache holds right now, plus when it was last reconciled with the
/// server. [at] drives the isolate's TTL refresh.
typedef ShareCache = ({DateTime? at, List<CachedShare> sessions});

/// K_share (and the deadline) for every live-share session THIS device created.
///
/// The server has never seen these keys and never will: they are what decrypts
/// the shared position, and the whole point of the design is that only the link
/// holds them. They are persisted for two reasons — a restart must keep feeding
/// a session that is still running, and the LOCATION ISOLATE, which is the only
/// thing that sees a fix, has no other way to learn them. Lose this store and
/// the session is simply unfeedable (revoke it).
///
/// Entries are pruned as soon as a session stops being live, so a dead session's
/// key does not linger.
class ShareKeyStore {
  ShareKeyStore(this._vault);

  final KeyVault _vault;

  /// Everything cached, with the last reconcile time. Never throws.
  Future<ShareCache> load() async {
    final raw = await _vault.loadShareSessions();
    if (raw == null) return (at: null, sessions: const <CachedShare>[]);
    try {
      final at = (raw['at'] as num?)?.toInt();
      return (
        at: at == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
        sessions: [
          for (final s
              in (raw['sessions'] as List).cast<Map<String, dynamic>>())
            ?CachedShare.fromJson(s),
        ],
      );
    } catch (_) {
      return (
        at: null,
        sessions: const <CachedShare>[],
      ); // corrupt — better empty than half
    }
  }

  /// sessionId → base64url(K_share), for rendering links.
  Future<Map<String, String>> loadKeys() async => {
    for (final s in (await load()).sessions) s.id: s.keyB64Url,
  };

  Future<void> _persist(ShareCache cache) => _vault.saveShareSessions({
    'at': cache.at?.toUtc().millisecondsSinceEpoch,
    'sessions': [for (final s in cache.sessions) s.toJson()],
  });

  /// Remembers a session created on this device. Called BEFORE the link is
  /// shown: a crash between the two would otherwise leave a live session this
  /// device could no longer feed.
  /// [now] stamps `addedAt`; it defaults to the wall clock but is injectable so
  /// a test can pin it to the same clock the feeder uses. This matters: `sync`
  /// keeps a session whose `addedAt` is after a refresh's start time (it was
  /// created mid-fetch, so a stale empty response must not prune it). If `add`
  /// stamps real time while the feeder runs on a fixed test clock, that guard
  /// compares two different clocks and a revoke silently stops being honoured —
  /// a time-bomb that only shows once wall time passes the test's fixed date.
  Future<void> add(
    String id,
    String keyB64Url,
    DateTime expiresAt, {
    DateTime? now,
  }) async {
    final cache = await load();
    await _persist((
      at: cache.at,
      sessions: [
        for (final s in cache.sessions)
          if (s.id != id) s,
        CachedShare(
          id: id,
          keyB64Url: keyB64Url,
          expiresAt: expiresAt,
          addedAt: (now ?? DateTime.now()).toUtc(),
        ),
      ],
    ));
  }

  Future<void> forget(String id) async {
    final cache = await load();
    if (!cache.sessions.any((s) => s.id == id)) return;
    await _persist((
      at: cache.at,
      sessions: [
        for (final s in cache.sessions)
          if (s.id != id) s,
      ],
    ));
  }

  /// Reconciles the cache with a SUCCESSFUL fetch: refreshes each surviving
  /// session's deadline from the server, and drops everything the server no
  /// longer lists as live. Stamps [at] so the isolate's TTL backs off.
  ///
  /// Call ONLY with the result of a fetch that actually succeeded — pruning on a
  /// failed one would throw away the keys of perfectly live sessions and leave
  /// them unfeedable.
  ///
  /// [startedAt] must be when the fetch was ISSUED. A session created on this
  /// device after that instant cannot be in [sessions] no matter how live it is,
  /// so it is kept rather than pruned; the next reconcile sees it. Without this
  /// a share created while a refresh was in flight would lose its key forever —
  /// and the two run concurrently by design, one per isolate.
  Future<void> sync(
    List<ShareSession> sessions,
    DateTime startedAt, {
    DateTime? at,
  }) async {
    final now = at ?? DateTime.now().toUtc();
    final live = {
      for (final s in sessions)
        if (isShareLive(s, now)) s.id: s,
    };
    final cache = await load();
    await _persist((
      at: now,
      sessions: [
        for (final s in cache.sessions)
          if (live[s.id] case final fresh?)
            CachedShare(
              id: s.id,
              keyB64Url: s.keyB64Url,
              // The SERVER's deadline wins: it is the one that is enforced on
              // the other end, and it is the only one that can have moved.
              expiresAt: fresh.expiresAt,
              addedAt: s.addedAt,
            )
          else if (s.addedAt.isAfter(startedAt))
            s, // created after the fetch went out — not its business to prune
      ],
    ));
  }

  Future<void> clear() => _vault.clearShareSessions();
}
