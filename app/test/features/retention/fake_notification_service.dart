import 'package:aul/src/features/notifications/notification_service.dart';

/// One posted notification, captured for assertions.
class ShownNotification {
  ShownNotification(this.id, this.title, this.body);
  final int id;
  final String title;
  final String body;
}

/// A hermetic [NotificationService] that records what would be shown instead of
/// touching the platform plugin. Shared across the retention unit tests.
class FakeNotificationService implements NotificationService {
  final List<ShownNotification> shown = [];
  int initCalls = 0;
  int permissionCalls = 0;

  @override
  Future<void> init() async => initCalls++;

  @override
  Future<bool> requestPermission() async {
    permissionCalls++;
    return true;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    shown.add(ShownNotification(id, title, body));
  }
}
