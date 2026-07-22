import 'package:aul/src/domain/location_fix.dart';
import 'package:aul/src/features/map/member_positions.dart';
import 'package:aul/src/features/map/member_positions_poller.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

MemberPosition _pos(String id) => MemberPosition(
  deviceId: id,
  fix: LocationFix(lat: 1, lng: 2, capturedAt: DateTime.utc(2026, 1, 1)),
);

void main() {
  test('fetches immediately, then on each interval, and emits snapshots', () {
    fakeAsync((async) {
      var calls = 0;
      final poller = MemberPositionsPoller(
        interval: const Duration(seconds: 17),
        fetch: () async {
          calls++;
          return {'dev': _pos('dev')};
        },
      );
      final emitted = <Map<String, MemberPosition>>[];
      poller.stream.listen(emitted.add);

      poller.start();
      async.flushMicrotasks(); // resolve the immediate fetch
      expect(calls, 1);
      expect(emitted, hasLength(1));
      expect(poller.latest.keys, ['dev']);

      async.elapse(const Duration(seconds: 17));
      expect(calls, 2);
      async.elapse(const Duration(seconds: 17));
      expect(calls, 3);
      expect(emitted, hasLength(3));

      poller.dispose();
    });
  });

  test('stops firing and closes the stream after dispose', () {
    fakeAsync((async) {
      var calls = 0;
      var closed = false;
      final poller = MemberPositionsPoller(
        interval: const Duration(seconds: 10),
        fetch: () async {
          calls++;
          return const <String, MemberPosition>{};
        },
      );
      poller.stream.listen((_) {}, onDone: () => closed = true);

      poller.start();
      async.flushMicrotasks();
      expect(calls, 1);

      poller.dispose();
      async.flushMicrotasks(); // deliver the stream's onDone
      expect(closed, isTrue); // stream closed on teardown

      // No further ticks after the timer is cancelled.
      async.elapse(const Duration(seconds: 60));
      expect(calls, 1);
    });
  });

  test('keeps the last snapshot when a fetch throws', () {
    fakeAsync((async) {
      var attempt = 0;
      final poller = MemberPositionsPoller(
        interval: const Duration(seconds: 5),
        fetch: () async {
          attempt++;
          if (attempt == 1) return {'dev': _pos('dev')};
          throw Exception('transient');
        },
      );
      poller.start();
      async.flushMicrotasks();
      expect(poller.latest.keys, ['dev']);

      async.elapse(const Duration(seconds: 5)); // second fetch throws
      expect(poller.latest.keys, ['dev']); // last good snapshot retained

      poller.dispose();
    });
  });
}
