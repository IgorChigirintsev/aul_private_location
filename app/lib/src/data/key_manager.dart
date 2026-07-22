import 'dart:convert';
import 'dart:typed_data';

import '../crypto/aul_crypto.dart';
import 'api/api_client.dart';
import 'key_vault.dart';

/// Manages the circle key K_c across devices via sealed key envelopes
/// (crypto_box_seal): opening envelopes addressed to this device, distributing
/// K_c to member devices, and rotating the key. The server only relays sealed
/// boxes it cannot open; K_c and the private key never leave the device.
class KeyManager {
  KeyManager({
    required AulCrypto crypto,
    required AulApi api,
    required KeyVault vault,
  }) : _crypto = crypto,
       _api = api,
       _vault = vault;

  final AulCrypto _crypto;
  final AulApi _api;
  final KeyVault _vault;

  /// Opens every pending envelope addressed to this device, storing the
  /// recovered K_c. Returns the circle ids that gained a key. Safe to call on
  /// startup / reconnect.
  Future<List<String>> openPendingEnvelopes() async {
    final id = await _vault.loadIdentity();
    if (id == null) return const [];
    final identity = _crypto.identityKeyPairFromBytes(
      id.publicKey,
      id.secretKey,
    );
    // Open every envelope we can, then ADD the recovered keys to each circle's
    // ring in ascending key_epoch order so the highest-epoch key ends up newest
    // (the sealing key) even if the server returns envelopes out of order. A
    // device offline across several rotations thus catches up on every key and
    // still seals under the latest.
    final opened =
        <({String circleId, int epoch, Uint8List kc, String envId})>[];
    for (final env in await _api.pendingEnvelopes()) {
      try {
        final kc = _crypto.openSealed(
          base64.decode(env.ciphertextB64),
          identity,
        );
        opened.add((
          circleId: env.circleId,
          epoch: env.keyEpoch,
          kc: kc,
          envId: env.id,
        ));
      } catch (_) {
        // Not for us / malformed — leave it for the intended device.
      }
    }
    opened.sort((a, b) => a.epoch.compareTo(b.epoch));
    final updated = <String>{};
    for (final e in opened) {
      await _vault.addCircleKey(e.circleId, e.kc); // ring append (dedup)
      await _api.consumeEnvelope(e.envId);
      updated.add(e.circleId);
    }
    return updated.toList();
  }

  /// Seals [key] to every member device that has an identity public key and
  /// posts the envelopes. Returns how many were delivered.
  Future<int> distributeKey(String circleId, Uint8List key) async {
    final devices = await _api.circleDevices(circleId);
    final envelopes = <Map<String, dynamic>>[];
    for (final d in devices) {
      final pub = d.pubkeyB64;
      if (pub == null) continue;
      final sealed = _crypto.sealToPublicKey(key, base64.decode(pub));
      envelopes.add({
        'recipient_device_id': d.id,
        'ciphertext': base64.encode(sealed),
        'key_epoch': 0, // server clamps ≤0 to the current epoch
      });
    }
    if (envelopes.isEmpty) return 0;
    return _api.postEnvelopes(circleId, envelopes);
  }

  /// Rotates K_c: a fresh key, the server epoch bumped, then the new key
  /// distributed to all member devices. Order matters — the server epoch is
  /// bumped *first* (so a server failure aborts before any local/remote state
  /// changes), and always *before* distribution so the new key lands at a
  /// distinct epoch (the server clamps key_epoch=0 to the circle's current
  /// epoch), keeping one pending envelope per rotation so a device offline
  /// across several rotations catches up on every intermediate key. The fresh
  /// key is APPENDED to the local ring as its new newest (sealing) key; older
  /// keys stay in the ring so pre-rotation data still opens (v1: no forward
  /// secrecy — see THREAT_MODEL). Returns the new key bytes.
  Future<Uint8List> rotateKey(String circleId) async {
    final next = _crypto.generateCircleKey().extractBytes();
    await _api.rotateKey(circleId);
    await _vault.addCircleKey(circleId, next); // newest = the sealing key
    await distributeKey(circleId, next);
    return next;
  }
}
