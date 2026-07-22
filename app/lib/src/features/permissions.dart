import 'package:permission_handler/permission_handler.dart';

/// Thin wrapper over permission_handler for the progressive location-permission
/// flow (spec §9): While-in-use → educational screen → Background → notification
/// → battery-optimization exclusion.
class AppPermissions {
  const AppPermissions();

  Future<bool> hasWhileInUse() => Permission.locationWhenInUse.isGranted;
  Future<bool> hasBackground() => Permission.locationAlways.isGranted;
  Future<bool> hasNotifications() => Permission.notification.isGranted;

  Future<PermissionStatus> requestWhileInUse() =>
      Permission.locationWhenInUse.request();

  /// Must be requested AFTER while-in-use is granted (Android requirement).
  Future<PermissionStatus> requestBackground() =>
      Permission.locationAlways.request();

  Future<PermissionStatus> requestNotifications() =>
      Permission.notification.request();

  Future<bool> requestIgnoreBatteryOptimizations() async =>
      (await Permission.ignoreBatteryOptimizations.request()).isGranted;

  /// Everything needed for reliable background reporting.
  Future<bool> ready() async =>
      await hasWhileInUse() &&
      await hasBackground() &&
      await hasNotifications();

  Future<void> openSettings() => openAppSettings();
}
