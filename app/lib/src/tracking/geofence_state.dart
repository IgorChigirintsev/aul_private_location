import '../data/key_vault.dart';

/// Durable home for the geofence engine's inside/outside set.
///
/// WHY THIS EXISTS. [GeofenceEngine]'s `_inside` set is the entire memory of the
/// feature: "enter" means *the fix is in the radius and was not before*. Held
/// only in RAM, "was not before" is a lie every time the process restarts — and
/// Android restarts a START_STICKY foreground service whenever it feels like it
/// (memory pressure, an app update, a reboot). A fresh engine starts empty, so
/// the first fix while you sit at home reads as a crossing and re-announces "you
/// arrived at Home" to you AND, through the relay, to your whole circle. Nobody
/// moved. That is the bug this interface exists to make impossible.
///
/// So the set must outlive the isolate, and the store must be reachable from the
/// isolate that owns evaluation — the headless location service (see
/// `BackgroundReporter`), which has no Riverpod, no providers and no UI.
abstract interface class GeofenceStateStore {
  /// The place ids this device was last known to be INSIDE. Empty when nothing
  /// was ever stored (a genuinely fresh install) — see [ArrivalMonitor] for why
  /// that case still must not announce anything.
  Future<Set<String>> load();

  /// Replaces the stored set. Called only when the set actually CHANGES, which
  /// is to say on a crossing — a handful of writes a day, not one per fix.
  Future<void> save(Set<String> insidePlaceIds);
}

/// The production store: the device keystore, via [KeyVault].
///
/// Why the keystore and not the drift queue database, which the isolate also
/// already opens:
///
///  * It is **location-derived data at rest.** "This device is inside fence
///    abc-123" is a weaker statement than a coordinate, but it is the same kind
///    of statement. `queued_pings` documents its own invariant — it stores ONLY
///    ciphertext, so that location data is encrypted at rest on the device too —
///    and a plaintext `inside` table sitting beside it would quietly undercut
///    exactly that promise. The keystore (Android EncryptedSharedPreferences)
///    keeps the posture intact for free.
///  * **The write pattern fits.** Secure storage is a poor fit for chatty
///    writes, and a perfect fit for this one: the set is read ONCE per isolate
///    start and written only on a crossing. It is never touched on the hot fix
///    path.
///  * **It is proven across isolates.** [KeyVault] over `FlutterSecretStore` is
///    already how BOTH background isolates reach their secrets — the location
///    service's `_bootstrap` and the FCM handler. Reusing it adds no new
///    cross-isolate assumption; a drift table would have cost a schema migration
///    and codegen for data that is smaller than one ping.
///  * **Sign-out wipes it.** [KeyVault.wipe] clears the whole store, so a second
///    account can never inherit the first one's fences. A drift table would have
///    needed that remembering by hand.
class VaultGeofenceState implements GeofenceStateStore {
  const VaultGeofenceState(this._vault);

  final KeyVault _vault;

  @override
  Future<Set<String>> load() => _vault.loadGeofenceInside();

  @override
  Future<void> save(Set<String> insidePlaceIds) =>
      _vault.saveGeofenceInside(insidePlaceIds);
}

/// A store that forgets. For tests, and for any caller that deliberately wants
/// no durability.
class MemoryGeofenceState implements GeofenceStateStore {
  Set<String> _inside = <String>{};

  @override
  Future<Set<String>> load() async => _inside;

  @override
  Future<void> save(Set<String> insidePlaceIds) async =>
      _inside = Set<String>.of(insidePlaceIds);
}
