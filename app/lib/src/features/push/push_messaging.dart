import 'dart:async';
import 'dart:ui' show DartPluginRegistrant;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sodium/sodium.dart';

import '../../../l10n/app_localizations.dart';
import '../../controller.dart';
import '../../crypto/aul_crypto.dart';
import '../../crypto/notify_codec.dart';
import '../../data/api/api_client.dart';
import '../../data/key_vault.dart';
import '../../data/secret_store.dart';
import '../locale_controller.dart';
import '../notifications/notification_service.dart';

/// Background push for Android, and the receiving half of the loop whose sending
/// half is [NotifyRelay] (features/retention/notify_relay.dart).
///
/// THE RULE THAT SHAPES THIS WHOLE FILE: the server sends **data-only** FCM
/// messages — `data: {"payload_enc": "<base64>"}`, no `notification` key — so
/// Android renders nothing on its own and hands the bytes to us instead. Those
/// bytes are the SAME blob a sender sealed under the circle key K_c with
/// associated data `aul-notify:v1` for the web's Web Push relay. We open them
/// here, on this device, and render the plaintext ourselves.
///
/// So the failure mode is the important part: if we cannot open the blob — no
/// K_c for that circle, a rotated-away key, a corrupt payload — we show
/// **nothing at all**. Not the ciphertext, and not a generic-but-leaky line
/// derived from what the server could see. The web's service worker does show a
/// contentless "Activity in your circle" fallback, but only because Chrome's
/// `userVisibleOnly: true` contractually obliges it to display *something* for
/// every push it accepts. Android imposes no such bargain on a data-only
/// message, so we take the better option: silence.

/// The app-wide FCM registrar. Overridden in tests with a fake so nothing
/// touches the Firebase plugin.
final pushMessagingProvider = Provider<PushMessaging>(
  (ref) => PushMessaging(
    notifications: ref.read(notificationServiceProvider),
    vault: ref.read(vaultProvider),
  ),
);

/// The one data key we read. Fixed by the server contract.
const _payloadKey = 'payload_enc';

/// The notification slot for a decrypted push: one per person + place + kind.
///
/// Mirrors the web SW's `tag: aul:${t}:${who}:${place}` and inherits its
/// reasoning — a re-arrival REPLACES the stale line instead of stacking, an
/// arrival is NOT erased by a later departure, and two different people arriving
/// are two notifications. Hashing into a fixed range can collide (two payloads
/// sharing a slot), which costs a replaced notification and nothing more.
@visibleForTesting
int pushSlot(NotifyPayload p) =>
    NotifId.pushBase +
    (Object.hash(p.kind, p.who, p.place) & 0x7fffffff) % NotifId.pushSlots;

/// Opens one relayed blob and renders it. The heart of the feature.
///
/// Returns whether a notification was shown — for the tests; every caller
/// ignores it. Never throws: a push handler that throws in the background
/// isolate is just a crash log nobody reads.
@visibleForTesting
Future<bool> handleNotifyData(
  Map<String, dynamic> data, {
  required NotificationService notifications,
  required AulCrypto crypto,
  required KeyVault vault,
  AppLocalizations? l10n,
}) async {
  final raw = data[_payloadKey];
  if (raw is! String || raw.isEmpty) return false;

  // Every circle key this device holds, because the push does not say — and must
  // not say — which circle it belongs to. See KeyVault.loadAllCircleKeys.
  final rawKeys = await vault.loadAllCircleKeys();
  if (rawKeys.isEmpty) return false; // signed out, or no keys synced here

  final keyring = <SecureKey>[];
  NotifyPayload? payload;
  try {
    for (final k in rawKeys) {
      try {
        keyring.add(crypto.circleKeyFromBytes(k));
      } catch (_) {
        continue; // not a well-formed K_c — it could not have sealed this
      }
    }
    payload = NotifyCodec(crypto).open(raw, keyring);
  } catch (_) {
    return false; // libsodium unhappy — indistinguishable from "not for us"
  } finally {
    for (final k in keyring) {
      k.dispose();
    }
  }

  // Not ours to read, or authentic-but-malformed. Say NOTHING: rendering
  // anything here would be describing a push we cannot actually read.
  if (payload == null) return false;

  final strings = l10n ?? currentL10n();
  await notifications.show(
    id: pushSlot(payload),
    title: strings.notifCircleUpdateTitle,
    body: payload.kind == NotifyKind.arrival
        ? strings.notifMemberArrivedBody(payload.who, payload.place)
        : strings.notifMemberLeftBody(payload.who, payload.place),
  );
  return true;
}

/// The background/terminated message handler. **Runs in its own isolate**, with
/// its own Dart heap: no Riverpod, no providers, no [AppController], nothing the
/// UI built. Everything it needs, it builds here from scratch.
///
/// How it gets K_c — the crux of the whole task. It does NOT get it passed in;
/// it re-reads it from the same OS keystore the UI isolate writes to, through
/// the same [KeyVault] over [FlutterSecretStore] (flutter_secure_storage is a
/// platform plugin, so the value comes from Android's EncryptedSharedPreferences
/// and is isolate-agnostic). This is exactly how the headless location isolate
/// already does it — see platform/background_service.dart, `_bootstrap`. The key
/// therefore never crosses an isolate boundary, is never serialized into an
/// FCM payload, and is never held anywhere a second process could read it: both
/// isolates are simply clients of the same keystore.
///
/// Deliberately no `Firebase.initializeApp()`: this handler touches no Firebase
/// API. The message's data arrived as method-channel arguments before this ran,
/// and the plugin's own dispatcher already brought the binding up. Initializing
/// here would only add a way to fail.
///
/// Must be a top-level function annotated for AOT retention — the engine looks
/// it up by callback handle, so tree-shaking must not remove it.
@pragma('vm:entry-point')
Future<void> aulFcmBackgroundHandler(RemoteMessage message) async {
  try {
    // The plugin's dispatcher calls this too; it is idempotent, and relying on
    // someone else's initialization order is not worth the saving.
    WidgetsFlutterBinding.ensureInitialized();
    // Registers the Dart-side plugin implementations (shared_preferences) in
    // THIS isolate. The Java-side plugins (secure storage, local notifications)
    // come up with the background FlutterEngine.
    DartPluginRegistrant.ensureInitialized();
    // Match the app's language rather than the system's.
    await restoreLocaleOverride();

    final notifications = LocalNotificationService();
    await notifications.init(); // recreates the channel; idempotent
    await handleNotifyData(
      message.data,
      notifications: notifications,
      crypto: await AulCrypto.load(),
      vault: KeyVault(FlutterSecretStore()),
    );
  } catch (_) {
    // A push we cannot handle is a push nobody hears about. That is the
    // intended failure mode, so there is nothing to report and nothing to fix
    // from here.
  }
}

/// Owns FCM setup and token registration for the UI isolate.
///
/// What the server learns by registering: that this account has an Android
/// device and a token that can wake it. It never learns what it delivers — the
/// payload it relays is sealed under K_c before it ever reaches it, so FCM is
/// only transport, exactly as Web Push is for the dashboard.
class PushMessaging {
  PushMessaging({
    required NotificationService notifications,
    required KeyVault vault,
    FirebaseMessaging? messaging,
  }) : _notifications = notifications,
       _vault = vault,
       _messaging = messaging;

  final NotificationService _notifications;
  final KeyVault _vault;
  FirebaseMessaging? _messaging;

  AulCrypto? _crypto;
  StreamSubscription<String>? _tokenRefresh;
  bool _wired = false;

  /// True only where an FCM token could exist at all. iOS is excluded on
  /// purpose: its Firebase side (GoogleService-Info.plist, APNs) is not wired,
  /// and pretending otherwise would just produce prompts leading nowhere.
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Brings Firebase up and attaches the message handlers. Safe to call
  /// repeatedly; returns false when this build cannot do push at all — no
  /// google-services.json at build time (a self-hoster who brought no Firebase
  /// project), an unsupported platform, or a test host with no plugins.
  Future<bool> ensureReady() async {
    if (!supported) return false;
    if (_wired) return true;
    try {
      await Firebase.initializeApp();
      _messaging ??= FirebaseMessaging.instance;

      // Background/terminated. Deliberately before the permission prompt and
      // the token fetch in register(): those can fail or be refused, and the
      // handler should be wired regardless.
      //
      // This is also what makes the TERMINATED case work at all. The plugin
      // persists both callback handles (its dispatcher's and ours) into native
      // SharedPreferences, and the native FlutterFirebaseMessagingService reads
      // them back to spawn the isolate when a message lands on a dead app — so
      // no Dart of ours needs to have run in that process. Calling this on each
      // launch keeps the handles fresh across app updates, which move them.
      FirebaseMessaging.onBackgroundMessage(aulFcmBackgroundHandler);

      // Foreground. Data-only messages are NOT auto-rendered here either, so
      // the same decrypt-and-show path serves both — one behaviour, one place
      // it can be wrong.
      FirebaseMessaging.onMessage.listen((m) async {
        try {
          await handleNotifyData(
            m.data,
            notifications: _notifications,
            crypto: _crypto ??= await AulCrypto.load(),
            vault: _vault,
          );
        } catch (_) {
          /* same posture as the background isolate: stay quiet */
        }
      });
      _wired = true;
      return true;
    } catch (_) {
      return false; // no Firebase config / no native side — push stays inert
    }
  }

  /// Asks for the OS notification permission (Android 13+ POST_NOTIFICATIONS),
  /// then hands this device's token to [api].
  ///
  /// Returns the registered token, or null when push could not be turned on —
  /// permission refused, no Firebase, or the server rejected it. Callers treat
  /// null as "the switch stays off", so a refusal is never recorded as success.
  Future<String?> register(AulApi api) async {
    if (!await ensureReady()) return null;
    // The plugin's own request is the one that shows the Android 13 dialog for
    // FCM; the local-notifications permission is the same OS permission, so
    // whichever runs first satisfies both.
    if (!await _notifications.requestPermission()) return null;
    try {
      final token = await _messaging?.getToken();
      if (token == null || token.isEmpty) return null;
      await api.pushSubscribeFcm(token);

      // FCM can rotate a token at any time (app restore, cleared storage).
      // Follow it, or the server goes on waking a token that no longer routes
      // here — a subscription that fails silently forever.
      _tokenRefresh ??= _messaging?.onTokenRefresh.listen((t) async {
        try {
          await api.pushSubscribeFcm(t);
        } catch (_) {
          /* offline — the next register() on launch catches it up */
        }
      });
      return token;
    } catch (_) {
      return null;
    }
  }

  /// Tells the server to stop pushing to this device, and drops the local token
  /// so a later sign-in mints a fresh one rather than inheriting this account's.
  ///
  /// Best-effort on both halves: an orphaned token just fails to deliver and
  /// gets pruned server-side. Never throws — this runs on the sign-out path,
  /// where a failure must not block the user from leaving.
  Future<void> unregister(AulApi? api) async {
    await _tokenRefresh?.cancel();
    _tokenRefresh = null;
    if (!supported || _messaging == null) return;
    try {
      final token = await _messaging?.getToken();
      if (token != null && token.isNotEmpty && api != null) {
        await api.pushUnsubscribe(token);
      }
      await _messaging?.deleteToken();
    } catch (_) {
      /* offline / already gone — nothing to undo */
    }
  }
}
