import 'dart:async';
import 'dart:convert';

import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:aul/src/crypto/ping_codec.dart';
import 'package:aul/src/domain/location_fix.dart';
import 'package:aul/src/features/realtime/realtime_client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';

const _circle = 'circle-1';

/// A [RealtimeChannel] backed by a plain controller: the test plays the server.
/// This is the whole reason [RealtimeChannel] is narrower than
/// `WebSocketChannel` — the client can be driven frame by frame, with no socket,
/// no server, and no waiting.
class FakeChannel implements RealtimeChannel {
  FakeChannel();

  final _controller = StreamController<dynamic>();
  bool closed = false;

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) await _controller.close();
  }

  /// Pushes a raw frame to the client.
  void send(String frame) => _controller.add(frame);

  /// Pushes an event frame in the server's shape (realtime.Event in hub.go).
  void sendEvent(String type, {String? circleId = _circle, Object? payload}) =>
      send(
        jsonEncode({'type': type, 'circle_id': ?circleId, 'payload': ?payload}),
      );

  /// The socket drops (server restart, network away) without the client asking.
  void dropFromServer() {
    if (!_controller.isClosed) _controller.close();
  }
}

/// A real key that records being freed. Only `dispose` is exercised through it —
/// anything else would mean the client used a key it was told to let go of, and
/// [noSuchMethod] fails loudly rather than quietly returning null.
class _SpyKey implements SecureKey {
  _SpyKey(this._inner);

  final SecureKey _inner;
  bool disposed = false;

  @override
  void dispose() {
    disposed = true;
    _inner.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AulCrypto crypto;
  late PingCodec codec;

  setUpAll(() async {
    crypto = await AulCrypto.load();
    codec = PingCodec(crypto);
  });

  /// A ping event payload in the server's `pingDTO` shape, sealed under [key].
  Map<String, dynamic> sealedPingPayload(
    String deviceId,
    LocationFix fix,
    SecureKey key,
  ) {
    final blob = codec.seal(fix, key);
    return {
      'id': 'ping-1',
      'circle_id': _circle,
      'device_id': deviceId,
      'nonce': base64.encode(blob.nonce),
      'ciphertext': base64.encode(blob.ciphertext),
      'captured_at': fix.capturedAt.toUtc().toIso8601String(),
    };
  }

  LocationFix fixAt(DateTime at) =>
      LocationFix(lat: 43.238, lng: 76.889, battery: 55, capturedAt: at);

  /// Builds a client over [channel] with a real keyring, plus the positions it
  /// reports. [keyring] defaults to a fresh key that opens nothing the test seals
  /// unless the test passes the same one.
  ({
    RealtimeClient client,
    List<({String deviceId, LocationFix fix})> positions,
    List<String> events,
    List<bool> status,
  })
  buildClient(
    RealtimeChannel? Function() open, {
    required List<SecureKey> keyring,
  }) {
    final positions = <({String deviceId, LocationFix fix})>[];
    final events = <String>[];
    final status = <bool>[];
    final client = RealtimeClient(
      circleId: _circle,
      open: () async => open(),
      codec: codec,
      keyring: keyring,
      handlers: RealtimeHandlers(
        onPosition: (deviceId, fix) =>
            positions.add((deviceId: deviceId, fix: fix)),
        onSos: (_) => events.add('sos'),
        onSosResolved: (id) => events.add('sos_resolved:$id'),
        onPlaceUpdated: () => events.add('places'),
        onPrecision: () => events.add('precision'),
        onMemberChanged: () => events.add('members'),
        onKeyEnvelope: () => events.add('key_envelope'),
        onStatus: status.add,
      ),
    );
    return (
      client: client,
      positions: positions,
      events: events,
      status: status,
    );
  }

  group('ping events', () {
    test('a ping decrypts on THIS device and lands as a position', () {
      fakeAsync((async) {
        final key = crypto.generateCircleKey();
        final channel = FakeChannel();
        final c = buildClient(() => channel, keyring: [key]);
        c.client.connect();
        async.flushMicrotasks();

        final at = DateTime.utc(2026, 7, 15, 12, 30);
        channel.sendEvent(
          'ping',
          payload: sealedPingPayload('dev-a', fixAt(at), key),
        );
        async.flushMicrotasks();

        expect(c.positions, hasLength(1));
        expect(c.positions.single.deviceId, 'dev-a');
        // The coordinates came out of the ciphertext the socket carried — the
        // server relayed a blob it could not read.
        expect(c.positions.single.fix.lat, closeTo(43.238, 1e-9));
        expect(c.positions.single.fix.battery, 55);
        expect(c.positions.single.fix.capturedAt, at);

        c.client.dispose();
      });
    });

    test('a ping no key opens is SKIPPED silently, not surfaced', () {
      fakeAsync((async) {
        // Sealed under a key this device does not hold — a member on a rotated
        // key, say. Normal on a server that relays ciphertext.
        final theirKey = crypto.generateCircleKey();
        final myKey = crypto.generateCircleKey();
        final channel = FakeChannel();
        final c = buildClient(() => channel, keyring: [myKey]);
        c.client.connect();
        async.flushMicrotasks();

        channel.sendEvent(
          'ping',
          payload: sealedPingPayload(
            'dev-a',
            fixAt(DateTime.utc(2026, 7, 15)),
            theirKey,
          ),
        );
        async.flushMicrotasks();

        expect(c.positions, isEmpty);
        // Skipped, not fatal: the connection stays up for everything else.
        expect(c.client.connected, isTrue);

        // ...and a ping we CAN open still arrives on the same connection.
        channel.sendEvent(
          'ping',
          payload: sealedPingPayload(
            'dev-b',
            fixAt(DateTime.utc(2026, 7, 15)),
            myKey,
          ),
        );
        async.flushMicrotasks();
        expect(c.positions.single.deviceId, 'dev-b');

        c.client.dispose();
        theirKey.dispose();
      });
    });

    test('a keyring-less client skips pings but stays useful for events', () {
      fakeAsync((async) {
        final key = crypto.generateCircleKey();
        final channel = FakeChannel();
        // No key for this circle yet (invited, key not distributed).
        final c = buildClient(() => channel, keyring: []);
        c.client.connect();
        async.flushMicrotasks();

        channel.sendEvent(
          'ping',
          payload: sealedPingPayload(
            'dev-a',
            fixAt(DateTime.utc(2026, 7, 15)),
            key,
          ),
        );
        channel.sendEvent('key_envelope');
        async.flushMicrotasks();

        expect(c.positions, isEmpty);
        // The event that says "you have just been given the key" must still land —
        // it is how this device stops being keyring-less.
        expect(c.events, ['key_envelope']);

        c.client.dispose();
        key.dispose();
      });
    });

    test('a malformed ping payload is ignored', () {
      fakeAsync((async) {
        final key = crypto.generateCircleKey();
        final channel = FakeChannel();
        final c = buildClient(() => channel, keyring: [key]);
        c.client.connect();
        async.flushMicrotasks();

        channel.sendEvent('ping', payload: {'device_id': 'dev-a'}); // no blob
        channel.sendEvent('ping', payload: 'not-an-object');
        channel.sendEvent(
          'ping',
          payload: {
            'device_id': 'dev-a',
            'nonce': '!!not base64!!',
            'ciphertext': '!!not base64!!',
            'captured_at': DateTime.utc(2026).toIso8601String(),
          },
        );
        async.flushMicrotasks();

        expect(c.positions, isEmpty);
        expect(c.client.connected, isTrue);
        c.client.dispose();
      });
    });
  });

  group('other event types trigger the right refresh', () {
    test('each event reaches its own handler', () {
      fakeAsync((async) {
        final key = crypto.generateCircleKey();
        final channel = FakeChannel();
        final c = buildClient(() => channel, keyring: [key]);
        c.client.connect();
        async.flushMicrotasks();

        channel.sendEvent('sos', payload: {'id': 'sos-1'});
        channel.sendEvent('sos_resolved', payload: {'id': 'sos-1'});
        channel.sendEvent('place_updated');
        channel.sendEvent('precision_mode');
        channel.sendEvent('member_changed');
        channel.sendEvent('key_envelope');
        async.flushMicrotasks();

        expect(c.events, [
          'sos',
          'sos_resolved:sos-1',
          'places',
          'precision',
          'members',
          'key_envelope',
        ]);
        c.client.dispose();
      });
    });

    test('events for ANOTHER circle are ignored', () {
      fakeAsync((async) {
        final key = crypto.generateCircleKey();
        final channel = FakeChannel();
        final c = buildClient(() => channel, keyring: [key]);
        c.client.connect();
        async.flushMicrotasks();

        // The server subscribes the connection to every circle the user is in, so
        // these genuinely arrive. This client speaks for one circle only.
        channel.sendEvent('member_changed', circleId: 'other-circle');
        channel.sendEvent(
          'ping',
          circleId: 'other-circle',
          payload: sealedPingPayload(
            'dev-x',
            fixAt(DateTime.utc(2026, 7, 15)),
            key,
          ),
        );
        async.flushMicrotasks();

        expect(c.events, isEmpty);
        expect(c.positions, isEmpty);
        c.client.dispose();
      });
    });

    test('the welcome frame and unknown/garbage frames are survived', () {
      fakeAsync((async) {
        final key = crypto.generateCircleKey();
        final channel = FakeChannel();
        final c = buildClient(() => channel, keyring: [key]);
        c.client.connect();
        async.flushMicrotasks();

        channel.send(
          jsonEncode({
            'type': 'welcome',
            'circles': [_circle],
          }),
        );
        channel.send('not json at all');
        channel.send(
          jsonEncode({'type': 'from_the_future', 'circle_id': _circle}),
        );
        channel.send(jsonEncode([1, 2, 3])); // JSON, but not an object
        async.flushMicrotasks();

        expect(c.events, isEmpty);
        // Above all: none of it killed the connection.
        expect(c.client.connected, isTrue);
        channel.sendEvent('member_changed');
        async.flushMicrotasks();
        expect(c.events, ['members']);

        c.client.dispose();
      });
    });
  });

  group('reconnect + backoff', () {
    test('a dropped socket reconnects, doubling the wait up to the ceiling', () {
      fakeAsync((async) {
        final key = crypto.generateCircleKey();
        final opened = <FakeChannel>[];
        FakeChannel? current;
        final c = buildClient(() {
          current = FakeChannel();
          opened.add(current!);
          return current;
        }, keyring: [key]);
        c.client.connect();
        async.flushMicrotasks();
        expect(opened, hasLength(1));
        expect(c.status, [true]);

        // The socket drops. Nothing reconnects instantly — that is the point.
        current!.dropFromServer();
        async.flushMicrotasks();
        expect(c.status, [true, false]);
        expect(opened, hasLength(1));

        // First retry at 1 s.
        async.elapse(const Duration(milliseconds: 999));
        expect(opened, hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(opened, hasLength(2));

        // It drops again WITHOUT ever delivering a frame, so the backoff has not
        // been reset: the next wait is 2 s, not another 1 s.
        current!.dropFromServer();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1999));
        expect(opened, hasLength(2));
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(opened, hasLength(3));

        // Keep failing: 4, 8, 16, then it clamps at the 30 s ceiling rather than
        // drifting off to hours.
        for (final seconds in [4, 8, 16, 30, 30]) {
          current!.dropFromServer();
          async.flushMicrotasks();
          async.elapse(Duration(milliseconds: seconds * 1000 - 1));
          final before = opened.length;
          async.elapse(const Duration(milliseconds: 1));
          async.flushMicrotasks();
          expect(
            opened,
            hasLength(before + 1),
            reason: 'expected a retry after ${seconds}s',
          );
        }

        c.client.dispose();
      });
    });

    test('a frame resets the backoff, so a healthy reconnect is fast again', () {
      fakeAsync((async) {
        final key = crypto.generateCircleKey();
        final opened = <FakeChannel>[];
        FakeChannel? current;
        final c = buildClient(() {
          current = FakeChannel();
          opened.add(current!);
          return current;
        }, keyring: [key]);
        c.client.connect();
        async.flushMicrotasks();

        // Fail once so the backoff has grown past its floor.
        current!.dropFromServer();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(opened, hasLength(2));

        // This connection actually WORKS — a frame arrives.
        current!.sendEvent('member_changed');
        async.flushMicrotasks();

        // A later drop starts over at 1 s: the last connection proved the server
        // is reachable and this device is authenticated, so there is nothing to
        // back off from.
        current!.dropFromServer();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 999));
        expect(opened, hasLength(2));
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(opened, hasLength(3));

        c.client.dispose();
      });
    });

    test('an opener that cannot connect backs off instead of hot-looping', () {
      fakeAsync((async) {
        final key = crypto.generateCircleKey();
        var attempts = 0;
        final c = buildClient(() {
          attempts++;
          return null; // no session to authenticate with, say
        }, keyring: [key]);
        c.client.connect();
        async.flushMicrotasks();
        expect(attempts, 1);
        expect(c.client.connected, isFalse);

        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(attempts, 2);

        // Still spaced out, not spinning.
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(attempts, 3);

        c.client.dispose();
      });
    });

    test('connect() twice does not open a second socket', () {
      fakeAsync((async) {
        final key = crypto.generateCircleKey();
        var opens = 0;
        final c = buildClient(() {
          opens++;
          return FakeChannel();
        }, keyring: [key]);
        c.client.connect();
        c.client.connect();
        async.flushMicrotasks();
        c.client.connect();
        async.flushMicrotasks();
        expect(opens, 1);
        c.client.dispose();
      });
    });
  });

  group('dispose', () {
    test('closes the socket and stops reconnecting for good', () {
      fakeAsync((async) {
        final key = crypto.generateCircleKey();
        final opened = <FakeChannel>[];
        FakeChannel? current;
        final c = buildClient(() {
          current = FakeChannel();
          opened.add(current!);
          return current;
        }, keyring: [key]);
        c.client.connect();
        async.flushMicrotasks();

        c.client.dispose();
        expect(opened.single.closed, isTrue);
        expect(c.client.connected, isFalse);

        // A drop after dispose must not resurrect it, and neither must time.
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();
        expect(opened, hasLength(1));
      });
    });

    test('a pending reconnect is cancelled by dispose', () {
      fakeAsync((async) {
        final key = crypto.generateCircleKey();
        final opened = <FakeChannel>[];
        FakeChannel? current;
        final c = buildClient(() {
          current = FakeChannel();
          opened.add(current!);
          return current;
        }, keyring: [key]);
        c.client.connect();
        async.flushMicrotasks();
        current!.dropFromServer(); // arms a retry
        async.flushMicrotasks();

        c.client.dispose();
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();
        expect(opened, hasLength(1), reason: 'the armed retry must not fire');
      });
    });

    test('dispose frees EVERY key in the ring it was given', () {
      fakeAsync((async) {
        // A ring, not one key: rotation means several epochs, and leaving the
        // older ones alive would leak exactly the key material this frees.
        final keys = <_SpyKey>[
          _SpyKey(crypto.generateCircleKey()),
          _SpyKey(crypto.generateCircleKey()),
        ];
        final c = buildClient(FakeChannel.new, keyring: keys);
        c.client.connect();
        async.flushMicrotasks();

        expect(keys.every((k) => k.disposed), isFalse);
        c.client.dispose();
        // The client OWNS the ring: nothing is left holding circle key material
        // for a circle the app has stopped watching.
        expect(keys.every((k) => k.disposed), isTrue);
      });
    });

    test('dispose is idempotent', () {
      fakeAsync((async) {
        final key = crypto.generateCircleKey();
        final c = buildClient(FakeChannel.new, keyring: [key]);
        c.client.connect();
        async.flushMicrotasks();
        c.client.dispose();
        expect(c.client.dispose, returnsNormally);
      });
    });

    test('a socket that opens AFTER dispose is closed, not kept', () {
      fakeAsync((async) {
        final key = crypto.generateCircleKey();
        final channel = FakeChannel();
        final completer = Completer<RealtimeChannel?>();
        final client = RealtimeClient(
          circleId: _circle,
          open: () => completer.future,
          codec: codec,
          keyring: [key],
        );
        client.connect();
        async.flushMicrotasks();

        // Disposed while the connect is still in flight (the screen closed).
        client.dispose();
        completer.complete(channel);
        async.flushMicrotasks();

        expect(channel.closed, isTrue, reason: 'the late socket must not leak');
        expect(client.connected, isFalse);
      });
    });
  });

  group('realtimeUrl', () {
    test('maps the scheme and keeps host + port', () {
      expect(
        realtimeUrl('https://aul.example.org').toString(),
        'wss://aul.example.org/v1/realtime',
      );
      expect(
        realtimeUrl('http://10.0.2.2:8080').toString(),
        'ws://10.0.2.2:8080/v1/realtime',
      );
    });

    test('https ⇒ wss: a socket must not be the one plaintext hop', () {
      expect(realtimeUrl('https://aul.example.org')!.scheme, 'wss');
      expect(realtimeUrl('http://localhost:8080')!.scheme, 'ws');
    });

    test('keeps a base path, so a server under a prefix still works', () {
      expect(
        realtimeUrl('https://example.org/aul').toString(),
        'wss://example.org/aul/v1/realtime',
      );
      // A trailing slash must not produce `//v1/realtime`.
      expect(
        realtimeUrl('https://example.org/aul/').toString(),
        'wss://example.org/aul/v1/realtime',
      );
      expect(
        realtimeUrl('https://example.org/').toString(),
        'wss://example.org/v1/realtime',
      );
    });

    test('already-ws URLs pass through', () {
      expect(
        realtimeUrl('ws://localhost:8080').toString(),
        'ws://localhost:8080/v1/realtime',
      );
      expect(
        realtimeUrl('wss://aul.example.org').toString(),
        'wss://aul.example.org/v1/realtime',
      );
    });

    test('surrounding whitespace is tolerated', () {
      expect(
        realtimeUrl('  https://aul.example.org  ').toString(),
        'wss://aul.example.org/v1/realtime',
      );
    });

    test('anything that is not a usable server URL yields null', () {
      // Null, not a guess: there is nothing to connect to, and a fabricated URL
      // would only produce a reconnect loop against nothing.
      expect(realtimeUrl(''), isNull);
      expect(realtimeUrl('not a url'), isNull);
      expect(realtimeUrl('/v1/realtime'), isNull, reason: 'no host');
      expect(realtimeUrl('ftp://example.org'), isNull, reason: 'not http(s)');
    });
  });
}
