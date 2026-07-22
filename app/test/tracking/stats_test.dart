import 'package:aul/src/tracking/tracking_stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accumulates counters and last-send time', () {
    final start = DateTime.utc(2026, 1, 1);
    final s = TrackingStats(windowStart: start);
    s.onWake();
    s.onSealed();
    s.onSealed();
    s.onBatchSent(
      accepted: 2,
      stored: 2,
      duplicate: 0,
      bytes: 400,
      at: DateTime.utc(2026, 1, 1, 0, 1),
    );
    expect(s.locationWakes, 1);
    expect(s.pingsSealed, 2);
    expect(s.pingsSent, 2);
    expect(s.batchesSent, 1);
    expect(s.bytesUploaded, 400);
    expect(s.lastSendAt, DateTime.utc(2026, 1, 1, 0, 1));
  });

  test('rolls the window after 24h', () {
    final start = DateTime.utc(2026, 1, 1);
    final s = TrackingStats(windowStart: start, pingsSent: 500);
    s.rollWindow(start.add(const Duration(hours: 23)));
    expect(s.pingsSent, 500); // not yet
    s.rollWindow(start.add(const Duration(hours: 25)));
    expect(s.pingsSent, 0); // reset
    expect(s.windowStart.isAfter(start), isTrue);
  });

  test('json round-trips', () {
    final s = TrackingStats(pingsSent: 12, bytesUploaded: 999, sendFailures: 1);
    final back = TrackingStats.fromJson(s.toJson());
    expect(back.pingsSent, 12);
    expect(back.bytesUploaded, 999);
    expect(back.sendFailures, 1);
  });
}
