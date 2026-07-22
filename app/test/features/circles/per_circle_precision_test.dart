import 'package:aul/src/controller.dart';
import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:aul/src/crypto/ping_codec.dart';
import 'package:aul/src/data/api/api_client.dart';
import 'package:aul/src/data/api/models.dart';
import 'package:aul/src/data/db/queue_db.dart';
import 'package:aul/src/data/key_vault.dart';
import 'package:aul/src/data/secret_store.dart';
import 'package:aul/src/domain/location_fix.dart';
import 'package:aul/src/tracking/reporter.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';

CircleSummary _circle(String id, PrecisionMode mode) => CircleSummary(
  id: id,
  role: 'member',
  keyEpoch: 1,
  retentionDays: 7,
  precisionMode: mode.wire,
);

/// PRECISION IS PER-CIRCLE — the property this whole feature exists for.
///
/// The chain under test is the real one: each circle's server-side
/// `precision_mode` → [resolveReportingTargets] → the real [Reporter] → the
/// sealed blobs it queues. Each blob is then opened with that circle's own key
/// and the plaintext inspected, so these assert what the CIRCLE actually
/// receives, not what the app believes it sent.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AulCrypto crypto;
  late PingCodec codec;
  late QueueDatabase db;
  late Reporter reporter;
  late Map<String, SecureKey> keys;

  setUpAll(() async {
    crypto = await AulCrypto.load();
    codec = PingCodec(crypto);
  });

  setUp(() {
    db = QueueDatabase(NativeDatabase.memory());
    reporter = Reporter(
      crypto: crypto,
      queue: db,
      // The Reporter needs an AulApi, and an AulApi needs a vault. Nothing here
      // touches the network: only `record` is exercised, and it seals into the
      // local queue without ever calling the API.
      api: AulApi(
        baseUrl: 'http://localhost:1',
        vault: KeyVault(InMemorySecretStore()),
      ),
    );
    keys = {
      'family': crypto.generateCircleKey(),
      'work': crypto.generateCircleKey(),
    };
  });

  tearDown(() async {
    for (final k in keys.values) {
      k.dispose();
    }
    await db.close();
  });

  /// The fix the phone actually samples: precise, because some circle wants it
  /// precise. Coarsening happens per circle, on the way out.
  final fix = LocationFix(
    lat: 43.238949,
    lng: 76.889709,
    accuracy: 8,
    speed: 3.5,
    heading: 90,
    battery: 64,
    capturedAt: DateTime.utc(2026, 7, 15, 12),
  );

  /// Seals [fix] for [circles] exactly as the app does, then opens each queued
  /// blob with its own circle key. Returns circleId → the plaintext that circle
  /// receives.
  Future<Map<String, LocationFix>> sealFor(
    List<CircleSummary> circles, {
    PrecisionMode? override,
  }) async {
    final targets = [
      for (final t in resolveReportingTargets(circles, override: override))
        CircleTarget(t.circleId, keys[t.circleId]!, t.precision),
    ];
    await reporter.record(fix, targets);
    final out = <String, LocationFix>{};
    for (final row in await db.nextBatch(100)) {
      // Opened with THAT circle's key: a blob sealed for one circle must not be
      // readable with another's, so this also proves they were sealed separately.
      final opened = codec.open(row.nonce, row.ciphertext, keys[row.circleId]!);
      out[row.circleId] = opened;
    }
    return out;
  }

  test(
    'two circles on different modes: each gets a ping sealed at ITS OWN mode',
    () async {
      final received = await sealFor([
        _circle('family', PrecisionMode.precise),
        _circle('work', PrecisionMode.city),
      ]);

      expect(received.keys, unorderedEquals(['family', 'work']));

      // Family asked for precise, and gets the exact spot.
      final family = received['family']!;
      expect(family.mode, PrecisionMode.precise);
      expect(family.lat, closeTo(43.238949, 1e-9));
      expect(family.lng, closeTo(76.889709, 1e-9));

      // Work asked for city, and gets a ~1 km grid square — from the SAME sample,
      // in the same instant. This is the arrangement that was unreachable before:
      // one control set one mode for everybody.
      final work = received['work']!;
      expect(work.mode, PrecisionMode.city);
      expect(work.lat, closeTo(43.24, 1e-9));
      expect(work.lng, closeTo(76.89, 1e-9));
      expect(work.speed, isNull, reason: 'city drops movement detail');
      expect(work.heading, isNull);
      expect(work.accuracy, greaterThanOrEqualTo(1000));

      // The city circle genuinely cannot recover the precise position: the
      // coarsening happened BEFORE sealing, so it is not a display choice the
      // recipient could undo.
      expect((work.lat - family.lat).abs(), greaterThan(1e-6));
    },
  );

  test(
    'a paused circle receives nothing, while the others still report',
    () async {
      final received = await sealFor([
        _circle('family', PrecisionMode.precise),
        _circle('work', PrecisionMode.paused),
      ]);

      expect(received.keys, ['family']);
      expect(
        received['work'],
        isNull,
        reason: 'paused means no ping is sealed for that circle at all',
      );
      // Pausing one circle must not disturb another's.
      expect(received['family']!.mode, PrecisionMode.precise);
    },
  );

  test('every circle paused ⇒ nothing is sealed for anyone', () async {
    final received = await sealFor([
      _circle('family', PrecisionMode.paused),
      _circle('work', PrecisionMode.paused),
    ]);
    expect(received, isEmpty);
    // ...and the sampler is then told there is nothing to sample for.
    expect(
      samplingPrecision([PrecisionMode.paused, PrecisionMode.paused]),
      PrecisionMode.paused,
    );
  });

  test('an SOS override beats BOTH circles — including the paused one', () async {
    final received = await sealFor([
      _circle('family', PrecisionMode.city),
      _circle('work', PrecisionMode.paused),
    ], override: PrecisionMode.precise);

    // The alert went to every circle, so every circle gets a location good enough
    // to act on — the city circle is sharpened, and the paused one is un-paused
    // for the emergency.
    expect(received.keys, unorderedEquals(['family', 'work']));
    for (final circle in ['family', 'work']) {
      expect(received[circle]!.mode, PrecisionMode.precise, reason: circle);
      expect(received[circle]!.lat, closeTo(43.238949, 1e-9), reason: circle);
    }
  });

  group('target resolution', () {
    test('each target carries its own circle mode, paused ones included', () {
      final targets = resolveReportingTargets([
        _circle('family', PrecisionMode.precise),
        _circle('work', PrecisionMode.city),
        _circle('friends', PrecisionMode.paused),
      ]);
      expect(targets, [
        (circleId: 'family', precision: PrecisionMode.precise),
        (circleId: 'work', precision: PrecisionMode.city),
        // Carried, not dropped: the reporter must be told to skip it, not left
        // to guess from its absence.
        (circleId: 'friends', precision: PrecisionMode.paused),
      ]);
    });

    test('an unknown mode from a newer server falls back to precise', () {
      // fromWire's fallback. Precise is the safe default here only because it
      // over-shares to a circle the user already chose to be in; the alternative
      // (silently pausing) would make the app claim to share and not.
      final targets = resolveReportingTargets([
        CircleSummary(
          id: 'c',
          role: 'member',
          keyEpoch: 1,
          retentionDays: 7,
          precisionMode: 'blockwise',
        ),
      ]);
      expect(targets.single.precision, PrecisionMode.precise);
    });
  });

  group(
    'sampling precision — the one stream must satisfy the finest circle',
    () {
      test('any precise circle ⇒ sample precise', () {
        expect(
          samplingPrecision([PrecisionMode.city, PrecisionMode.precise]),
          PrecisionMode.precise,
        );
      });

      test('city + paused ⇒ sample city (nobody needs better)', () {
        expect(
          samplingPrecision([PrecisionMode.city, PrecisionMode.paused]),
          PrecisionMode.city,
        );
      });

      test('no circles at all ⇒ paused: hold no GPS for nobody', () {
        expect(samplingPrecision(const []), PrecisionMode.paused);
      });
    },
  );
}
