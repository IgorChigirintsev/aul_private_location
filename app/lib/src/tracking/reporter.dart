import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:sodium/sodium.dart';
import 'package:uuid/uuid.dart';

import '../crypto/aul_crypto.dart';
import '../crypto/ping_codec.dart';
import '../data/api/api_client.dart';
import '../data/api/models.dart';
import '../data/db/queue_db.dart';
import '../domain/location_fix.dart';
import 'tracking_stats.dart';

/// A circle this device reports to, with the precision the user chose for it.
class CircleTarget {
  const CircleTarget(this.circleId, this.key, this.precision);
  final String circleId;
  final SecureKey key; // K_c
  final PrecisionMode precision;
}

/// Orchestrates the reporting pipeline: seal each fix per circle into the
/// offline queue, and flush the queue to the server in idempotent batches with
/// retry accounting. Holds no plaintext at rest — only sealed blobs are queued.
class Reporter {
  Reporter({
    required AulCrypto crypto,
    required QueueDatabase queue,
    required AulApi api,
    PingCodec? codec,
    TrackingStats? stats,
    Uuid? uuid,
  }) : _crypto = crypto,
       _queue = queue,
       _api = api,
       _codec = codec ?? PingCodec(crypto),
       stats = stats ?? TrackingStats(),
       _uuid = uuid ?? const Uuid();

  final AulCrypto _crypto;
  final QueueDatabase _queue;
  final AulApi _api;
  final PingCodec _codec;
  final Uuid _uuid;
  final TrackingStats stats;

  static const int maxBatch = 100;

  /// Seals [fix] for every non-paused [targets] circle and enqueues the sealed
  /// blobs. Returns how many pings were enqueued.
  Future<int> record(
    LocationFix fix,
    List<CircleTarget> targets, {
    int? ttlSeconds,
  }) async {
    var count = 0;
    for (final t in targets) {
      if (t.precision == PrecisionMode.paused) continue;
      final coarsened = fix.forMode(t.precision);
      final blob = _codec.seal(coarsened, t.key);
      await _queue.enqueue(
        QueuedPingsCompanion.insert(
          circleId: t.circleId,
          clientId: _uuid.v4(),
          nonce: blob.nonce,
          ciphertext: blob.ciphertext,
          capturedAt: fix.capturedAt.toUtc(),
          ttlSeconds: Value(ttlSeconds),
        ),
      );
      stats.onSealed();
      count++;
    }
    return count;
  }

  /// Flushes up to [maxBatch] queued pings to the server. On success the sent
  /// rows are deleted; on failure their retry counters are bumped and the error
  /// rethrown so the caller can back off. Returns the batch result, or null when
  /// the queue was empty.
  Future<PingBatchResult?> flush() async {
    final batch = await _queue.nextBatch(maxBatch);
    if (batch.isEmpty) return null;

    final pings = [
      for (final row in batch)
        OutgoingPing(
          circleId: row.circleId,
          clientId: row.clientId,
          nonceB64: base64.encode(row.nonce),
          ciphertextB64: base64.encode(row.ciphertext),
          capturedAt: row.capturedAt,
          ttlSeconds: row.ttlSeconds,
        ),
    ];

    try {
      final res = await _api.sendPings(pings);
      await _queue.deleteByIds(batch.map((r) => r.id).toList());
      final bytes = pings.fold<int>(
        0,
        (sum, p) => sum + p.nonceB64.length + p.ciphertextB64.length,
      );
      stats.onBatchSent(
        accepted: res.accepted,
        stored: res.stored,
        duplicate: res.duplicate,
        bytes: bytes,
        at: DateTime.now().toUtc(),
      );
      return res;
    } catch (_) {
      await _queue.bumpAttempts(batch.map((r) => r.id).toList());
      stats.onSendFailure();
      rethrow;
    }
  }

  /// Drains the queue completely (used on reconnect), stopping if a flush fails.
  Future<void> flushAll() async {
    while (await _queue.pendingCount() > 0) {
      final res = await flush();
      if (res == null) break;
    }
  }

  int get uuidV4Length => _uuid.v4().length; // exposed for tests only
  AulCrypto get crypto => _crypto;
}
