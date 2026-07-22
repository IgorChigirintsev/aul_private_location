import 'dart:math';

/// Exponential backoff with full jitter for the batch sender's retries. The
/// random source is injectable so the policy can be tested deterministically.
class Backoff {
  Backoff({
    this.base = const Duration(seconds: 2),
    this.max = const Duration(minutes: 5),
    Random? random,
  }) : _rng = random ?? Random();

  final Duration base;
  final Duration max;
  final Random _rng;

  /// Delay before retry number [attempt] (0-based). Capped at [max], with full
  /// jitter in `[0, exp]` so many devices don't retry in lockstep.
  Duration delay(int attempt) {
    if (attempt < 0) attempt = 0;
    final expMs = base.inMilliseconds * (1 << min(attempt, 20));
    final cappedMs = min(expMs, max.inMilliseconds);
    final jittered = (cappedMs * _rng.nextDouble()).round();
    return Duration(milliseconds: jittered);
  }

  /// Upper bound (no jitter) before retry [attempt] — useful for display/tests.
  Duration ceiling(int attempt) {
    if (attempt < 0) attempt = 0;
    final expMs = base.inMilliseconds * (1 << min(attempt, 20));
    return Duration(milliseconds: min(expMs, max.inMilliseconds));
  }
}
