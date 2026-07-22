import {
  fromBase64,
  openSealed,
  randomCircleKey,
  sealToPublicKey,
  toBase64,
} from '../crypto/aulCrypto';
import { api } from './api';
import { keystore } from './keystore';

/// Manages the circle key K_c across devices via sealed key envelopes
/// (crypto_box_seal): opening envelopes addressed to this device, distributing
/// K_c to member devices, and rotating the key. The server only relays sealed
/// boxes it cannot open.
export const keyManager = {
  /// Opens every pending envelope addressed to this device, adding the recovered
  /// K_c to the circle's keyring. Returns the circle ids that gained a key.
  async openPendingEnvelopes(): Promise<string[]> {
    const identity = await keystore.loadIdentity();
    if (!identity) return [];
    const pending = await api.pendingEnvelopes();
    const updated = new Set<string>();
    for (const env of pending) {
      try {
        const kc = openSealed(fromBase64(env.ciphertext), identity.publicKey, identity.privateKey);
        await keystore.saveCircleKey(env.circle_id, kc);
        await api.consumeEnvelope(env.id);
        updated.add(env.circle_id);
      } catch {
        // Not for us / malformed — leave it for the intended device.
      }
    }
    return [...updated];
  },

  /// Seals [key] to every member device that has an identity public key and
  /// posts the envelopes. Skips devices without a key (older/legacy).
  async distributeKey(circleId: string, key: Uint8Array): Promise<number> {
    const devices = await api.circleDevices(circleId);
    const envelopes = devices
      .filter((d) => d.pubkey)
      .map((d) => ({
        recipient_device_id: d.id,
        ciphertext: toBase64(sealToPublicKey(key, fromBase64(d.pubkey!))),
        key_epoch: 0, // server clamps ≤0 to the circle's current epoch
      }));
    if (envelopes.length === 0) return 0;
    const res = await api.postEnvelopes(circleId, envelopes);
    return res.delivered;
  },

  /// Rotates K_c: generates a new key, bumps the server epoch, then distributes
  /// the new key to all member devices as envelopes and adds it to the local
  /// keyring. Order matters: the epoch is bumped *before* distribution so the
  /// new key lands at a distinct epoch (server clamps key_epoch=0 to the
  /// circle's current epoch). This keeps one pending envelope per rotation, so a
  /// device offline across several rotations catches up on every intermediate
  /// key — old keys are retained so history stays readable (v1 has no forward
  /// secrecy).
  async rotateKey(circleId: string): Promise<Uint8Array> {
    const next = randomCircleKey();
    await keystore.saveCircleKey(circleId, next);
    await api.rotateKey(circleId);
    await this.distributeKey(circleId, next);
    return next;
  },
};
