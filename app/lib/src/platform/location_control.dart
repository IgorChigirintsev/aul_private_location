import 'package:flutter/services.dart';

import '../tracking/adaptive_scheduler.dart';

/// Foreground control bridge to the native reporting service. The UI issues
/// commands; the actual location work runs in the service's background isolate.
///
/// STRICTLY ONE-WAY: this channel carries start/stop/isReporting to the native
/// side and nothing back. Fixes arrive on `app.aul/bg`, in the location isolate,
/// on both platforms — `MainActivity` only RECEIVES on `app.aul/control` and
/// never sends. A `setForegroundLocationHandler` that registered for `onLocation`
/// here was deleted for exactly that reason: nothing ever called it, so the two
/// features hanging off it (live share, the low-battery reminder) never ran once.
/// Do not add a receiver here — add it where the fixes are.
class LocationControl {
  const LocationControl();

  static const _channel = MethodChannel('app.aul/control');

  /// Starts the foreground reporting service with [profile] and a truthful
  /// notification line (spec §9: "Sharing with {circle} · ±N m").
  Future<void> start({
    required TrackingProfile profile,
    required String notificationText,
  }) async {
    await _channel.invokeMethod<void>('startReporting', {
      'interval_ms': profile.interval.inMilliseconds,
      'displacement_m': profile.minDisplacementMeters,
      'priority': profile.minDisplacementMeters >= 100 ? 'balanced' : 'high',
      'notif_text': notificationText,
    });
  }

  Future<void> stop() => _channel.invokeMethod<void>('stopReporting');

  Future<bool> isReporting() async =>
      (await _channel.invokeMethod<bool>('isReporting')) ?? false;
}
