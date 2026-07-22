import 'dart:convert';
import 'dart:typed_data';

import 'package:aul/l10n/app_localizations.dart';
import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:aul/src/crypto/notify_codec.dart';
import 'package:aul/src/data/api/api_client.dart';
import 'package:aul/src/data/key_vault.dart';
import 'package:aul/src/data/secret_store.dart';
import 'package:aul/src/domain/place.dart';
import 'package:aul/src/features/retention/arrival_monitor.dart';
import 'package:aul/src/features/retention/notify_relay.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_notification_service.dart';

/// One captured POST /v1/circles/{id}/notify.
class _Post {
  const _Post(this.path, this.body);
  final String path;
  final Map<String, dynamic> body;
}

/// Captures what the app actually put on the wire, so the relay is asserted on
/// the REQUEST, not on a mock of itself. [status] fakes the server's answer.
class _FakeNotifyAdapter implements HttpClientAdapter {
  _FakeNotifyAdapter({this.status = 200});

  final int status;
  final List<_Post> posts = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    posts.add(
      _Post(options.path, (options.data as Map).cast<String, dynamic>()),
    );
    if (status >= 400) {
      return ResponseBody.fromString(
        '{"error":{"code":"internal","message":"push is not configured"}}',
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      '{"sent":2,"failed":0}',
      status,
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
  final l10n = lookupAppLocalizations(const Locale('en'));

  late AulCrypto crypto;
  setUpAll(() async => crypto = await AulCrypto.load());

  const home = Place(
    id: 'place-home',
    version: 1,
    name: 'Home',
    lat: 43.2,
    lng: 76.8,
    radius: 100,
  );
  final t0 = DateTime.utc(2026, 1, 1, 9, 30);

  /// A vault holding K_c for 'c1' (and nothing for any other circle).
  Future<(KeyVault, Uint8List)> vaultWithKey() async {
    final vault = KeyVault(InMemorySecretStore());
    final key = crypto.generateCircleKey();
    final raw = key.extractBytes();
    key.dispose();
    await vault.saveCircleKey('c1', raw);
    return (vault, raw);
  }

  ({
    ArrivalMonitor monitor,
    _FakeNotifyAdapter adapter,
    FakeNotificationService notifications,
  })
  wire(KeyVault vault, {int status = 200, String who = 'Aisha'}) {
    final adapter = _FakeNotifyAdapter(status: status);
    final dio = Dio(BaseOptions(baseUrl: 'https://aul.test'));
    dio.httpClientAdapter = adapter;
    final api = AulApi(baseUrl: 'https://aul.test', vault: vault, dio: dio);
    final relay = NotifyRelay(
      api: api,
      crypto: crypto,
      vault: vault,
      // 'place-home' belongs to circle c1 — the only circle it may be told to.
      circleOfPlace: (placeId) => placeId == 'place-home' ? 'c1' : null,
      whoIn: (_) => who,
    );
    final notifications = FakeNotificationService();
    return (
      monitor: ArrivalMonitor(
        notifications: notifications,
        relay: relay.onCrossing,
      ),
      adapter: adapter,
      notifications: notifications,
    );
  }

  /// Drives the device from far away to inside [home] — one real geofence enter
  /// through the real arrival path.
  Future<void> arriveHome(
    ArrivalMonitor monitor, {
    bool active = true,
    bool relayActive = true,
  }) async {
    await monitor.onOwnFix(
      lat: 43.25,
      lng: 76.85,
      places: const [home],
      now: t0,
      active: active,
      relayActive: relayActive,
      l10n: l10n,
    );
    await monitor.onOwnFix(
      lat: 43.2,
      lng: 76.8,
      places: const [home],
      now: t0,
      active: active,
      relayActive: relayActive,
      l10n: l10n,
    );
  }

  test('an arrival POSTs exactly once, to the right circle, sealed', () async {
    final (vault, raw) = await vaultWithKey();
    final w = wire(vault);

    await arriveHome(w.monitor);

    // ONE crossing ⇒ ONE relay. Not one per fix, not one per circle.
    expect(w.adapter.posts, hasLength(1));
    final post = w.adapter.posts.single;
    expect(post.path, '/v1/circles/c1/notify');
    expect(post.body.keys, ['payload_enc']);

    // The body is opaque to the server and opens only under K_c.
    final key = crypto.circleKeyFromBytes(raw);
    final opened = NotifyCodec(
      crypto,
    ).open(post.body['payload_enc'] as String, [key]);
    expect(opened, isNotNull);
    expect(opened!.kind, NotifyKind.arrival);
    expect(opened.place, 'Home');
    expect(opened.who, 'Aisha');
    expect(opened.ts, t0.millisecondsSinceEpoch);

    // Nothing recognisable is on the wire in the clear: not the place name, not
    // the nickname. The server sees a base64 blob and a circle id.
    final onTheWire = jsonEncode(post.body);
    expect(onTheWire, isNot(contains('Home')));
    expect(onTheWire, isNot(contains('Aisha')));
    expect(onTheWire, isNot(contains('arrival')));
  });

  test('leaving relays a departure', () async {
    final (vault, raw) = await vaultWithKey();
    final w = wire(vault);
    await arriveHome(w.monitor);

    // Beyond radius + hysteresis ⇒ a real exit.
    await w.monitor.onOwnFix(
      lat: 43.25,
      lng: 76.85,
      places: const [home],
      now: t0,
      active: true,
      relayActive: true,
      l10n: l10n,
    );

    expect(w.adapter.posts, hasLength(2));
    final key = crypto.circleKeyFromBytes(raw);
    final opened = NotifyCodec(
      crypto,
    ).open(w.adapter.posts.last.body['payload_enc'] as String, [key]);
    expect(opened!.kind, NotifyKind.departure);
    expect(opened.place, 'Home');
  });

  test('a 503 (push not configured) is a silent no-op', () async {
    final (vault, _) = await vaultWithKey();
    final w = wire(vault, status: 503);

    // Must not throw, and must not stop the local alert from firing.
    await arriveHome(w.monitor);

    expect(w.adapter.posts, hasLength(1)); // it tried
    expect(
      w.notifications.shown,
      hasLength(1),
    ); // and the local alert still fired
    expect(w.notifications.shown.single.body, 'You arrived at Home');
  });

  test('any other failure is swallowed too — best-effort by design', () async {
    final (vault, _) = await vaultWithKey();
    final w = wire(vault, status: 500);
    await arriveHome(w.monitor);
    expect(w.adapter.posts, hasLength(1));
    expect(w.notifications.shown, hasLength(1));
  });

  group('the two gates are separate', () {
    test(
      'the relay fires even when the sender wants NO alert of their own',
      () async {
        // The whole point: `arrival` is a preference about YOUR notification
        // tray. Letting it mute the relay would silently deprive the rest of the
        // circle of their alerts.
        final (vault, _) = await vaultWithKey();
        final w = wire(vault);

        await arriveHome(w.monitor, active: false, relayActive: true);

        expect(w.adapter.posts, hasLength(1)); // the circle IS told
        expect(w.notifications.shown, isEmpty); // this device stays quiet
      },
    );

    test('the operator kill-switch stops the relay dead', () async {
      final (vault, _) = await vaultWithKey();
      final w = wire(vault);

      await arriveHome(w.monitor, active: true, relayActive: false);

      expect(w.adapter.posts, isEmpty); // nothing left the device
      expect(w.notifications.shown, hasLength(1)); // local alert unaffected
    });
  });

  test('a place whose circle is unknown relays nothing', () async {
    final (vault, _) = await vaultWithKey();
    final w = wire(vault);

    const orphan = Place(
      id: 'place-orphan',
      version: 1,
      name: 'Nowhere',
      lat: 43.2,
      lng: 76.8,
      radius: 100,
    );
    await w.monitor.onOwnFix(
      lat: 43.2,
      lng: 76.8,
      places: const [orphan],
      now: t0,
      active: true,
      relayActive: true,
      l10n: l10n,
    );

    expect(w.adapter.posts, isEmpty);
  });

  test(
    'no key for the circle ⇒ nothing to seal under, so nothing is sent',
    () async {
      // An empty vault: this device is in the circle but holds no K_c (e.g. the
      // envelope hasn't arrived). Sending plaintext instead is not an option.
      final vault = KeyVault(InMemorySecretStore());
      final w = wire(vault);

      await arriveHome(w.monitor);

      expect(w.adapter.posts, isEmpty);
      expect(w.notifications.shown, hasLength(1)); // the local alert is local
    },
  );

  test(
    'no crossing, no relay: a fix that changes nothing sends nothing',
    () async {
      final (vault, _) = await vaultWithKey();
      final w = wire(vault);
      await arriveHome(w.monitor);
      expect(w.adapter.posts, hasLength(1));

      // Still inside: no new crossing, so no second announcement.
      await w.monitor.onOwnFix(
        lat: 43.2001,
        lng: 76.8001,
        places: const [home],
        now: t0.add(const Duration(minutes: 1)),
        active: true,
        relayActive: true,
        l10n: l10n,
      );
      expect(w.adapter.posts, hasLength(1));
    },
  );
}
