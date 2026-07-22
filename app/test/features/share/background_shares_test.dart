import 'dart:convert';
import 'dart:typed_data';

import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:aul/src/crypto/share_codec.dart';
import 'package:aul/src/data/api/api_client.dart';
import 'package:aul/src/data/key_vault.dart';
import 'package:aul/src/data/secret_store.dart';
import 'package:aul/src/domain/location_fix.dart';
import 'package:aul/src/features/share/background_shares.dart';
import 'package:aul/src/features/share/share_keys.dart';
import 'package:aul/src/features/share/share_session.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// One request the isolate made, captured off the wire.
class _Call {
  _Call(this.method, this.path, this.body);
  final String method;
  final String path;
  final Object? body;
}

/// Answers the /v1/share contract from memory and records every request, so a
/// test can assert on exactly what left the device.
class _FakeShareAdapter implements HttpClientAdapter {
  _FakeShareAdapter();

  final List<_Call> calls = [];

  /// The sessions the SERVER says are live: id → expiry.
  Map<String, DateTime> sessions = {};
  bool listThrows = false;

  List<_Call> get puts => [
    for (final c in calls)
      if (c.method == 'PUT') c,
  ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(_Call(options.method, options.path, options.data));
    if (options.method == 'GET' && listThrows) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      );
    }
    final json = options.method == 'GET'
        ? {
            'sessions': [
              for (final e in sessions.entries)
                {
                  'id': e.key,
                  'created_at': DateTime.now().toUtc().toIso8601String(),
                  'expires_at': e.value.toUtc().toIso8601String(),
                  'viewer_bound': false,
                  'revoked': false,
                },
            ],
          }
        : {'status': 'ok'};
    return ResponseBody.fromString(
      jsonEncode(json),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AulCrypto crypto;
  setUpAll(() async => crypto = await AulCrypto.load());

  late KeyVault vault;
  late ShareKeyStore store;
  late _FakeShareAdapter adapter;
  late AulApi api;

  /// "Now" for the code under test — fixed, so a deadline is a fact and not a
  /// race with the wall clock.
  final now = DateTime.utc(2026, 7, 16, 12);

  setUp(() {
    vault = KeyVault(InMemorySecretStore());
    store = ShareKeyStore(vault);
    adapter = _FakeShareAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://aul.example'))
      ..httpClientAdapter = adapter;
    api = AulApi(baseUrl: 'https://aul.example', vault: vault, dio: dio);
  });

  BackgroundShares shares({Duration ttl = kShareRefreshInterval}) =>
      BackgroundShares(
        store: store,
        crypto: crypto,
        api: api,
        ttl: ttl,
        clock: () => now,
      );

  /// Seeds a session exactly as the foreground's `create` would, and tells the
  /// fake server about it. Returns base64url(K_share).
  Future<String> seed(
    String id, {
    required Duration expiresIn,
    bool onServer = true,
  }) async {
    final key = crypto.generateCircleKey();
    final b64 = toBase64Url(key.extractBytes());
    key.dispose();
    await store.add(id, b64, now.add(expiresIn), now: now);
    if (onServer) adapter.sessions[id] = now.add(expiresIn);
    return b64;
  }

  /// Marks the cache as JUST reconciled with the server, so no refresh is due.
  ///
  /// The deadline tests below need this, and finding that out was the point of
  /// mutation-testing them: without it the TTL refresh fires (an unstamped cache
  /// is always due), the server's list drops the expired session, and the tests
  /// pass with the per-fix deadline check deleted — proving the refresh, not the
  /// check. Stamping the cache reproduces the case the check exists for: the
  /// list was fetched seconds ago and said "live", and the deadline has passed
  /// since.
  Future<void> stampFresh({DateTime? at}) async {
    final cache = await store.load();
    await vault.saveShareSessions({
      'at': (at ?? now).toUtc().millisecondsSinceEpoch,
      'sessions': [for (final s in cache.sessions) s.toJson()],
    });
  }

  LocationFix fixAt({
    double lat = 43.238949,
    double lng = 76.889709,
    double? acc = 9.5,
    int? batt,
  }) => LocationFix(
    lat: lat,
    lng: lng,
    accuracy: acc,
    battery: batt,
    capturedAt: now.subtract(const Duration(seconds: 3)),
  );

  /// Opens a PUT's body with [keyB64Url] — i.e. does what the link holder's
  /// browser does.
  ShareFix? openPut(_Call put, String keyB64Url) {
    final body = put.body! as Map<String, dynamic>;
    final key = crypto.circleKeyFromBytes(fromBase64Url(keyB64Url));
    try {
      return ShareCodec(
        crypto,
      ).open(body['nonce'] as String, body['ciphertext'] as String, key);
    } finally {
      key.dispose();
    }
  }

  test(
    'a fix while a share is live is sealed and PUT for that session',
    () async {
      final key = await seed('sess-1', expiresIn: const Duration(minutes: 15));

      await shares().onFix(fixAt());

      expect(adapter.puts, hasLength(1));
      expect(adapter.puts.single.path, '/v1/share/sess-1/ping');

      // It opens under THAT session's key, and carries the position.
      final opened = openPut(adapter.puts.single, key);
      expect(opened, isNotNull);
      expect(opened!.lat, closeTo(43.238949, 1e-9));
      expect(opened.lng, closeTo(76.889709, 1e-9));
      expect(opened.accuracy, 9.5);
      // The PLATFORM's fix time, not now(): a settled fix must not be relabelled
      // "just now" on a stranger's map.
      expect(opened.capturedAt, now.subtract(const Duration(seconds: 3)));

      // Any other key gets nothing — the AEAD tag fails closed.
      final other = crypto.generateCircleKey();
      final body = adapter.puts.single.body! as Map<String, dynamic>;
      expect(
        ShareCodec(
          crypto,
        ).open(body['nonce'] as String, body['ciphertext'] as String, other),
        isNull,
      );
      other.dispose();
    },
  );

  test('the position never crosses the wire in cleartext', () async {
    final key = await seed('sess-1', expiresIn: const Duration(minutes: 15));
    await shares().onFix(fixAt());

    for (final call in adapter.calls) {
      final wire = jsonEncode(call.body ?? {});
      // Not the coordinate...
      expect(wire, isNot(contains('43.238')));
      expect(wire, isNot(contains('76.889')));
      // ...and above all not K_share, which only the link fragment may carry.
      expect(wire, isNot(contains(key)));
    }
  });

  test('every live session is fed, each under its own key', () async {
    final a = await seed('sess-a', expiresIn: const Duration(minutes: 5));
    final b = await seed('sess-b', expiresIn: const Duration(minutes: 30));

    await shares().onFix(fixAt());

    expect(adapter.puts.map((p) => p.path), [
      '/v1/share/sess-a/ping',
      '/v1/share/sess-b/ping',
    ]);
    // Crucially, one link's key cannot open the other link's position.
    expect(openPut(adapter.puts[0], a), isNotNull);
    expect(openPut(adapter.puts[0], b), isNull);
    expect(openPut(adapter.puts[1], b), isNotNull);
  });

  test('nothing is sent for a session past its deadline', () async {
    // The device's OWN enforcement. The server would reject this too, but the
    // list it comes from is up to a refresh stale, and not one position may go
    // out after the end of the window the user agreed to. The cache is stamped
    // fresh, so no refresh can intervene: the deadline check is the only thing
    // standing between this fix and a stranger's map.
    await seed('dead', expiresIn: const Duration(seconds: -1));
    await stampFresh();

    await shares().onFix(fixAt());

    expect(adapter.puts, isEmpty);
    expect(adapter.calls, isEmpty, reason: 'and it did not need to ask anyone');
  });

  test('the deadline is enforced per fix, not per list refresh', () async {
    // The exact hole this closes. The list was fetched while the session was
    // live and still says so; eleven minutes have passed since. The clock wins,
    // with no fetch to save it — this is what the web's shareReporter does by
    // re-checking every tick, and what the app must do between refreshes.
    await seed('expiring', expiresIn: const Duration(minutes: 10));
    await stampFresh();

    final feeder = BackgroundShares(
      store: store,
      crypto: crypto,
      api: api,
      // Long enough that no refresh is due: the ONLY thing that can stop the
      // feed is the deadline check on the cached entry.
      ttl: const Duration(days: 1),
      clock: () => now.add(const Duration(minutes: 11)),
    );
    await feeder.onFix(fixAt());

    expect(adapter.puts, isEmpty);
    expect(adapter.calls, isEmpty);
  });

  test(
    'a live session is fed with no circle, and while the circle is paused',
    () async {
      // There is no circle here at all: no reporting target, no K_c, nothing. A
      // share is its own opt-in with its own key and must not depend on any of it.
      await seed('sess-1', expiresIn: const Duration(minutes: 15));
      await vault.saveReportingTargets(const []);

      await shares().onFix(fixAt());

      expect(adapter.puts, hasLength(1));
    },
  );

  test('a revoke from another device stops the feed within the TTL', () async {
    await seed('sess-1', expiresIn: const Duration(minutes: 15));
    var clock = now;
    final feeder = BackgroundShares(
      store: store,
      crypto: crypto,
      api: api,
      clock: () => clock,
    );
    await feeder.onFix(fixAt());
    expect(adapter.puts, hasLength(1));

    // Another device revokes it: the server simply stops listing it. This
    // device is never told directly — the list is the only channel there is,
    // which is why the isolate refreshes it itself rather than trusting the UI
    // to still be running.
    adapter.sessions.remove('sess-1');
    clock = now.add(kShareRefreshInterval);
    await feeder.onFix(fixAt());

    expect(adapter.puts, hasLength(1), reason: 'no second ping went out');
    expect(await store.loadKeys(), isEmpty, reason: 'and the key is dropped');
  });

  test(
    'offline, the cached sessions keep being fed until their deadlines',
    () async {
      await seed('sess-1', expiresIn: const Duration(minutes: 15));
      adapter.listThrows = true;

      final feeder = shares();
      await feeder.onFix(fixAt());

      expect(adapter.puts, hasLength(1));
      expect(
        await store.loadKeys(),
        contains('sess-1'),
        reason: 'a failed fetch must never prune a live session',
      );
    },
  );

  test('a failed refresh backs off rather than retrying every fix', () async {
    await seed('sess-1', expiresIn: const Duration(minutes: 15));
    adapter.listThrows = true;

    final feeder = shares();
    await feeder.onFix(fixAt());
    await feeder.onFix(fixAt());
    await feeder.onFix(fixAt());

    // The clock is frozen inside the TTL, so exactly one list attempt is
    // allowed — otherwise an offline phone burns the radio once a fix, forever.
    expect(adapter.calls.where((c) => c.method == 'GET'), hasLength(1));
    expect(
      adapter.puts,
      hasLength(3),
      reason: 'the feed carries on regardless',
    );
  });

  test(
    'no live share means no work at all: no request, not even a list',
    () async {
      await shares().onFix(fixAt());
      expect(adapter.calls, isEmpty);
    },
  );

  test(
    'a session whose key is corrupt does not cost the others theirs',
    () async {
      await store.add(
        'broken',
        'not-a-key!!',
        now.add(const Duration(minutes: 5)),
      );
      adapter.sessions['broken'] = now.add(const Duration(minutes: 5));
      final key = await seed('good', expiresIn: const Duration(minutes: 5));

      await shares().onFix(fixAt());

      expect(adapter.puts, hasLength(1));
      expect(adapter.puts.single.path, '/v1/share/good/ping');
      expect(openPut(adapter.puts.single, key), isNotNull);
    },
  );
}
