@Tags(['live'])
library;

import 'dart:convert';

import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:aul/src/crypto/ping_codec.dart';
import 'package:aul/src/data/api/api_client.dart';
import 'package:aul/src/data/db/queue_db.dart';
import 'package:aul/src/data/key_vault.dart';
import 'package:aul/src/data/secret_store.dart';
import 'package:aul/src/domain/location_fix.dart';
import 'package:aul/src/tracking/reporter.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// End-to-end proof that the reporter seals a fix, the server stores only
/// ciphertext, and a watcher decrypts it back — against the REAL server.
/// Point AUL_TEST_SERVER at a running server (default http://localhost:8080).
/// Skips gracefully if no server is reachable.
void main() {
  // NB: deliberately NOT calling TestWidgetsFlutterBinding.ensureInitialized() —
  // it installs a mock HttpClient that returns 400 for all real network calls.
  // This is a live network integration test.
  const baseUrl = String.fromEnvironment(
    'AUL_TEST_SERVER',
    defaultValue: 'http://127.0.0.1:8080',
  );

  late AulCrypto crypto;
  setUpAll(() async {
    crypto = await AulCrypto.load();
  });

  test(
    'E2EE ping: reporter → server (ciphertext) → watcher decrypts',
    () async {
      // Probe the server; skip if it isn't up.
      try {
        await Dio().get<dynamic>('$baseUrl/healthz');
      } catch (e) {
        markTestSkipped('no Aul server at $baseUrl ($e) — skipping live test');
        return;
      }

      final vault = KeyVault(InMemorySecretStore());
      final api = AulApi(baseUrl: baseUrl, vault: vault);

      // Register with a real X25519 identity public key.
      final identity = crypto.generateIdentityKeyPair();
      final email =
          'reporter+${DateTime.now().microsecondsSinceEpoch}@example.com';
      await api.register(
        email: email,
        password: 'reporter-strong-password',
        platform: 'android',
        pubkeyB64: base64.encode(identity.publicKey),
      );

      // Create a circle and generate its key on-device.
      final circle = await api.createCircle(retentionDays: 7);
      final circleKey = crypto.generateCircleKey();
      await vault.saveCircleKey(circle.id, circleKey.extractBytes());

      // Report an encrypted fix through the offline queue.
      final queue = QueueDatabase(NativeDatabase.memory());
      addTearDown(queue.close);
      final reporter = Reporter(crypto: crypto, queue: queue, api: api);

      final fix = LocationFix(
        lat: 43.238949,
        lng: 76.889709,
        accuracy: 9,
        battery: 88,
        capturedAt: DateTime.now().toUtc(),
      );
      final enqueued = await reporter.record(fix, [
        CircleTarget(circle.id, circleKey, PrecisionMode.precise),
      ]);
      expect(enqueued, 1);

      final result = await reporter.flush();
      expect(result, isNotNull);
      expect(result!.stored, 1);
      expect(await queue.pendingCount(), 0);

      // Read the ciphertext back from the server and decrypt it locally.
      final remote = await api.latestPings(circle.id);
      expect(remote, isNotEmpty);
      final rp = remote.first;
      final opened = PingCodec(crypto).open(
        base64.decode(rp.nonceB64),
        base64.decode(rp.ciphertextB64),
        circleKey,
      );
      expect(opened.lat, closeTo(fix.lat, 1e-9));
      expect(opened.lng, closeTo(fix.lng, 1e-9));
      expect(opened.battery, 88);

      // Idempotency: re-flushing an empty queue is a no-op.
      expect(await reporter.flush(), isNull);
    },
  );
}
