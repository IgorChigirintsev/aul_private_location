@Tags(['live'])
library;

import 'dart:convert';

import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:aul/src/data/api/api_client.dart';
import 'package:aul/src/data/key_manager.dart';
import 'package:aul/src/data/key_vault.dart';
import 'package:aul/src/data/secret_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Live validation of the Phase-4 key-envelope path in Dart: the app seals K_c
/// to a device's identity key, the server relays the box it cannot open, and the
/// app recovers K_c by opening its pending envelope. Skips if no server is up.
void main() {
  const baseUrl = String.fromEnvironment(
    'AUL_TEST_SERVER',
    defaultValue: 'http://127.0.0.1:8080',
  );

  late AulCrypto crypto;
  setUpAll(() async {
    crypto = await AulCrypto.load();
  });

  test('K_c distributed as an envelope is recovered by the device', () async {
    try {
      await Dio().get<dynamic>('$baseUrl/healthz');
    } catch (e) {
      markTestSkipped('no Aul server at $baseUrl ($e)');
      return;
    }

    final vault = KeyVault(InMemorySecretStore());
    final api = AulApi(baseUrl: baseUrl, vault: vault);

    // Register with a real identity keypair (stored in the vault).
    final id = crypto.generateIdentityKeyPair();
    await vault.saveIdentity(id.publicKey, id.secretKey.extractBytes());
    final email = 'keymgr+${DateTime.now().microsecondsSinceEpoch}@example.com';
    await api.register(
      email: email,
      password: 'keymanager-strong-pass',
      platform: 'android',
      pubkeyB64: base64.encode(id.publicKey),
    );

    final circle = await api.createCircle(retentionDays: 7);
    final km = KeyManager(crypto: crypto, api: api, vault: vault);

    // Distribute a fresh K_c to this device (seals to our own identity key).
    final kc = crypto.generateCircleKey().extractBytes();
    final delivered = await km.distributeKey(circle.id, kc);
    expect(delivered, greaterThanOrEqualTo(1));

    // Simulate a device that doesn't yet have the key locally.
    await vault.removeCircleKey(circle.id);
    expect(await vault.loadCircleKey(circle.id), isNull);

    // Open pending envelopes → K_c recovered and stored.
    final updated = await km.openPendingEnvelopes();
    expect(updated, contains(circle.id));
    expect(await vault.loadCircleKey(circle.id), equals(kc));
  });
}
