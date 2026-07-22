import 'dart:convert';
import 'dart:typed_data';

import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:aul/src/crypto/place_codec.dart';
import 'package:aul/src/data/key_vault.dart';
import 'package:aul/src/data/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for the per-circle KEY RING (all K_c epochs): append + dedup, the
/// newest key used for sealing, transparent migration of a legacy single-key
/// entry, and a cross-codec proof that data sealed under an OLD key still opens
/// once a newer key is added (rotation-safe decrypt). Fully hermetic — an
/// in-memory secret store, no network, no platform channels.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List key(int fill) => Uint8List.fromList(List.filled(32, fill));

  late InMemorySecretStore store;
  late KeyVault vault;
  setUp(() {
    store = InMemorySecretStore();
    vault = KeyVault(store);
  });

  test('empty ring when nothing stored', () async {
    expect(await vault.loadCircleKeys('c1'), isEmpty);
    expect(await vault.loadCircleKey('c1'), isNull);
  });

  test(
    'addCircleKey appends oldest→newest; loadCircleKey returns newest',
    () async {
      await vault.addCircleKey('c1', key(1));
      await vault.addCircleKey('c1', key(2));
      await vault.addCircleKey('c1', key(3));

      final ring = await vault.loadCircleKeys('c1');
      expect(ring, hasLength(3));
      expect(ring[0], key(1)); // oldest first
      expect(ring[1], key(2));
      expect(ring[2], key(3)); // newest last
      // The newest key is the one used for SEALING.
      expect(await vault.loadCircleKey('c1'), key(3));
    },
  );

  test('dedup by bytes: re-adding an existing key is a no-op', () async {
    await vault.addCircleKey('c1', key(7));
    await vault.addCircleKey('c1', key(7)); // same bytes → ignored
    await vault.addCircleKey('c1', key(8));
    await vault.addCircleKey('c1', key(7)); // already present → ignored

    final ring = await vault.loadCircleKeys('c1');
    expect(ring, hasLength(2));
    expect(ring[0], key(7));
    expect(ring[1], key(8));
    // Dedup does NOT move an existing key to newest.
    expect(await vault.loadCircleKey('c1'), key(8));
  });

  test('saveCircleKey is an alias for addCircleKey (append + dedup)', () async {
    await vault.saveCircleKey('c1', key(1));
    await vault.saveCircleKey('c1', key(2));
    await vault.saveCircleKey('c1', key(1)); // dedup

    expect(await vault.loadCircleKeys('c1'), [key(1), key(2)]);
    expect(await vault.loadCircleKey('c1'), key(2));
  });

  test(
    'migrates a legacy single-key entry into a 1-element ring on read',
    () async {
      // Simulate an entry written by an older build: a single bare-base64 key.
      await store.put('circle_key_c1', base64.encode(key(5)));

      expect(await vault.loadCircleKeys('c1'), [key(5)]);
      expect(await vault.loadCircleKey('c1'), key(5));

      // Appending upgrades it to the JSON ring form while preserving the legacy key.
      await vault.addCircleKey('c1', key(6));
      expect(await vault.loadCircleKeys('c1'), [key(5), key(6)]);
      expect(await vault.loadCircleKey('c1'), key(6));
      // Stored value is now the JSON list form.
      expect(await store.get('circle_key_c1'), startsWith('['));
    },
  );

  test('removeCircleKey clears the whole ring', () async {
    await vault.addCircleKey('c1', key(1));
    await vault.addCircleKey('c1', key(2));
    await vault.removeCircleKey('c1');
    expect(await vault.loadCircleKeys('c1'), isEmpty);
    expect(await vault.loadCircleKey('c1'), isNull);
  });

  test('rings are isolated per circle', () async {
    await vault.addCircleKey('a', key(1));
    await vault.addCircleKey('b', key(2));
    expect(await vault.loadCircleKey('a'), key(1));
    expect(await vault.loadCircleKey('b'), key(2));
    expect(await vault.loadCircleKeys('a'), [key(1)]);
  });

  test(
    'ROTATION-SAFE: data sealed under an OLD key still opens after a newer key is added',
    () async {
      final crypto = await AulCrypto.load();
      final codec = PlaceCodec(crypto);

      // Owner seals a place under the ORIGINAL circle key, then persists it.
      final oldKey = crypto.generateCircleKey();
      final sealed = codec.seal(
        name: 'Home',
        lat: 43.238949,
        lng: 76.889709,
        radius: 120,
        key: oldKey,
      );
      await vault.addCircleKey('c1', oldKey.extractBytes());

      // A rotation adds a fresh key as the new NEWEST (sealing) key.
      final newKey = crypto.generateCircleKey();
      await vault.addCircleKey('c1', newKey.extractBytes());

      // Sealing now uses the newest key…
      expect(await vault.loadCircleKey('c1'), newKey.extractBytes());

      // …but the pre-rotation place still opens because the whole ring is tried.
      final ringBytes = await vault.loadCircleKeys('c1');
      final ring = [for (final b in ringBytes) crypto.circleKeyFromBytes(b)];
      final place = codec.open(
        id: 'p1',
        version: 1,
        ciphertextB64: sealed,
        keyring: ring,
      );
      expect(place, isNotNull);
      expect(place!.name, 'Home');
      expect(place.radius, 120);

      // And the newest key alone canNOT open it (proving the ring is what saves it).
      final newOnly = codec.open(
        id: 'p1',
        version: 1,
        ciphertextB64: sealed,
        keyring: [crypto.circleKeyFromBytes(newKey.extractBytes())],
      );
      expect(newOnly, isNull);

      for (final k in ring) {
        k.dispose();
      }
    },
  );

  test('the geofence inside-set round-trips, and a wipe forgets it', () async {
    // The durable crossing state the background isolate depends on. It lives in
    // the keystore rather than the queue DB because it is location-derived, and
    // because a sign-out must take it with the keys — a second account inheriting
    // "you are inside Home" would announce a departure from a place it has never
    // heard of.
    final vault = KeyVault(InMemorySecretStore());
    expect(await vault.loadGeofenceInside(), isEmpty);

    await vault.saveGeofenceInside({'home', 'school'});
    expect(await vault.loadGeofenceInside(), {'home', 'school'});

    // Leaving one place rewrites the whole set, rather than merging into it.
    await vault.saveGeofenceInside({'school'});
    expect(await vault.loadGeofenceInside(), {'school'});

    await vault.wipe();
    expect(await vault.loadGeofenceInside(), isEmpty);
  });

  test(
    'a corrupt geofence entry re-seeds instead of crashing the isolate',
    () async {
      // This runs in a headless service with nobody watching. Throwing here would
      // take reporting down with it; an empty set merely costs one phantom enter.
      final store = InMemorySecretStore();
      await store.put('geofence_inside', 'not json');
      expect(await KeyVault(store).loadGeofenceInside(), isEmpty);
    },
  );
}
