import 'package:aul/src/domain/location_fix.dart';
import 'package:aul/src/features/retention/background_arrival.dart';
import 'package:aul/src/features/retention/background_reengage.dart';
import 'package:aul/src/features/share/background_shares.dart';
import 'package:aul/src/platform/background_service.dart';
import 'package:aul/src/tracking/reporter.dart';
import 'package:aul/src/tracking/tracking_stats.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';

/// A stand-in K_c. The gate runs BEFORE any sealing, and the fake reporter never
/// touches the key, so this test needs the TYPE but not a sodium runtime.
class _FakeKey implements SecureKey {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Captures what the background isolate would have SEALED, without a queue, a
/// key, or a network. The gate + timestamp handling are the behaviour under
/// test; the crypto has its own tests.
class _RecordingReporter implements Reporter {
  final List<LocationFix> recorded = [];

  @override
  final TrackingStats stats = TrackingStats();

  @override
  Future<int> record(
    LocationFix fix,
    List<CircleTarget> targets, {
    int? ttlSeconds,
  }) async {
    recorded.add(fix);
    return targets.length;
  }

  @override
  Future<void> flushAll() async {}

  // Everything else on Reporter is unused by this path.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Captures which fixes reached the geofence evaluation. The crossing logic
/// itself is tested in features/retention/background_arrival_test.dart; what
/// matters here is WHICH fixes the reporter hands it, and that a failure in it
/// never costs the circle a location.
class _RecordingArrival implements FixCrossingEvaluator {
  _RecordingArrival({this.throws = false});

  final bool throws;
  final List<LocationFix> seen = [];

  @override
  Future<void> onFix(LocationFix fix) async {
    seen.add(fix);
    if (throws) throw StateError('no notification plugin in this isolate');
  }
}

/// Captures which fixes reached the live-share feed, and in what shape. The
/// sealing and the deadline live in features/share/background_shares_test.dart;
/// what matters here is WHICH fixes get there and what state they are in.
class _RecordingShares implements FixShareFeeder {
  _RecordingShares({this.throws = false});

  final bool throws;
  final List<LocationFix> fed = [];

  @override
  Future<void> onFix(LocationFix fix) async {
    fed.add(fix);
    if (throws) throw StateError('the share server is unreachable');
  }
}

/// Captures which fixes reached the low-battery reminder.
class _RecordingReengage implements FixBatteryWatcher {
  final List<LocationFix> seen = [];

  @override
  Future<void> onFix(LocationFix fix) async => seen.add(fix);
}

/// The native service's payload for a fix. `ts` is the PLATFORM's fix time
/// (Location.time), which is the whole point of the assertions below.
Map<String, dynamic> nativeFix({
  required int tsMillis,
  double lat = 51.5,
  double lng = -0.1,
  double? acc,
  int? batt,
}) => {'lat': lat, 'lng': lng, 'acc': ?acc, 'batt': ?batt, 'ts': tsMillis};

void main() {
  late _RecordingReporter reporter;
  late BackgroundReporter bg;

  // A target list of one; the precision coarsening has its own tests.
  setUp(() {
    reporter = _RecordingReporter();
    bg = BackgroundReporter(
      reporter: reporter,
      targets: [CircleTarget('c1', _FakeKey(), PrecisionMode.precise)],
      channel: const MethodChannel('app.aul/bg-test'),
    );
  });

  Future<void> deliver(Map<String, dynamic> payload) =>
      bg.handle(MethodCall('onLocation', payload));

  test(
    'the platform fix time is carried through, never re-stamped as now',
    () async {
      // A fix the provider timed 10 minutes ago (a cached/settling fix) must reach
      // the seal claiming ITS OWN time. Stamping DateTime.now() here would relabel
      // a ten-minute-old position "just now" — the exact lie the web told.
      final platformTime = DateTime.utc(2026, 7, 15, 11, 50);
      await deliver(nativeFix(tsMillis: platformTime.millisecondsSinceEpoch));

      expect(reporter.recorded, hasLength(1));
      expect(reporter.recorded.single.capturedAt.toUtc(), platformTime);
    },
  );

  test(
    'a stationary device still reports: repeat fixes at one spot all seal',
    () async {
      // The re-ask loop hands the same coordinates back every interval while the
      // phone sits on a table. Nothing in the Dart path may swallow those as
      // "unchanged" — a marker that stops refreshing is a marker that is lying by
      // the time it matters. Each carries its own, advancing platform time.
      final t0 = DateTime.utc(2026, 7, 15, 12);
      for (var i = 0; i < 3; i++) {
        await deliver(
          nativeFix(
            tsMillis: t0.add(Duration(minutes: 2 * i)).millisecondsSinceEpoch,
            acc: 12,
          ),
        );
      }

      expect(reporter.recorded, hasLength(3));
      expect(
        reporter.recorded.map((f) => f.capturedAt.toUtc()),
        [
          t0,
          t0.add(const Duration(minutes: 2)),
          t0.add(const Duration(minutes: 4)),
        ],
        reason: 'each refresh reports its own capture time',
      );
    },
  );

  test('a much vaguer fix does not replace a sharp, current one', () async {
    final t0 = DateTime.utc(2026, 7, 15, 12);
    await deliver(nativeFix(tsMillis: t0.millisecondsSinceEpoch, acc: 8));
    // The network estimate that would yank the pin a couple of blocks away.
    await deliver(
      nativeFix(
        tsMillis: t0.add(const Duration(seconds: 5)).millisecondsSinceEpoch,
        lat: 51.52,
        acc: 500,
      ),
    );

    expect(reporter.recorded, hasLength(1));
    expect(reporter.recorded.single.accuracy, 8);
  });

  test('a vaguer fix is sealed once the sharp one has gone stale', () async {
    final t0 = DateTime.utc(2026, 7, 15, 12);
    await deliver(nativeFix(tsMillis: t0.millisecondsSinceEpoch, acc: 8));
    await deliver(
      nativeFix(
        tsMillis: t0.add(const Duration(seconds: 91)).millisecondsSinceEpoch,
        acc: 500,
      ),
    );

    expect(reporter.recorded, hasLength(2));
    expect(reporter.recorded.last.accuracy, 500);
  });

  test(
    'a rejected fix still counts as a wake (battery accounting stays honest)',
    () async {
      final t0 = DateTime.utc(2026, 7, 15, 12);
      await deliver(nativeFix(tsMillis: t0.millisecondsSinceEpoch, acc: 8));
      await deliver(
        nativeFix(
          tsMillis: t0.add(const Duration(seconds: 5)).millisecondsSinceEpoch,
          acc: 900,
        ),
      );

      expect(reporter.recorded, hasLength(1));
      expect(reporter.stats.locationWakes, 2);
    },
  );

  test('crossings are evaluated on the RAW, gate-accepted fix', () async {
    final arrival = _RecordingArrival();
    final bg2 = BackgroundReporter(
      reporter: reporter,
      // A CITY-precision circle: what the circle is told is coarsened to a ~1 km
      // grid, but the geofence must still see the real coordinate. Blurring the
      // input to a local fence would just make it wrong — a city-grid point lands
      // several fence radii from the house.
      targets: [CircleTarget('c1', _FakeKey(), PrecisionMode.city)],
      channel: const MethodChannel('app.aul/bg-test'),
      arrival: arrival,
    );
    final t0 = DateTime.utc(2026, 7, 15, 12);
    await bg2.handle(
      MethodCall(
        'onLocation',
        nativeFix(
          tsMillis: t0.millisecondsSinceEpoch,
          lat: 43.2,
          lng: 76.8,
          acc: 8,
        ),
      ),
    );

    expect(arrival.seen, hasLength(1));
    expect(arrival.seen.single.lat, 43.2, reason: 'raw, never forMode()d');
    expect(arrival.seen.single.lng, 76.8);
    expect(arrival.seen.single.capturedAt.toUtc(), t0);

    // The vague network estimate the gate rejects must not reach the geofence
    // either: a fix that would yank the pin across town would just as happily
    // invent an arrival and a departure.
    await bg2.handle(
      MethodCall(
        'onLocation',
        nativeFix(
          tsMillis: t0.add(const Duration(seconds: 5)).millisecondsSinceEpoch,
          lat: 43.25,
          acc: 900,
        ),
      ),
    );
    expect(arrival.seen, hasLength(1), reason: 'the gate rejected it');
  });

  test('a failing geofence evaluation never costs the circle a fix', () async {
    // Reporting is the feature people's safety rests on; an arrival alert is
    // not. A missing notification plugin in this isolate must not stop the
    // position reaching the circle.
    final bg2 = BackgroundReporter(
      reporter: reporter,
      targets: [CircleTarget('c1', _FakeKey(), PrecisionMode.precise)],
      channel: const MethodChannel('app.aul/bg-test'),
      arrival: _RecordingArrival(throws: true),
    );
    await bg2.handle(
      MethodCall('onLocation', nativeFix(tsMillis: 1752580000000, acc: 10)),
    );
    expect(reporter.recorded, hasLength(1));
  });

  test('no targets means nothing is sealed', () async {
    final bare = BackgroundReporter(
      reporter: reporter,
      channel: const MethodChannel('app.aul/bg-test'),
    );
    await bare.handle(
      MethodCall('onLocation', nativeFix(tsMillis: 1752580000000)),
    );
    expect(reporter.recorded, isEmpty);
  });

  // --- live share ---

  test(
    'a live share is fed the RAW fix while the circle is in CITY mode',
    () async {
      // The bar this feature is defined by. A share is its own opt-in with its
      // own key, and the circle's precision has no say over a link the user made
      // deliberately: the circle gets a ~1 km grid square, the link holder gets
      // where the user actually is.
      final feed = _RecordingShares();
      final bg2 = BackgroundReporter(
        reporter: reporter,
        targets: [CircleTarget('c1', _FakeKey(), PrecisionMode.city)],
        channel: const MethodChannel('app.aul/bg-test'),
        shares: feed,
      );
      await bg2.handle(
        MethodCall(
          'onLocation',
          nativeFix(
            tsMillis: DateTime.utc(2026, 7, 15, 12).millisecondsSinceEpoch,
            lat: 43.238949,
            lng: 76.889709,
            acc: 8,
          ),
        ),
      );

      expect(feed.fed, hasLength(1));
      expect(feed.fed.single.lat, 43.238949, reason: 'raw, never forMode()d');
      expect(feed.fed.single.lng, 76.889709);
      expect(feed.fed.single.mode, PrecisionMode.precise);
      // The coarsening the circle DOES get happens downstream, in the reporter,
      // against K_c — the fix handed to the share never passes through it.
      expect(reporter.recorded.single.lat, 43.238949);
    },
  );

  test('a live share is fed even when NO circle is reported to', () async {
    // Circle paused, or no circle at all, or reporting stopped: the share runs
    // off its own key and its own deadline. This is the path that used to be cut
    // off entirely — the fix path returned early when there were no targets.
    final feed = _RecordingShares();
    final bare = BackgroundReporter(
      reporter: reporter,
      channel: const MethodChannel('app.aul/bg-test'),
      shares: feed,
    );
    await bare.handle(
      MethodCall('onLocation', nativeFix(tsMillis: 1752580000000, acc: 10)),
    );

    expect(reporter.recorded, isEmpty, reason: 'nothing for the circle');
    expect(feed.fed, hasLength(1), reason: 'but the link is still fed');
  });

  test('a failing share feed never costs the circle a fix', () async {
    final bg2 = BackgroundReporter(
      reporter: reporter,
      targets: [CircleTarget('c1', _FakeKey(), PrecisionMode.precise)],
      channel: const MethodChannel('app.aul/bg-test'),
      shares: _RecordingShares(throws: true),
    );
    await bg2.handle(
      MethodCall('onLocation', nativeFix(tsMillis: 1752580000000, acc: 10)),
    );
    expect(reporter.recorded, hasLength(1));
  });

  test('a gate-rejected fix is not fed to a share either', () async {
    // A vague network estimate would yank a watcher's dot across town exactly as
    // it would the circle's pin.
    final feed = _RecordingShares();
    final bg2 = BackgroundReporter(
      reporter: reporter,
      channel: const MethodChannel('app.aul/bg-test'),
      shares: feed,
    );
    final t0 = DateTime.utc(2026, 7, 15, 12);
    await bg2.handle(
      MethodCall(
        'onLocation',
        nativeFix(tsMillis: t0.millisecondsSinceEpoch, acc: 8),
      ),
    );
    await bg2.handle(
      MethodCall(
        'onLocation',
        nativeFix(
          tsMillis: t0.add(const Duration(seconds: 5)).millisecondsSinceEpoch,
          lat: 51.52,
          acc: 900,
        ),
      ),
    );
    expect(feed.fed, hasLength(1));
  });

  // --- low-battery reminder ---

  test('the battery level reaches the reminder, from the isolate', () async {
    // The reminder can only run here: `batt` rides on the fix, and the fix only
    // ever lands in this isolate. Hanging it off a foreground handler is what
    // stopped it firing for its whole shipped life.
    final reengage = _RecordingReengage();
    final bg2 = BackgroundReporter(
      reporter: reporter,
      targets: [CircleTarget('c1', _FakeKey(), PrecisionMode.precise)],
      channel: const MethodChannel('app.aul/bg-test'),
      reengage: reengage,
    );
    await bg2.handle(
      MethodCall(
        'onLocation',
        nativeFix(tsMillis: 1752580000000, acc: 10, batt: 7),
      ),
    );

    expect(reengage.seen, hasLength(1));
    expect(reengage.seen.single.battery, 7);
  });

  test('the reminder runs with no circle to report to', () async {
    // Sharing paused is exactly when a dying battery is worth mentioning, and it
    // is also when there are no targets.
    final reengage = _RecordingReengage();
    final bare = BackgroundReporter(
      reporter: reporter,
      channel: const MethodChannel('app.aul/bg-test'),
      reengage: reengage,
    );
    await bare.handle(
      MethodCall(
        'onLocation',
        nativeFix(tsMillis: 1752580000000, acc: 10, batt: 4),
      ),
    );
    expect(reengage.seen, hasLength(1));
  });
}
