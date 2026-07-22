import 'dart:convert';
import 'dart:typed_data';

import 'package:aul/src/controller.dart';
import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:aul/src/data/api/api_client.dart';
import 'package:aul/src/data/key_vault.dart';
import 'package:aul/src/data/secret_store.dart';
import 'package:aul/src/features/share/share_controller.dart';
import 'package:aul/src/features/share/share_keys.dart';
import 'package:aul/src/features/share/share_session.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// One request the app made, captured off the wire.
class _Call {
  _Call(this.method, this.path, this.body);
  final String method;
  final String path;
  final Object? body;
}

/// A Dio adapter that answers the /v1/share contract from memory and records
/// every request, so a test can assert on exactly what left the device.
class _FakeShareAdapter implements HttpClientAdapter {
  _FakeShareAdapter(this.expiresAt);

  DateTime expiresAt;
  final List<_Call> calls = [];
  bool viewerBound = false;
  List<String> sessions = [];
  int created = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(_Call(options.method, options.path, options.data));
    Map<String, dynamic> json;
    if (options.method == 'POST' && options.path == '/v1/share') {
      final id = 'sess-${++created}';
      sessions.add(id);
      json = {'id': id, 'expires_at': expiresAt.toIso8601String()};
    } else if (options.method == 'GET' && options.path == '/v1/share') {
      json = {
        'sessions': [
          for (final id in sessions)
            {
              'id': id,
              'created_at': DateTime.now().toUtc().toIso8601String(),
              'expires_at': expiresAt.toIso8601String(),
              'viewer_bound': viewerBound,
              'revoked': false,
            },
        ],
      };
    } else if (options.method == 'DELETE') {
      sessions.remove(options.path.split('/').last);
      json = {'status': 'revoked'};
    } else {
      json = {'status': 'ok'}; // PUT .../ping
    }
    return ResponseBody.fromString(
      jsonEncode(json),
      options.method == 'POST' ? 201 : 200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// An [AppController] that is signed in against the fake transport and records
/// the location-need flips, without touching a platform channel.
class _FakeAppController extends AppController {
  _FakeAppController(this._api, this._crypto);

  final AulApi _api;
  final AulCrypto _crypto;
  final List<bool> needs = [];

  @override
  AppSession build() => const AppSession(
    phase: AuthPhase.signedIn,
    serverUrl: 'https://aul.example',
  );

  @override
  AulApi? get api => _api;

  @override
  Future<AulCrypto> get crypto async => _crypto;

  @override
  Future<void> setShareNeedsLocation(bool needed) async => needs.add(needed);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AulCrypto crypto;
  setUpAll(() async => crypto = await AulCrypto.load());

  late _FakeShareAdapter adapter;
  late _FakeAppController app;
  late ProviderContainer container;
  late KeyVault vault;

  /// Boots the controller over the fake transport, with [cached] already in the
  /// vault — i.e. what a previous run (or another isolate) left behind.
  Future<void> boot({List<CachedShare> cached = const []}) async {
    vault = KeyVault(InMemorySecretStore());
    if (cached.isNotEmpty) {
      await vault.saveShareSessions({
        'at': DateTime.now().toUtc().millisecondsSinceEpoch,
        'sessions': [for (final s in cached) s.toJson()],
      });
    }
    adapter = _FakeShareAdapter(
      DateTime.now().toUtc().add(const Duration(minutes: 15)),
    );
    final dio = Dio(BaseOptions(baseUrl: 'https://aul.example'))
      ..httpClientAdapter = adapter;
    final api = AulApi(baseUrl: 'https://aul.example', vault: vault, dio: dio);
    app = _FakeAppController(api, crypto);
    container = ProviderContainer(
      overrides: [
        controllerProvider.overrideWith(() => app),
        vaultProvider.overrideWithValue(vault),
      ],
    );
    addTearDown(container.dispose);
  }

  ShareController ctrl() => container.read(shareControllerProvider.notifier);
  ShareState state() => container.read(shareControllerProvider);

  /// What the location isolate would read: the sessions it is able to feed.
  Future<List<CachedShare>> cachedSessions() async =>
      (await ShareKeyStore(vault).load()).sessions;

  test('create → a live session, a stored K_share, and a usable link', () async {
    await boot();
    final id = await ctrl().create(1800);

    expect(id, 'sess-1');
    expect(state().hasLive, isTrue);

    // The chosen TTL is what was asked for, and the request carries no key.
    final post = adapter.calls.firstWhere((c) => c.method == 'POST');
    expect(post.path, '/v1/share');
    expect(post.body, {'ttl_seconds': 1800});

    // The link is <origin>/s/<id>#<base64url(K_share)> and its fragment decodes
    // to a 32-byte key.
    final key = state().keys[id!]!;
    final link = shareLink('https://aul.example', id, key);
    expect(link, 'https://aul.example/s/sess-1#$key');
    expect(fromBase64Url(Uri.parse(link).fragment).length, 32);

    // The share went live, so the device's location stream was asked for.
    expect(app.needs, contains(true));
  });

  test('K_share is NOT the circle key and never leaves the device', () async {
    await boot();
    final id = (await ctrl().create(900))!;
    final key = state().keys[id]!;

    await ctrl().refresh();
    await pumpEventQueue();

    // Nothing the app sent anywhere contains the key material.
    for (final call in adapter.calls) {
      expect(jsonEncode(call.body ?? {}), isNot(contains(key)));
    }
  });

  test(
    'create hands the isolate everything it needs to feed the session',
    () async {
      // The whole contract between the two halves. The foreground never sees a
      // fix, so if this write is wrong the link is fed nothing at all — which is
      // precisely the bug this replaced.
      await boot();
      final id = (await ctrl().create(900))!;

      final cached = await cachedSessions();
      expect(cached, hasLength(1));
      expect(cached.single.id, id);
      expect(cached.single.keyB64Url, state().keys[id]);
      expect(fromBase64Url(cached.single.keyB64Url).length, 32);
      // The DEADLINE travels with it: the isolate enforces it per fix, and a
      // session with no deadline it could check would feed a stranger forever.
      // To the millisecond — that is the cache's resolution, and the sub-ms
      // remainder of a deadline is not a thing anyone can act on.
      expect(
        cached.single.expiresAt.millisecondsSinceEpoch,
        adapter.expiresAt.millisecondsSinceEpoch,
      );
    },
  );

  test('an expired session drops out and releases the stream, even before the '
      'list refreshes', () async {
    await boot();
    await ctrl().create(900);
    // The deadline passes locally; the server list still lists it as live.
    adapter.expiresAt = DateTime.now().toUtc().subtract(
      const Duration(seconds: 1),
    );
    await ctrl().refresh();

    expect(state().hasLive, isFalse);
    // The stream is released once nothing needs it...
    expect(app.needs.last, isFalse);
    // ...and the isolate is told to stop feeding it, by the only means there
    // is: the key is gone.
    expect(await cachedSessions(), isEmpty);
  });

  test(
    'revoke kills the session, forgets its key, and frees the stream',
    () async {
      await boot();
      final id = (await ctrl().create(900))!;
      await ctrl().revoke(id);

      expect(
        adapter.calls.any(
          (c) => c.method == 'DELETE' && c.path == '/v1/share/$id',
        ),
        isTrue,
      );
      expect(state().keys.containsKey(id), isFalse);
      expect(state().hasLive, isFalse);
      expect(app.needs.last, isFalse);

      // The key is gone from the store the isolate reads, not just from memory —
      // otherwise the isolate would go on feeding a revoked link.
      expect(await cachedSessions(), isEmpty);
    },
  );

  test('a restart keeps feeding a session that is still running', () async {
    // A key persisted by a previous run, for a session the server still lists.
    final key = toBase64Url(Uint8List.fromList(List.filled(32, 3)));
    await boot(
      cached: [
        CachedShare(
          id: 'sess-1',
          keyB64Url: key,
          expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
          addedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 10)),
        ),
      ],
    );
    adapter.sessions = ['sess-1'];

    await ctrl().refresh();
    expect(state().hasLive, isTrue);
    expect(state().keys['sess-1'], key);
    expect(app.needs, contains(true));
    // The key survived the reconcile, so the isolate can still feed it.
    expect((await cachedSessions()).single.keyB64Url, key);
  });

  test(
    'a successful fetch prunes the keys of sessions that are gone',
    () async {
      final stale = toBase64Url(Uint8List.fromList(List.filled(32, 9)));
      await boot(
        cached: [
          CachedShare(
            id: 'dead-session',
            keyB64Url: stale,
            expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
            addedAt: DateTime.now().toUtc().subtract(
              const Duration(minutes: 10),
            ),
          ),
        ],
      );
      adapter.sessions = []; // the server no longer lists it

      await ctrl().refresh();

      expect(state().keys, isEmpty);
      expect(await cachedSessions(), isEmpty);
    },
  );

  test('viewer_bound from the server is surfaced as-is', () async {
    await boot();
    await ctrl().create(900);
    expect(state().live().single.viewerBound, isFalse);

    adapter.viewerBound = true;
    await ctrl().refresh();
    expect(state().live().single.viewerBound, isTrue);
  });
}
