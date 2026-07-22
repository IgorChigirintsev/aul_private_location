import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A minimal secret key/value store. Abstracted so the higher layers (auth,
/// key vault) can be unit-tested with [InMemorySecretStore] without a device.
abstract interface class SecretStore {
  Future<void> put(String key, String value);
  Future<String?> get(String key);
  Future<void> remove(String key);
  Future<void> clear();

  /// Every stored entry. Needed by the push background isolate, which must open
  /// a sealed notification WITHOUT knowing which circle it came from — the
  /// server deliberately doesn't say — and so has to try every circle key this
  /// device holds. See [KeyVault.loadAllCircleKeys].
  Future<Map<String, String>> readAll();
}

/// Backed by the OS keystore/Keychain via flutter_secure_storage.
class FlutterSecretStore implements SecretStore {
  FlutterSecretStore([FlutterSecureStorage? storage])
    : _s =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  final FlutterSecureStorage _s;

  @override
  Future<void> put(String key, String value) =>
      _s.write(key: key, value: value);

  @override
  Future<String?> get(String key) => _s.read(key: key);

  @override
  Future<void> remove(String key) => _s.delete(key: key);

  @override
  Future<void> clear() => _s.deleteAll();

  @override
  Future<Map<String, String>> readAll() => _s.readAll();
}

/// In-memory implementation for tests.
class InMemorySecretStore implements SecretStore {
  final Map<String, String> _m = {};

  @override
  Future<void> put(String key, String value) async => _m[key] = value;

  @override
  Future<String?> get(String key) async => _m[key];

  @override
  Future<void> remove(String key) async => _m.remove(key);

  @override
  Future<void> clear() async => _m.clear();

  @override
  Future<Map<String, String>> readAll() async => Map<String, String>.of(_m);
}
