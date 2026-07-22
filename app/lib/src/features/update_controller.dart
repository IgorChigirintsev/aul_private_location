import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../controller.dart';
import '../data/api/api_client.dart';
import '../data/api/models.dart';
import 'self_update.dart';

/// Where the self-update flow currently is. The APK is only ever installed
/// after its SHA-256 matches the manifest (see [UpdateService]).
enum UpdatePhase {
  /// Nothing to show (initial, or dismissed with "Later").
  idle,

  /// A version check is in flight.
  checking,

  /// A newer version is available and can be installed.
  available,

  /// Downloading + verifying the APK (indeterminate — the service does not
  /// surface byte progress, so this is a pending state).
  downloading,

  /// Handing the verified APK to the system installer.
  installing,

  /// A manual check found we are already on the latest version.
  upToDate,

  /// Something went wrong (offline, download failure, or integrity mismatch).
  error,
}

/// Immutable snapshot the self-update UI renders.
class UpdateState {
  const UpdateState({
    this.phase = UpdatePhase.idle,
    this.available,
    this.error,
    this.integrityFailure = false,
  });

  final UpdatePhase phase;
  final AppVersionInfo? available;
  final String? error;

  /// True when the failure was a SHA-256 mismatch — a tampered/corrupt APK was
  /// rejected and NOT installed.
  final bool integrityFailure;

  /// Whether a non-intrusive update prompt should be shown.
  bool get showPrompt =>
      available != null &&
      (phase == UpdatePhase.available ||
          phase == UpdatePhase.downloading ||
          phase == UpdatePhase.installing ||
          phase == UpdatePhase.error);
}

/// Installed version of the running app (Android `versionCode` == buildNumber).
/// A provider so tests can supply a value without the platform channel.
class CurrentVersion {
  const CurrentVersion(this.versionCode, this.versionName);
  final int versionCode;
  final String versionName;
}

final currentVersionProvider = FutureProvider<CurrentVersion>((_) async {
  final info = await PackageInfo.fromPlatform();
  return CurrentVersion(int.tryParse(info.buildNumber) ?? 0, info.version);
});

/// Whether self-update is possible on this platform. The app is sideloaded on
/// Android; iOS updates go through the App Store, so the feature is disabled
/// there. A provider so widget tests can enable it without a real device.
final selfUpdateSupportedProvider = Provider<bool>((_) => Platform.isAndroid);

/// Builds an [UpdateService] bound to the signed-in server, or null when signed
/// out. Overridden in tests with a fake.
final updateServiceProvider = Provider<UpdateService?>((ref) {
  final url = ref.watch(controllerProvider.select((s) => s.serverUrl));
  if (url == null) return null;
  return UpdateService(AulApi(baseUrl: url, vault: ref.read(vaultProvider)));
});

final updateControllerProvider =
    NotifierProvider<UpdateController, UpdateState>(UpdateController.new);

/// Orchestrates the discover → download+verify → install flow. All heavy lifting
/// (HTTP, hashing, the install intent) lives in [UpdateService]; this only holds
/// UI state and sequences the steps.
class UpdateController extends Notifier<UpdateState> {
  @override
  UpdateState build() => const UpdateState();

  /// Checks the server for a newer version. Non-blocking; on startup ([manual]
  /// false) any error is swallowed (being offline is normal). A [manual] check
  /// surfaces "up to date" and errors so the user gets feedback.
  Future<void> check({bool manual = false}) async {
    if (!ref.read(selfUpdateSupportedProvider)) return;
    final service = ref.read(updateServiceProvider);
    if (service == null) return;
    // Never clobber an in-progress download/install.
    if (state.phase == UpdatePhase.downloading ||
        state.phase == UpdatePhase.installing) {
      return;
    }
    state = const UpdateState(phase: UpdatePhase.checking);
    try {
      final current = await ref.read(currentVersionProvider.future);
      final info = await service.checkForUpdate(current.versionCode);
      if (info != null) {
        state = UpdateState(phase: UpdatePhase.available, available: info);
      } else {
        state = UpdateState(
          phase: manual ? UpdatePhase.upToDate : UpdatePhase.idle,
        );
      }
    } catch (_) {
      state = manual
          ? const UpdateState(
              phase: UpdatePhase.error,
              error: 'Could not check for updates. Please try again.',
            )
          : const UpdateState();
    }
  }

  /// Downloads + SHA-256-verifies the APK, then hands it to the system
  /// installer. On an integrity mismatch nothing is installed and a clear error
  /// is shown; other download errors are retriable.
  Future<void> startUpdate() async {
    final service = ref.read(updateServiceProvider);
    final info = state.available;
    if (service == null || info == null) return;

    if (ref.read(selfUpdateSupportedProvider)) {
      final granted = await _ensureInstallPermission();
      if (!granted) {
        state = UpdateState(
          phase: UpdatePhase.error,
          available: info,
          error: 'Allow "install unknown apps" for Aul to update.',
        );
        return;
      }
    }

    state = UpdateState(phase: UpdatePhase.downloading, available: info);
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/aul-${info.versionCode}.apk';
      await service.downloadAndVerify(info, path);
      state = UpdateState(phase: UpdatePhase.installing, available: info);
      await service.install(path);
      // The system installer UI now takes over; keep the prompt in "available"
      // so the user can re-launch it if they back out of the system dialog.
      state = UpdateState(phase: UpdatePhase.available, available: info);
    } on ApkIntegrityException {
      state = UpdateState(
        phase: UpdatePhase.error,
        available: info,
        integrityFailure: true,
        error: 'Update aborted: integrity check failed.',
      );
    } catch (_) {
      state = UpdateState(
        phase: UpdatePhase.error,
        available: info,
        error: 'Download failed. Please try again.',
      );
    }
  }

  /// "Later" — hide the prompt until the next check.
  void dismiss() => state = const UpdateState();

  Future<bool> _ensureInstallPermission() async {
    if ((await Permission.requestInstallPackages.status).isGranted) return true;
    return (await Permission.requestInstallPackages.request()).isGranted;
  }
}
