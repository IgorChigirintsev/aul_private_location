/// Accounting for the in-app debug/battery screen. Counters reset on a rolling
/// 24-hour window so testers can watch a "typical day" and confirm the ≤3 %/day
/// battery target. Contains no location data — only counts and sizes.
class TrackingStats {
  TrackingStats({
    DateTime? windowStart,
    this.locationWakes = 0,
    this.pingsSealed = 0,
    this.pingsSent = 0,
    this.pingsDuplicate = 0,
    this.batchesSent = 0,
    this.sendFailures = 0,
    this.bytesUploaded = 0,
    this.lastSendAt,
  }) : windowStart = windowStart ?? DateTime.now().toUtc();

  DateTime windowStart;
  int locationWakes;
  int pingsSealed;
  int pingsSent;
  int pingsDuplicate;
  int batchesSent;
  int sendFailures;
  int bytesUploaded;
  DateTime? lastSendAt;

  /// Resets counters if the 24h window elapsed relative to [now].
  void rollWindow(DateTime now) {
    if (now.toUtc().difference(windowStart) >= const Duration(hours: 24)) {
      windowStart = now.toUtc();
      locationWakes = pingsSealed = pingsSent = pingsDuplicate = 0;
      batchesSent = sendFailures = bytesUploaded = 0;
      lastSendAt = null;
    }
  }

  void onWake() => locationWakes++;
  void onSealed() => pingsSealed++;

  void onBatchSent({
    required int accepted,
    required int stored,
    required int duplicate,
    required int bytes,
    required DateTime at,
  }) {
    batchesSent++;
    pingsSent += stored;
    pingsDuplicate += duplicate;
    bytesUploaded += bytes;
    lastSendAt = at.toUtc();
  }

  void onSendFailure() => sendFailures++;

  Map<String, dynamic> toJson() => {
    'windowStart': windowStart.toIso8601String(),
    'locationWakes': locationWakes,
    'pingsSealed': pingsSealed,
    'pingsSent': pingsSent,
    'pingsDuplicate': pingsDuplicate,
    'batchesSent': batchesSent,
    'sendFailures': sendFailures,
    'bytesUploaded': bytesUploaded,
    'lastSendAt': lastSendAt?.toIso8601String(),
  };

  factory TrackingStats.fromJson(Map<String, dynamic> j) => TrackingStats(
    windowStart: DateTime.parse(j['windowStart'] as String),
    locationWakes: (j['locationWakes'] as num?)?.toInt() ?? 0,
    pingsSealed: (j['pingsSealed'] as num?)?.toInt() ?? 0,
    pingsSent: (j['pingsSent'] as num?)?.toInt() ?? 0,
    pingsDuplicate: (j['pingsDuplicate'] as num?)?.toInt() ?? 0,
    batchesSent: (j['batchesSent'] as num?)?.toInt() ?? 0,
    sendFailures: (j['sendFailures'] as num?)?.toInt() ?? 0,
    bytesUploaded: (j['bytesUploaded'] as num?)?.toInt() ?? 0,
    lastSendAt: (j['lastSendAt'] as String?) != null
        ? DateTime.parse(j['lastSendAt'] as String)
        : null,
  );
}
