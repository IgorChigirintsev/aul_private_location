import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../locale_controller.dart';

/// The single low-key notification channel the retention features post to
/// (arrival alerts, tracking reminders). One channel lets the
/// user mute the whole category from system settings if they want. The
/// user-facing name/description are localized via [currentL10n] since the
/// service has no [BuildContext].
class AulNotifChannel {
  static const id = 'aul_retention';
}

/// Stable notification ids so a newer notification of the same kind replaces the
/// previous one instead of stacking (anti-nagware).
class NotifId {
  static const arrival = 1001;
  static const memberArrival = 1002;
  static const trackingOff = 1003;
  static const batteryLow = 1004;

  /// Slot range for decrypted background pushes (2000..2999). Unlike the fixed
  /// slots above, a push gets a slot DERIVED from what it says — see
  /// `pushSlot` in features/push/push_messaging.dart. Kept clear of the fixed
  /// ids so a push can never overwrite a tracking reminder.
  static const pushBase = 2000;
  static const pushSlots = 1000;
}

/// Shows local notifications. Abstracted behind an interface so widget/unit tests
/// can assert what would be shown without touching the platform plugin (a
/// [FakeNotificationService] in tests records calls).
abstract interface class NotificationService {
  /// Prepares the plugin and Android channel. Safe to call repeatedly.
  Future<void> init();

  /// Requests the OS notification permission (Android 13+, iOS). Returns whether
  /// it is granted. Never throws on an unsupported platform (returns false).
  Future<bool> requestPermission();

  /// Posts a local notification. [id] identifies the slot so a repeat of the
  /// same kind replaces the previous one.
  Future<void> show({
    required int id,
    required String title,
    required String body,
  });
}

/// Real implementation backed by `flutter_local_notifications`. Every platform
/// call is guarded by [_supported] so it degrades to a no-op — never a crash —
/// on iOS without the native side wired, on desktop/web, or on a test host where
/// the plugin channel is absent. iOS is handled (permissions via the plugin);
/// the native project itself is owned by a sibling task, so this stays purely
/// Dart-side and defensive.
class LocalNotificationService implements NotificationService {
  LocalNotificationService([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;

  bool get _supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  Future<void> init() async {
    if (_ready || !_supported) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    // Do NOT auto-request on iOS init; we ask explicitly when the user opts in.
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(
      android: android,
      iOS: darwin,
      macOS: darwin,
    );
    try {
      await _plugin.initialize(settings: settings);
      if (Platform.isAndroid) {
        final l10n = currentL10n();
        await _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.createNotificationChannel(
              AndroidNotificationChannel(
                AulNotifChannel.id,
                l10n.notifChannelName,
                description: l10n.notifChannelDescription,
                importance: Importance.defaultImportance,
              ),
            );
      }
      _ready = true;
    } catch (_) {
      // Plugin channel missing (e.g. iOS native not wired yet) — stay a no-op.
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (!_supported) return false;
    await init();
    try {
      if (Platform.isAndroid) {
        final ok = await _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission();
        return ok ?? false;
      }
      if (Platform.isIOS) {
        final ok = await _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true);
        return ok ?? false;
      }
    } catch (_) {
      // no native side — treat as not granted
    }
    return false;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!_supported) return;
    await init();
    final l10n = currentL10n();
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        AulNotifChannel.id,
        l10n.notifChannelName,
        channelDescription: l10n.notifChannelDescription,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
      iOS: const DarwinNotificationDetails(),
    );
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: details,
      );
    } catch (_) {
      // no native side — silently drop
    }
  }
}

/// The app-wide notification service. Overridden in tests with a fake.
final notificationServiceProvider = Provider<NotificationService>(
  (_) => LocalNotificationService(),
);
