import 'dart:io';

import 'package:crypto/crypto.dart' as c;
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../data/api/api_client.dart';
import '../data/api/models.dart';

/// Thrown when a downloaded APK's SHA-256 does not match the published manifest.
class ApkIntegrityException implements Exception {
  ApkIntegrityException(this.expected, this.actual);
  final String expected;
  final String actual;
  @override
  String toString() =>
      'APK integrity check failed: expected $expected, got $actual';
}

/// In-app APK self-update (distributed off-Play). The download is ONLY installed
/// after its SHA-256 matches the value from `GET /v1/version/latest` — never
/// trust an APK we didn't verify.
class UpdateService {
  UpdateService(this._api, {Dio? dio}) : _dio = dio ?? Dio();

  final AulApi _api;
  final Dio _dio;
  static const _installer = MethodChannel('app.aul/installer');

  /// Returns the latest version if it is newer than [currentVersionCode].
  Future<AppVersionInfo?> checkForUpdate(int currentVersionCode) async {
    final latest = await _api.latestVersion('android');
    if (latest == null) return null;
    return latest.versionCode > currentVersionCode ? latest : null;
  }

  /// Downloads the APK and verifies its SHA-256 against the manifest. Returns the
  /// saved file path, or throws [ApkIntegrityException] on mismatch (the file is
  /// deleted so a tampered APK is never left behind).
  Future<String> downloadAndVerify(AppVersionInfo info, String savePath) async {
    if (info.apkUrl == null || info.sha256 == null) {
      throw StateError('version manifest has no apk_url/sha256');
    }
    await _dio.download(info.apkUrl!, savePath);
    final file = File(savePath);
    final actual = await sha256OfFile(file);
    if (!_constantTimeHexEqual(actual, info.sha256!.toLowerCase())) {
      await file.delete();
      throw ApkIntegrityException(info.sha256!, actual);
    }
    return savePath;
  }

  /// Hands the verified APK to the system package installer (native side sets up
  /// a FileProvider and launches ACTION_VIEW / install intent). Android-only:
  /// the installer channel does not exist on iOS (App Store updates), so this is
  /// a no-op there rather than a MissingPluginException.
  Future<void> install(String verifiedApkPath) async {
    if (!Platform.isAndroid) return;
    await _installer.invokeMethod<void>('installApk', {
      'path': verifiedApkPath,
    });
  }
}

/// Streams the file and returns its lowercase hex SHA-256.
Future<String> sha256OfFile(File file) async {
  final digest = await c.sha256.bind(file.openRead()).first;
  return _hex(digest.bytes);
}

/// Verifies raw bytes against an expected hex digest (used in tests).
bool verifyApkSha256(Uint8List bytes, String expectedHex) =>
    _constantTimeHexEqual(
      _hex(c.sha256.convert(bytes).bytes),
      expectedHex.toLowerCase(),
    );

bool _constantTimeHexEqual(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
