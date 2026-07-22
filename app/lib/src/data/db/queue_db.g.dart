// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'queue_db.dart';

// ignore_for_file: type=lint
class $QueuedPingsTable extends QueuedPings
    with TableInfo<$QueuedPingsTable, QueuedPing> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $QueuedPingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _circleIdMeta = const VerificationMeta(
    'circleId',
  );
  @override
  late final GeneratedColumn<String> circleId = GeneratedColumn<String>(
    'circle_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _clientIdMeta = const VerificationMeta(
    'clientId',
  );
  @override
  late final GeneratedColumn<String> clientId = GeneratedColumn<String>(
    'client_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nonceMeta = const VerificationMeta('nonce');
  @override
  late final GeneratedColumn<Uint8List> nonce = GeneratedColumn<Uint8List>(
    'nonce',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _ciphertextMeta = const VerificationMeta(
    'ciphertext',
  );
  @override
  late final GeneratedColumn<Uint8List> ciphertext = GeneratedColumn<Uint8List>(
    'ciphertext',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _capturedAtMeta = const VerificationMeta(
    'capturedAt',
  );
  @override
  late final GeneratedColumn<DateTime> capturedAt = GeneratedColumn<DateTime>(
    'captured_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _ttlSecondsMeta = const VerificationMeta(
    'ttlSeconds',
  );
  @override
  late final GeneratedColumn<int> ttlSeconds = GeneratedColumn<int>(
    'ttl_seconds',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _attemptsMeta = const VerificationMeta(
    'attempts',
  );
  @override
  late final GeneratedColumn<int> attempts = GeneratedColumn<int>(
    'attempts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    circleId,
    clientId,
    nonce,
    ciphertext,
    capturedAt,
    ttlSeconds,
    attempts,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'queued_pings';
  @override
  VerificationContext validateIntegrity(
    Insertable<QueuedPing> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('circle_id')) {
      context.handle(
        _circleIdMeta,
        circleId.isAcceptableOrUnknown(data['circle_id']!, _circleIdMeta),
      );
    } else if (isInserting) {
      context.missing(_circleIdMeta);
    }
    if (data.containsKey('client_id')) {
      context.handle(
        _clientIdMeta,
        clientId.isAcceptableOrUnknown(data['client_id']!, _clientIdMeta),
      );
    } else if (isInserting) {
      context.missing(_clientIdMeta);
    }
    if (data.containsKey('nonce')) {
      context.handle(
        _nonceMeta,
        nonce.isAcceptableOrUnknown(data['nonce']!, _nonceMeta),
      );
    } else if (isInserting) {
      context.missing(_nonceMeta);
    }
    if (data.containsKey('ciphertext')) {
      context.handle(
        _ciphertextMeta,
        ciphertext.isAcceptableOrUnknown(data['ciphertext']!, _ciphertextMeta),
      );
    } else if (isInserting) {
      context.missing(_ciphertextMeta);
    }
    if (data.containsKey('captured_at')) {
      context.handle(
        _capturedAtMeta,
        capturedAt.isAcceptableOrUnknown(data['captured_at']!, _capturedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_capturedAtMeta);
    }
    if (data.containsKey('ttl_seconds')) {
      context.handle(
        _ttlSecondsMeta,
        ttlSeconds.isAcceptableOrUnknown(data['ttl_seconds']!, _ttlSecondsMeta),
      );
    }
    if (data.containsKey('attempts')) {
      context.handle(
        _attemptsMeta,
        attempts.isAcceptableOrUnknown(data['attempts']!, _attemptsMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  QueuedPing map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return QueuedPing(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      circleId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}circle_id'],
      )!,
      clientId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}client_id'],
      )!,
      nonce: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}nonce'],
      )!,
      ciphertext: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}ciphertext'],
      )!,
      capturedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}captured_at'],
      )!,
      ttlSeconds: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}ttl_seconds'],
      ),
      attempts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempts'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $QueuedPingsTable createAlias(String alias) {
    return $QueuedPingsTable(attachedDatabase, alias);
  }
}

class QueuedPing extends DataClass implements Insertable<QueuedPing> {
  final int id;
  final String circleId;
  final String clientId;
  final Uint8List nonce;
  final Uint8List ciphertext;
  final DateTime capturedAt;
  final int? ttlSeconds;
  final int attempts;
  final DateTime createdAt;
  const QueuedPing({
    required this.id,
    required this.circleId,
    required this.clientId,
    required this.nonce,
    required this.ciphertext,
    required this.capturedAt,
    this.ttlSeconds,
    required this.attempts,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['circle_id'] = Variable<String>(circleId);
    map['client_id'] = Variable<String>(clientId);
    map['nonce'] = Variable<Uint8List>(nonce);
    map['ciphertext'] = Variable<Uint8List>(ciphertext);
    map['captured_at'] = Variable<DateTime>(capturedAt);
    if (!nullToAbsent || ttlSeconds != null) {
      map['ttl_seconds'] = Variable<int>(ttlSeconds);
    }
    map['attempts'] = Variable<int>(attempts);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  QueuedPingsCompanion toCompanion(bool nullToAbsent) {
    return QueuedPingsCompanion(
      id: Value(id),
      circleId: Value(circleId),
      clientId: Value(clientId),
      nonce: Value(nonce),
      ciphertext: Value(ciphertext),
      capturedAt: Value(capturedAt),
      ttlSeconds: ttlSeconds == null && nullToAbsent
          ? const Value.absent()
          : Value(ttlSeconds),
      attempts: Value(attempts),
      createdAt: Value(createdAt),
    );
  }

  factory QueuedPing.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return QueuedPing(
      id: serializer.fromJson<int>(json['id']),
      circleId: serializer.fromJson<String>(json['circleId']),
      clientId: serializer.fromJson<String>(json['clientId']),
      nonce: serializer.fromJson<Uint8List>(json['nonce']),
      ciphertext: serializer.fromJson<Uint8List>(json['ciphertext']),
      capturedAt: serializer.fromJson<DateTime>(json['capturedAt']),
      ttlSeconds: serializer.fromJson<int?>(json['ttlSeconds']),
      attempts: serializer.fromJson<int>(json['attempts']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'circleId': serializer.toJson<String>(circleId),
      'clientId': serializer.toJson<String>(clientId),
      'nonce': serializer.toJson<Uint8List>(nonce),
      'ciphertext': serializer.toJson<Uint8List>(ciphertext),
      'capturedAt': serializer.toJson<DateTime>(capturedAt),
      'ttlSeconds': serializer.toJson<int?>(ttlSeconds),
      'attempts': serializer.toJson<int>(attempts),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  QueuedPing copyWith({
    int? id,
    String? circleId,
    String? clientId,
    Uint8List? nonce,
    Uint8List? ciphertext,
    DateTime? capturedAt,
    Value<int?> ttlSeconds = const Value.absent(),
    int? attempts,
    DateTime? createdAt,
  }) => QueuedPing(
    id: id ?? this.id,
    circleId: circleId ?? this.circleId,
    clientId: clientId ?? this.clientId,
    nonce: nonce ?? this.nonce,
    ciphertext: ciphertext ?? this.ciphertext,
    capturedAt: capturedAt ?? this.capturedAt,
    ttlSeconds: ttlSeconds.present ? ttlSeconds.value : this.ttlSeconds,
    attempts: attempts ?? this.attempts,
    createdAt: createdAt ?? this.createdAt,
  );
  QueuedPing copyWithCompanion(QueuedPingsCompanion data) {
    return QueuedPing(
      id: data.id.present ? data.id.value : this.id,
      circleId: data.circleId.present ? data.circleId.value : this.circleId,
      clientId: data.clientId.present ? data.clientId.value : this.clientId,
      nonce: data.nonce.present ? data.nonce.value : this.nonce,
      ciphertext: data.ciphertext.present
          ? data.ciphertext.value
          : this.ciphertext,
      capturedAt: data.capturedAt.present
          ? data.capturedAt.value
          : this.capturedAt,
      ttlSeconds: data.ttlSeconds.present
          ? data.ttlSeconds.value
          : this.ttlSeconds,
      attempts: data.attempts.present ? data.attempts.value : this.attempts,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('QueuedPing(')
          ..write('id: $id, ')
          ..write('circleId: $circleId, ')
          ..write('clientId: $clientId, ')
          ..write('nonce: $nonce, ')
          ..write('ciphertext: $ciphertext, ')
          ..write('capturedAt: $capturedAt, ')
          ..write('ttlSeconds: $ttlSeconds, ')
          ..write('attempts: $attempts, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    circleId,
    clientId,
    $driftBlobEquality.hash(nonce),
    $driftBlobEquality.hash(ciphertext),
    capturedAt,
    ttlSeconds,
    attempts,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is QueuedPing &&
          other.id == this.id &&
          other.circleId == this.circleId &&
          other.clientId == this.clientId &&
          $driftBlobEquality.equals(other.nonce, this.nonce) &&
          $driftBlobEquality.equals(other.ciphertext, this.ciphertext) &&
          other.capturedAt == this.capturedAt &&
          other.ttlSeconds == this.ttlSeconds &&
          other.attempts == this.attempts &&
          other.createdAt == this.createdAt);
}

class QueuedPingsCompanion extends UpdateCompanion<QueuedPing> {
  final Value<int> id;
  final Value<String> circleId;
  final Value<String> clientId;
  final Value<Uint8List> nonce;
  final Value<Uint8List> ciphertext;
  final Value<DateTime> capturedAt;
  final Value<int?> ttlSeconds;
  final Value<int> attempts;
  final Value<DateTime> createdAt;
  const QueuedPingsCompanion({
    this.id = const Value.absent(),
    this.circleId = const Value.absent(),
    this.clientId = const Value.absent(),
    this.nonce = const Value.absent(),
    this.ciphertext = const Value.absent(),
    this.capturedAt = const Value.absent(),
    this.ttlSeconds = const Value.absent(),
    this.attempts = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  QueuedPingsCompanion.insert({
    this.id = const Value.absent(),
    required String circleId,
    required String clientId,
    required Uint8List nonce,
    required Uint8List ciphertext,
    required DateTime capturedAt,
    this.ttlSeconds = const Value.absent(),
    this.attempts = const Value.absent(),
    this.createdAt = const Value.absent(),
  }) : circleId = Value(circleId),
       clientId = Value(clientId),
       nonce = Value(nonce),
       ciphertext = Value(ciphertext),
       capturedAt = Value(capturedAt);
  static Insertable<QueuedPing> custom({
    Expression<int>? id,
    Expression<String>? circleId,
    Expression<String>? clientId,
    Expression<Uint8List>? nonce,
    Expression<Uint8List>? ciphertext,
    Expression<DateTime>? capturedAt,
    Expression<int>? ttlSeconds,
    Expression<int>? attempts,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (circleId != null) 'circle_id': circleId,
      if (clientId != null) 'client_id': clientId,
      if (nonce != null) 'nonce': nonce,
      if (ciphertext != null) 'ciphertext': ciphertext,
      if (capturedAt != null) 'captured_at': capturedAt,
      if (ttlSeconds != null) 'ttl_seconds': ttlSeconds,
      if (attempts != null) 'attempts': attempts,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  QueuedPingsCompanion copyWith({
    Value<int>? id,
    Value<String>? circleId,
    Value<String>? clientId,
    Value<Uint8List>? nonce,
    Value<Uint8List>? ciphertext,
    Value<DateTime>? capturedAt,
    Value<int?>? ttlSeconds,
    Value<int>? attempts,
    Value<DateTime>? createdAt,
  }) {
    return QueuedPingsCompanion(
      id: id ?? this.id,
      circleId: circleId ?? this.circleId,
      clientId: clientId ?? this.clientId,
      nonce: nonce ?? this.nonce,
      ciphertext: ciphertext ?? this.ciphertext,
      capturedAt: capturedAt ?? this.capturedAt,
      ttlSeconds: ttlSeconds ?? this.ttlSeconds,
      attempts: attempts ?? this.attempts,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (circleId.present) {
      map['circle_id'] = Variable<String>(circleId.value);
    }
    if (clientId.present) {
      map['client_id'] = Variable<String>(clientId.value);
    }
    if (nonce.present) {
      map['nonce'] = Variable<Uint8List>(nonce.value);
    }
    if (ciphertext.present) {
      map['ciphertext'] = Variable<Uint8List>(ciphertext.value);
    }
    if (capturedAt.present) {
      map['captured_at'] = Variable<DateTime>(capturedAt.value);
    }
    if (ttlSeconds.present) {
      map['ttl_seconds'] = Variable<int>(ttlSeconds.value);
    }
    if (attempts.present) {
      map['attempts'] = Variable<int>(attempts.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('QueuedPingsCompanion(')
          ..write('id: $id, ')
          ..write('circleId: $circleId, ')
          ..write('clientId: $clientId, ')
          ..write('nonce: $nonce, ')
          ..write('ciphertext: $ciphertext, ')
          ..write('capturedAt: $capturedAt, ')
          ..write('ttlSeconds: $ttlSeconds, ')
          ..write('attempts: $attempts, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$QueueDatabase extends GeneratedDatabase {
  _$QueueDatabase(QueryExecutor e) : super(e);
  $QueueDatabaseManager get managers => $QueueDatabaseManager(this);
  late final $QueuedPingsTable queuedPings = $QueuedPingsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [queuedPings];
}

typedef $$QueuedPingsTableCreateCompanionBuilder =
    QueuedPingsCompanion Function({
      Value<int> id,
      required String circleId,
      required String clientId,
      required Uint8List nonce,
      required Uint8List ciphertext,
      required DateTime capturedAt,
      Value<int?> ttlSeconds,
      Value<int> attempts,
      Value<DateTime> createdAt,
    });
typedef $$QueuedPingsTableUpdateCompanionBuilder =
    QueuedPingsCompanion Function({
      Value<int> id,
      Value<String> circleId,
      Value<String> clientId,
      Value<Uint8List> nonce,
      Value<Uint8List> ciphertext,
      Value<DateTime> capturedAt,
      Value<int?> ttlSeconds,
      Value<int> attempts,
      Value<DateTime> createdAt,
    });

class $$QueuedPingsTableFilterComposer
    extends Composer<_$QueueDatabase, $QueuedPingsTable> {
  $$QueuedPingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get circleId => $composableBuilder(
    column: $table.circleId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get clientId => $composableBuilder(
    column: $table.clientId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get nonce => $composableBuilder(
    column: $table.nonce,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get ciphertext => $composableBuilder(
    column: $table.ciphertext,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get capturedAt => $composableBuilder(
    column: $table.capturedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get ttlSeconds => $composableBuilder(
    column: $table.ttlSeconds,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$QueuedPingsTableOrderingComposer
    extends Composer<_$QueueDatabase, $QueuedPingsTable> {
  $$QueuedPingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get circleId => $composableBuilder(
    column: $table.circleId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get clientId => $composableBuilder(
    column: $table.clientId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get nonce => $composableBuilder(
    column: $table.nonce,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get ciphertext => $composableBuilder(
    column: $table.ciphertext,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get capturedAt => $composableBuilder(
    column: $table.capturedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get ttlSeconds => $composableBuilder(
    column: $table.ttlSeconds,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$QueuedPingsTableAnnotationComposer
    extends Composer<_$QueueDatabase, $QueuedPingsTable> {
  $$QueuedPingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get circleId =>
      $composableBuilder(column: $table.circleId, builder: (column) => column);

  GeneratedColumn<String> get clientId =>
      $composableBuilder(column: $table.clientId, builder: (column) => column);

  GeneratedColumn<Uint8List> get nonce =>
      $composableBuilder(column: $table.nonce, builder: (column) => column);

  GeneratedColumn<Uint8List> get ciphertext => $composableBuilder(
    column: $table.ciphertext,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get capturedAt => $composableBuilder(
    column: $table.capturedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get ttlSeconds => $composableBuilder(
    column: $table.ttlSeconds,
    builder: (column) => column,
  );

  GeneratedColumn<int> get attempts =>
      $composableBuilder(column: $table.attempts, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$QueuedPingsTableTableManager
    extends
        RootTableManager<
          _$QueueDatabase,
          $QueuedPingsTable,
          QueuedPing,
          $$QueuedPingsTableFilterComposer,
          $$QueuedPingsTableOrderingComposer,
          $$QueuedPingsTableAnnotationComposer,
          $$QueuedPingsTableCreateCompanionBuilder,
          $$QueuedPingsTableUpdateCompanionBuilder,
          (
            QueuedPing,
            BaseReferences<_$QueueDatabase, $QueuedPingsTable, QueuedPing>,
          ),
          QueuedPing,
          PrefetchHooks Function()
        > {
  $$QueuedPingsTableTableManager(_$QueueDatabase db, $QueuedPingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$QueuedPingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$QueuedPingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$QueuedPingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> circleId = const Value.absent(),
                Value<String> clientId = const Value.absent(),
                Value<Uint8List> nonce = const Value.absent(),
                Value<Uint8List> ciphertext = const Value.absent(),
                Value<DateTime> capturedAt = const Value.absent(),
                Value<int?> ttlSeconds = const Value.absent(),
                Value<int> attempts = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => QueuedPingsCompanion(
                id: id,
                circleId: circleId,
                clientId: clientId,
                nonce: nonce,
                ciphertext: ciphertext,
                capturedAt: capturedAt,
                ttlSeconds: ttlSeconds,
                attempts: attempts,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String circleId,
                required String clientId,
                required Uint8List nonce,
                required Uint8List ciphertext,
                required DateTime capturedAt,
                Value<int?> ttlSeconds = const Value.absent(),
                Value<int> attempts = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => QueuedPingsCompanion.insert(
                id: id,
                circleId: circleId,
                clientId: clientId,
                nonce: nonce,
                ciphertext: ciphertext,
                capturedAt: capturedAt,
                ttlSeconds: ttlSeconds,
                attempts: attempts,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$QueuedPingsTableProcessedTableManager =
    ProcessedTableManager<
      _$QueueDatabase,
      $QueuedPingsTable,
      QueuedPing,
      $$QueuedPingsTableFilterComposer,
      $$QueuedPingsTableOrderingComposer,
      $$QueuedPingsTableAnnotationComposer,
      $$QueuedPingsTableCreateCompanionBuilder,
      $$QueuedPingsTableUpdateCompanionBuilder,
      (
        QueuedPing,
        BaseReferences<_$QueueDatabase, $QueuedPingsTable, QueuedPing>,
      ),
      QueuedPing,
      PrefetchHooks Function()
    >;

class $QueueDatabaseManager {
  final _$QueueDatabase _db;
  $QueueDatabaseManager(this._db);
  $$QueuedPingsTableTableManager get queuedPings =>
      $$QueuedPingsTableTableManager(_db, _db.queuedPings);
}
