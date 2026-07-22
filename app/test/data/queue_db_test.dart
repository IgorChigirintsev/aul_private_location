import 'dart:typed_data';

import 'package:aul/src/data/db/queue_db.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

QueuedPingsCompanion _ping(String circle, String client, DateTime at) =>
    QueuedPingsCompanion.insert(
      circleId: circle,
      clientId: client,
      nonce: Uint8List.fromList([1, 2, 3]),
      ciphertext: Uint8List.fromList([4, 5, 6, 7]),
      capturedAt: at,
    );

void main() {
  late QueueDatabase db;

  setUp(() => db = QueueDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('enqueue → oldest-first batch → delete', () async {
    for (var i = 0; i < 5; i++) {
      await db.enqueue(_ping('c1', 'p$i', DateTime.utc(2026, 1, 1, 0, i)));
    }
    expect(await db.pendingCount(), 5);

    final batch = await db.nextBatch(3);
    expect(batch.map((e) => e.clientId), ['p0', 'p1', 'p2']); // oldest first

    await db.deleteByIds(batch.map((e) => e.id).toList());
    expect(await db.pendingCount(), 2);
  });

  test('bumpAttempts increments the retry counter', () async {
    final id = await db.enqueue(_ping('c1', 'x', DateTime.utc(2026, 1, 1)));
    await db.bumpAttempts([id]);
    await db.bumpAttempts([id]);
    final row = (await db.nextBatch(1)).first;
    expect(row.attempts, 2);
  });

  test('pruneOlderThan drops stale rows only', () async {
    await db.enqueue(_ping('c1', 'old', DateTime.utc(2026, 1, 1)));
    await db.enqueue(_ping('c1', 'new', DateTime.utc(2026, 6, 1)));
    final removed = await db.pruneOlderThan(DateTime.utc(2026, 3, 1));
    expect(removed, 1);
    final remaining = await db.nextBatch(10);
    expect(remaining.single.clientId, 'new');
  });

  test('empty id lists are no-ops', () async {
    await db.deleteByIds([]);
    await db.bumpAttempts([]);
    expect(await db.pendingCount(), 0);
  });
}
