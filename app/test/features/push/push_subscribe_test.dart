import 'dart:typed_data';

import 'package:aul/src/data/api/api_client.dart';
import 'package:aul/src/data/api/models.dart';
import 'package:aul/src/data/key_vault.dart';
import 'package:aul/src/data/secret_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// One captured request.
class _Request {
  _Request(this.method, this.path, this.body);
  final String method;
  final String path;
  final Object? body;
}

/// Captures what the client actually put on the WIRE, so the push contract can
/// be asserted against the shape the server agent is shipping rather than
/// against our own helpers.
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter({this.status = 200, this.body = '{}'});

  final int status;
  final String body;
  final List<_Request> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(_Request(options.method, options.path, options.data));
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

AulApi _api(_CapturingAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
  dio.httpClientAdapter = adapter;
  return AulApi(
    baseUrl: 'https://example.test',
    vault: KeyVault(InMemorySecretStore()),
    dio: dio,
  );
}

void main() {
  group('POST /v1/push/subscribe (the FCM registration contract)', () {
    test('registers the token with kind=fcm at the agreed path', () async {
      final adapter = _CapturingAdapter();
      await _api(adapter).pushSubscribeFcm('fcm-token-abc123');

      expect(adapter.requests, hasLength(1));
      final req = adapter.requests.single;
      expect(req.method, 'POST');
      expect(req.path, '/v1/push/subscribe');
      // The body is fixed by the contract: {"kind":"fcm","token":"<token>"}.
      // The web's {endpoint,p256dh,auth} shape stays for browsers.
      expect(req.body, {'kind': 'fcm', 'token': 'fcm-token-abc123'});
    });

    test('sends no key material — only the routing token', () async {
      final adapter = _CapturingAdapter();
      await _api(adapter).pushSubscribeFcm('fcm-token-abc123');

      // What the server may learn here is that this account has a device it can
      // wake. K_c is not part of that bargain, and never travels.
      final body = adapter.requests.single.body! as Map<String, dynamic>;
      expect(body.keys, unorderedEquals(['kind', 'token']));
    });

    test('a rejected registration surfaces as an exception', () async {
      // The caller flips the opt-in back off on failure, so it must be told.
      final adapter = _CapturingAdapter(
        status: 401,
        body: '{"error":{"code":"unauthorized","message":"nope"}}',
      );
      await expectLater(
        _api(adapter).pushSubscribeFcm('t'),
        throwsA(isA<AulApiException>()),
      );
    });
  });

  group('DELETE /v1/push/subscribe', () {
    test('unregisters by endpoint (the token, for FCM)', () async {
      final adapter = _CapturingAdapter();
      await _api(adapter).pushUnsubscribe('fcm-token-abc123');

      final req = adapter.requests.single;
      expect(req.method, 'DELETE');
      expect(req.path, '/v1/push/subscribe');
      expect(req.body, {'endpoint': 'fcm-token-abc123'});
    });
  });

  group('GET /v1/server-info — fcm_enabled', () {
    test('reads the flag', () async {
      final adapter = _CapturingAdapter(
        body: '{"e2ee":true,"fcm_enabled":true}',
      );
      expect((await _api(adapter).serverInfo()).fcmEnabled, isTrue);
    });

    test('defaults FALSE when the server omits it', () async {
      // An older server that never heard of FCM cannot deliver to it, so the
      // app must not hand it a device token for nothing.
      final adapter = _CapturingAdapter(body: '{"e2ee":true}');
      expect((await _api(adapter).serverInfo()).fcmEnabled, isFalse);
    });

    test('parses fcm_enabled independently of the retention kill-switch', () {
      // Two separate gates: a server can allow the retention features and still
      // have no push transport configured.
      expect(
        ServerInfo.fromJson(const {
          'retention_features_enabled': true,
          'fcm_enabled': false,
        }).fcmEnabled,
        isFalse,
      );
      expect(
        ServerInfo.fromJson(const {
          'retention_features_enabled': false,
          'fcm_enabled': true,
        }).retentionFeaturesEnabled,
        isFalse,
      );
    });
  });
}
