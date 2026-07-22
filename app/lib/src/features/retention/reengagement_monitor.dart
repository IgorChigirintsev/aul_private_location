import '../../../l10n/app_localizations.dart';
import '../notifications/notification_service.dart';

/// Posts honest, dismissible re-engagement reminders for on-device conditions the
/// app already knows about — never nagware. Each reminder is posted at most once
/// per condition-episode (a dedup flag that clears when the condition clears), so
/// resuming and re-losing tracking can remind again, but a persisting condition
/// does not repeat. Behind the reengage opt-in + server kill-switch ([active]).
class ReengagementMonitor {
  ReengagementMonitor(this._notifications);

  final NotificationService _notifications;

  /// Battery percentage at or below which low-battery may throttle location.
  static const int batteryThreshold = 15;

  bool _trackingOffShown = false;
  bool _batteryLowShown = false;

  /// Call whenever the sharing/service state may have changed. If the user
  /// expects to be sharing ([shouldBeSharing]) but the foreground service is not
  /// running ([serviceRunning] false), post one reminder. Clears when sharing
  /// resumes so a later drop can remind again.
  Future<void> onTrackingState({
    required bool shouldBeSharing,
    required bool serviceRunning,
    required bool active,
    required AppLocalizations l10n,
  }) async {
    final off = shouldBeSharing && !serviceRunning;
    if (!off) {
      _trackingOffShown = false;
      return;
    }
    if (!active || _trackingOffShown) return;
    _trackingOffShown = true;
    await _notifications.show(
      id: NotifId.trackingOff,
      title: l10n.notifSharingOffTitle,
      body: l10n.notifSharingOffBody,
    );
  }

  /// Call with the latest known battery level. Reminds once when it drops to/below
  /// [batteryThreshold] while sharing is expected; clears when it recovers.
  Future<void> onBattery({
    required int batteryPct,
    required bool active,
    required AppLocalizations l10n,
  }) async {
    final low = batteryPct <= batteryThreshold;
    if (!low) {
      _batteryLowShown = false;
      return;
    }
    if (!active || _batteryLowShown) return;
    _batteryLowShown = true;
    await _notifications.show(
      id: NotifId.batteryLow,
      title: l10n.notifBatteryLowTitle,
      body: l10n.notifBatteryLowBody,
    );
  }
}
