import 'dart:convert';
import 'dart:typed_data';

import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:aul/src/crypto/place_codec.dart';
import 'package:aul/src/data/api/api_client.dart';
import 'package:aul/src/data/key_vault.dart';
import 'package:aul/src/data/secret_store.dart';
import 'package:aul/src/features/retention/background_places.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';

/// Serves GET /v1/circles/{id}/places, counting the calls so the TTL can be
/// asserted rather than assumed.
class _FakePlacesAdapter implements HttpClientAdapter {
  _FakePlacesAdapter(this.body);

  /// The `places` array the server returns, or null to fail like a flat network.
  String? body;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    final b = body;
    if (b == null) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      );
    }
    return ResponseBody.fromString(
      '{"places":$b}',
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
  late PlaceCodec codec;

  setUpAll(() async {
    crypto = await AulCrypto.load();
    codec = PlaceCodec(crypto);
  });

  final t0 = DateTime.utc(2026, 7, 15, 12);

  /// A vault holding one circle's key, a session and an email — what the
  /// foreground leaves behind for the isolate.
  Future<(KeyVault, SecureKey)> vaultWithCircle() async {
    final vault = KeyVault(InMemorySecretStore());
    final key = crypto.generateCircleKey();
    await vault.saveCircleKey('c1', key.extractBytes());
    await vault.saveReportingTargets([
      {'id': 'c1', 'precision': 'precise'},
    ]);
    await vault.saveEmail('anna@example.com');
    return (vault, key);
  }

  String sealHome(SecureKey key, {String name = 'Home'}) =>
      codec.seal(name: name, lat: 43.2, lng: 76.8, radius: 100, key: key);

  AulApi apiWith(_FakePlacesAdapter adapter, KeyVault vault) {
    final dio = Dio();
    dio.httpClientAdapter = adapter;
    return AulApi(baseUrl: 'https://aul.test', vault: vault, dio: dio);
  }

  test('opens the cache the foreground left, with no network at all', () async {
    final (vault, key) = await vaultWithCircle();
    await vault.saveGeofencePlaces({
      'at': t0.millisecondsSinceEpoch,
      'who': {'c1': 'Anna'},
      'places': [
        {'c': 'c1', 'id': 'home', 'v': 1, 'ct': sealHome(key)},
      ],
    });
    final adapter = _FakePlacesAdapter(null); // any call would throw
    final places = BackgroundPlaces(
      vault: vault,
      crypto: crypto,
      api: apiWith(adapter, vault),
    );

    // Inside the TTL, so the cache alone must answer.
    await places.ensureLoaded(t0.add(const Duration(minutes: 5)));

    expect(places.places, hasLength(1));
    expect(places.places.single.name, 'Home');
    expect(places.places.single.lat, closeTo(43.2, 1e-9));
    expect(places.places.single.radius, 100);
    expect(places.circleOf('home'), 'c1');
    expect(places.whoIn('c1'), 'Anna');
    expect(adapter.calls, 0, reason: 'a fresh cache costs no request');
  });

  test('what is cached at rest is ciphertext, never a coordinate', () async {
    // The E2EE promise, asserted on the BYTES that sit on the device: the cache
    // holds exactly what the server already has. A plaintext place cache would
    // put every member's home address in a file on disk.
    final (vault, key) = await vaultWithCircle();
    final sealed = sealHome(key, name: 'Anna Home');
    await vault.saveGeofencePlaces({
      'at': t0.millisecondsSinceEpoch,
      'who': {'c1': 'Anna'},
      'places': [
        {'c': 'c1', 'id': 'home', 'v': 1, 'ct': sealed},
      ],
    });

    final raw = jsonEncode(await vault.loadGeofencePlaces());
    expect(raw, contains(sealed));
    expect(raw, isNot(contains('Anna Home')), reason: 'the name stays sealed');
    expect(raw, isNot(contains('43.2')), reason: 'no latitude in cleartext');
    expect(raw, isNot(contains('76.8')), reason: 'no longitude in cleartext');
  });

  test(
    'a place added while backgrounded is picked up once the TTL expires',
    () async {
      // The cost of caching, and the reason the isolate refreshes itself rather
      // than trusting the foreground to have been opened recently.
      final (vault, key) = await vaultWithCircle();
      await vault.saveGeofencePlaces({
        'at': t0.millisecondsSinceEpoch,
        'who': {'c1': 'Anna'},
        'places': const [],
      });
      final adapter = _FakePlacesAdapter(
        '[{"id":"school","ciphertext":"${sealHome(key, name: 'School')}","version":1}]',
      );
      final places = BackgroundPlaces(
        vault: vault,
        crypto: crypto,
        api: apiWith(adapter, vault),
        ttl: const Duration(minutes: 15),
      );

      await places.ensureLoaded(t0.add(const Duration(minutes: 5)));
      expect(places.places, isEmpty, reason: 'still inside the TTL');
      expect(adapter.calls, 0);

      await places.ensureLoaded(t0.add(const Duration(minutes: 20)));
      expect(adapter.calls, 1);
      expect(places.places.single.name, 'School');
      expect(places.circleOf('school'), 'c1');

      // And the refreshed set is written back, so the NEXT isolate starts warm
      // rather than blind.
      final persisted = await vault.loadGeofencePlaces();
      expect((persisted!['places'] as List), hasLength(1));
    },
  );

  test('offline, the cached fences keep working', () async {
    // Crossings must not require the network: the whole point of the queue is
    // that Aul keeps working in a lift.
    final (vault, key) = await vaultWithCircle();
    await vault.saveGeofencePlaces({
      'at': t0.millisecondsSinceEpoch,
      'who': {'c1': 'Anna'},
      'places': [
        {'c': 'c1', 'id': 'home', 'v': 1, 'ct': sealHome(key)},
      ],
    });
    final adapter = _FakePlacesAdapter(null); // flat network
    final places = BackgroundPlaces(
      vault: vault,
      crypto: crypto,
      api: apiWith(adapter, vault),
      ttl: const Duration(minutes: 15),
    );

    await places.ensureLoaded(t0.add(const Duration(minutes: 30)));
    expect(adapter.calls, greaterThan(0), reason: 'it tried');
    expect(
      places.places.single.name,
      'Home',
      reason: 'a failed refresh must not blank the fences',
    );

    // A failure backs off for a TTL rather than retrying every fix.
    final after = adapter.calls;
    await places.ensureLoaded(t0.add(const Duration(minutes: 31)));
    expect(adapter.calls, after, reason: 'no retry storm on the radio');
  });

  test('a place no key opens is skipped, not guessed at', () async {
    final (vault, _) = await vaultWithCircle();
    final stranger = crypto.generateCircleKey(); // a key this device lacks
    await vault.saveGeofencePlaces({
      'at': t0.millisecondsSinceEpoch,
      'who': {'c1': 'Anna'},
      'places': [
        {'c': 'c1', 'id': 'home', 'v': 1, 'ct': sealHome(stranger)},
      ],
    });
    final places = BackgroundPlaces(
      vault: vault,
      crypto: crypto,
      api: apiWith(_FakePlacesAdapter(null), vault),
    );

    await places.ensureLoaded(t0.add(const Duration(minutes: 5)));
    expect(places.places, isEmpty);
  });

  test(
    'with no cache and no network, it stays quiet rather than throwing',
    () async {
      final (vault, _) = await vaultWithCircle();
      final places = BackgroundPlaces(
        vault: vault,
        crypto: crypto,
        api: apiWith(_FakePlacesAdapter(null), vault),
      );

      await places.ensureLoaded(t0);
      expect(places.places, isEmpty);
      expect(
        places.whoIn('c1'),
        'anna@example.com',
        reason: 'the email fallback',
      );
    },
  );
}
