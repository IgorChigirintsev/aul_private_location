import 'package:drift/drift.dart';

part 'queue_db.g.dart';

/// A sealed ping waiting to be sent. The queue stores ONLY ciphertext (nonce +
/// sealed blob) — never plaintext coordinates — so location data is encrypted at
/// rest on the device too. One captured fix produces one row per circle.
@DataClassName('QueuedPing')
class QueuedPings extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get circleId => text()();
  TextColumn get clientId => text()(); // idempotency key (uuid)
  BlobColumn get nonce => blob()();
  BlobColumn get ciphertext => blob()();
  DateTimeColumn get capturedAt => dateTime()();
  IntColumn get ttlSeconds => integer().nullable()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

@DriftDatabase(tables: [QueuedPings])
class QueueDatabase extends _$QueueDatabase {
  QueueDatabase(super.e);

  @override
  int get schemaVersion => 1;

  Future<int> enqueue(QueuedPingsCompanion ping) =>
      into(queuedPings).insert(ping);

  /// Oldest-first batch for sending.
  Future<List<QueuedPing>> nextBatch(int limit) =>
      (select(queuedPings)
            ..orderBy([(t) => OrderingTerm(expression: t.capturedAt)])
            ..limit(limit))
          .get();

  Future<void> deleteByIds(List<int> ids) async {
    if (ids.isEmpty) return;
    await (delete(queuedPings)..where((t) => t.id.isIn(ids))).go();
  }

  /// Increments the retry counter for the given rows.
  Future<void> bumpAttempts(List<int> ids) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await customUpdate(
      'UPDATE queued_pings SET attempts = attempts + 1 WHERE id IN ($placeholders)',
      variables: ids.map(Variable.withInt).toList(),
      updates: {queuedPings},
    );
  }

  Future<int> pendingCount() => queuedPings.count().getSingle();

  /// Drops rows older than [cutoff] (e.g. beyond the max retention window) so a
  /// long-offline device never floods the server with stale, already-expired
  /// pings.
  Future<int> pruneOlderThan(DateTime cutoff) => (delete(
    queuedPings,
  )..where((t) => t.capturedAt.isSmallerThanValue(cutoff))).go();
}
