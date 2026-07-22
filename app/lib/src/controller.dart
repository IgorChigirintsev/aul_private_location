import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sodium/sodium.dart';

import '../l10n/app_localizations.dart';
import 'crypto/aul_crypto.dart';
import 'crypto/ping_codec.dart';
import 'crypto/place_codec.dart';
import 'crypto/profile_codec.dart';
import 'crypto/sos_codec.dart';
import 'data/api/api_client.dart';
import 'data/api/models.dart';
import 'data/key_manager.dart';
import 'data/key_vault.dart';
import 'data/secret_store.dart';
import 'domain/location_fix.dart';
import 'domain/place.dart';
import 'domain/sos_alert.dart';
import 'features/circles/invite_link.dart';
import 'features/locale_controller.dart';
import 'features/map/member_positions.dart';
import 'features/realtime/realtime_controller.dart';
import 'features/notifications/notification_service.dart';
import 'features/push/push_messaging.dart';
import 'features/realtime/realtime_client.dart';
import 'features/realtime/ws_channel.dart';
import 'features/retention/reengagement_monitor.dart';
import 'features/retention/retention_controller.dart';
import 'features/share/share_controller.dart';
import 'platform/location_control.dart';
import 'tracking/adaptive_scheduler.dart';
import 'tracking/motion.dart';

enum AuthPhase { loading, signedOut, signedIn }

/// Outcome of [AppController.leaveSelectedCircle]. [soleOwner] means the server
/// refused the leave (the caller is a circle's sole owner) so the UI should
/// offer to delete the circle instead.
enum LeaveResult { left, soleOwner, error }

/// Sentinel so [AppSession.copyWith] can distinguish "leave selectedCircleId
/// unchanged" from "clear it to null" (a plain `null` default can't).
const Object _unchanged = Object();

/// One circle this device reports to, and the precision it is reported at.
typedef ReportingTarget = ({String circleId, PrecisionMode precision});

/// Resolves what to seal for each circle: THAT circle's own precision mode, and
/// nothing else. This is the rule that makes precision per-circle, so it is a
/// pure function — it is worth being able to state, and test, without a vault, a
/// server, or a GPS.
///
/// Every circle appears in the result, INCLUDING paused ones: the background
/// isolate reports against exactly this list, and a circle that vanished from it
/// would be indistinguishable from a circle that was never there. Paused targets
/// are carried explicitly and skipped by the reporter, which is what makes
/// "paused" a thing the reporter knows rather than a thing it can only infer.
///
/// An [override] (SOS, live share) replaces every circle's mode. That is the
/// intent: the alert already went to every circle, so a circle that was paused
/// still gets the location that makes the alert useful. It is the one case where
/// a global answer is the correct one.
List<ReportingTarget> resolveReportingTargets(
  List<CircleSummary> circles, {
  PrecisionMode? override,
}) => [
  for (final c in circles)
    (
      circleId: c.id,
      precision: override ?? PrecisionMode.fromWire(c.precisionMode),
    ),
];

/// The precision the ONE location stream must SAMPLE at to satisfy every circle:
/// the finest mode any of them is on.
///
/// Sampling fine and coarsening per circle is the only order that works — the
/// reporter calls `fix.forMode(t.precision)` per target, so a precise circle can
/// always be served from a precise sample, but a city-grid sample could never be
/// sharpened back up for it. Everything paused ⇒ paused, and the caller then
/// holds no GPS at all.
PrecisionMode samplingPrecision(Iterable<PrecisionMode> modes) {
  if (modes.contains(PrecisionMode.precise)) return PrecisionMode.precise;
  if (modes.contains(PrecisionMode.city)) return PrecisionMode.city;
  return PrecisionMode.paused;
}

/// Immutable app session snapshot the UI renders.
class AppSession {
  const AppSession({
    this.phase = AuthPhase.loading,
    this.serverUrl,
    this.email,
    this.userId,
    this.circles = const [],
    this.selectedCircleId,
    this.sharing = false,
    this.sosActive = false,
    this.error,
    this.errorCode,
  });

  final AuthPhase phase;
  final String? serverUrl;
  final String? email;

  /// This account's own user id. Needed to tell "you" apart from the other rows
  /// in a members list — the server rejects a self-mute with 400, so a bell must
  /// never be offered on yourself.
  final String? userId;
  final List<CircleSummary> circles;

  /// The circle the management/profile VIEW is focused on — and, since precision
  /// is per-circle, the circle the home screen's precision control acts on.
  ///
  /// Reporting still REACHES every circle; what selection decides is which one
  /// the UI shows and edits.
  final String? selectedCircleId;
  final bool sharing;
  final bool sosActive;
  final String? error;

  /// The server's stable error code for [error], when it came from the API — so
  /// the display can localize the codes with a context-free meaning (rate-limited,
  /// locked…) while leaving context-specific ones to the server's own message.
  /// Transient like [error]: cleared on the next state change.
  final String? errorCode;

  /// The selected circle: the one whose id == [selectedCircleId], else the first
  /// circle, else null when there are none. Defensive so a stale id (e.g. after a
  /// leave/delete) still resolves sensibly.
  CircleSummary? get selectedCircle {
    for (final c in circles) {
      if (c.id == selectedCircleId) return c;
    }
    return circles.isEmpty ? null : circles.first;
  }

  /// The SELECTED circle's precision mode — DERIVED, never stored.
  ///
  /// Precision is per-circle state the server holds on the `circle_members` row,
  /// so there is no such thing as "the app's precision". A stored copy here would
  /// be a second, lying source of truth: it could say Precise while the work
  /// circle sits on City. This getter means the home control and the circles
  /// dashboard are two views of the SAME server value, and neither can drift.
  ///
  /// Defaults to precise when there is no circle to have a mode.
  PrecisionMode get precision {
    final c = selectedCircle;
    return c == null
        ? PrecisionMode.precise
        : PrecisionMode.fromWire(c.precisionMode);
  }

  AppSession copyWith({
    AuthPhase? phase,
    String? serverUrl,
    String? email,
    String? userId,
    List<CircleSummary>? circles,
    Object? selectedCircleId = _unchanged,
    bool? sharing,
    bool? sosActive,
    String? error,
    String? errorCode,
  }) => AppSession(
    phase: phase ?? this.phase,
    serverUrl: serverUrl ?? this.serverUrl,
    email: email ?? this.email,
    userId: userId ?? this.userId,
    circles: circles ?? this.circles,
    selectedCircleId: identical(selectedCircleId, _unchanged)
        ? this.selectedCircleId
        : selectedCircleId as String?,
    sharing: sharing ?? this.sharing,
    sosActive: sosActive ?? this.sosActive,
    error: error,
    errorCode: errorCode,
  );
}

final secretStoreProvider = Provider<SecretStore>((_) => FlutterSecretStore());
final vaultProvider = Provider<KeyVault>(
  (ref) => KeyVault(ref.read(secretStoreProvider)),
);
final controlProvider = Provider<LocationControl>(
  (_) => const LocationControl(),
);

final controllerProvider = NotifierProvider<AppController, AppSession>(
  AppController.new,
);

/// Whether this device holds a circle key at all — i.e. whether an SOS could be
/// sealed for anyone. Re-evaluated whenever the circle list changes (join, leave,
/// delete), which is exactly when the answer can flip.
final hasCircleKeyProvider = FutureProvider<bool>((ref) async {
  ref.watch(controllerProvider.select((s) => s.circles));
  return ref.read(controllerProvider.notifier).hasAnyCircleKey();
});

/// Drives auth and reporting for the UI. Networking/crypto are delegated to the
/// tested data layer; this class holds only orchestration + UI state.
class AppController extends Notifier<AppSession> {
  AulApi? _api;
  AulCrypto? _crypto;

  // Retention (Phase 7). Built lazily so signed-out sessions and tests don't
  // touch the notification plugin.
  ReengagementMonitor? _reengage;

  /// Whether a live share currently needs this device's position. The share
  /// reporter flips it via [setShareNeedsLocation]; it is read here to decide
  /// whether the ONE foreground location service may stop.
  bool _shareNeedsLocation = false;

  KeyVault get _vault => ref.read(vaultProvider);
  LocationControl get _control => ref.read(controlProvider);

  /// The signed-in API client, or null when signed out. Exposed for the
  /// live-share reporter, which talks to `/v1/share` on the SAME authenticated
  /// server as everything else and has no business building a second client.
  AulApi? get api => _api;

  /// libsodium, loaded on demand. Exposed so the live-share codec can seal under
  /// K_share with the very same primitives the ping codec uses.
  Future<AulCrypto> get crypto => _ensureCrypto();

  NotificationService get _notifications =>
      ref.read(notificationServiceProvider);
  ReengagementMonitor get _reengageMonitor =>
      _reengage ??= ReengagementMonitor(_notifications);

  @override
  AppSession build() {
    _restore();
    return const AppSession();
  }

  Future<AulCrypto> _ensureCrypto() async => _crypto ??= await AulCrypto.load();

  /// Loads a circle's full key ring (all K_c epochs, oldest → newest) as live
  /// [SecureKey]s for DECRYPTING — data sealed under a pre-rotation key still
  /// opens. Empty when this device holds no key for the circle. Callers MUST
  /// [_disposeKeyring] the result. SEALING still uses only the newest key
  /// (via [KeyVault.loadCircleKey]).
  Future<List<SecureKey>> _keyringFor(String circleId) async {
    final crypto = await _ensureCrypto();
    final raws = await _vault.loadCircleKeys(circleId);
    return [for (final r in raws) crypto.circleKeyFromBytes(r)];
  }

  void _disposeKeyring(List<SecureKey> keyring) {
    for (final k in keyring) {
      k.dispose();
    }
  }

  Future<void> _restore() async {
    final url = await _vault.loadServerUrl();
    final session = await _vault.loadSession();
    if (url == null || session == null) {
      state = state.copyWith(phase: AuthPhase.signedOut);
      return;
    }
    _api = AulApi(baseUrl: url, vault: _vault);
    // Reporting is on only if the service runs AND it has somewhere to report:
    // the service also runs for a live share alone, and that is not "sharing
    // with your circle".
    final targets = await _vault.loadReportingTargets();
    final sharing = targets.isNotEmpty && await _control.isReporting();
    state = state.copyWith(
      phase: AuthPhase.signedIn,
      serverUrl: url,
      sharing: sharing,
      // Restored from the vault: a relaunched session must still know which
      // member row is its own (the "(you)" marker, and never a self-mute).
      userId: await _vault.loadUserId(),
      email: await _vault.loadEmail(),
    );
    await refreshCircles();
    await syncKeys();
  }

  Future<bool> authenticate({
    required String serverUrl,
    required String email,
    required String password,
    required bool register,
  }) async {
    try {
      final crypto = await _ensureCrypto();
      final api = AulApi(baseUrl: serverUrl, vault: _vault);

      // Ensure an X25519 identity keypair exists; send the public key.
      var identity = await _vault.loadIdentity();
      if (identity == null) {
        final kp = crypto.generateIdentityKeyPair();
        await _vault.saveIdentity(kp.publicKey, kp.secretKey.extractBytes());
        identity = (
          publicKey: kp.publicKey,
          secretKey: kp.secretKey.extractBytes(),
        );
      }
      final pubB64 = base64.encode(identity.publicKey);

      final res = register
          ? await api.register(
              email: email,
              password: password,
              platform: 'android',
              pubkeyB64: pubB64,
            )
          : await api.login(
              email: email,
              password: password,
              platform: 'android',
              pubkeyB64: pubB64,
            );

      await _vault.saveServerUrl(serverUrl);
      _api = api;
      state = state.copyWith(
        phase: AuthPhase.signedIn,
        serverUrl: serverUrl,
        email: res.email ?? email,
        userId: res.userId,
        error: null,
      );
      await refreshCircles();
      await syncKeys();
      return true;
    } on AulApiException catch (e) {
      state = state.copyWith(error: e.message, errorCode: e.code);
      return false;
    } catch (e) {
      state = state.copyWith(error: '$e');
      return false;
    }
  }

  Future<void> refreshCircles() async {
    final api = _api;
    if (api == null) return;
    try {
      final circles = await api.listCircles();
      state = state.copyWith(circles: circles);
    } catch (_) {
      /* offline: keep cached */
    }
  }

  /// Picks up any circle keys distributed to this device as sealed envelopes
  /// (Phase 4: multi-device key distribution / rotation). Best-effort.
  ///
  /// Public because the realtime socket drives it too: a `key_envelope` event
  /// means a key was just re-sealed to this device, and opening it right then is
  /// what stops a rotation from blanking the map until the next launch.
  Future<void> syncKeys() async {
    final api = _api;
    if (api == null) return;
    try {
      final crypto = await _ensureCrypto();
      await KeyManager(
        crypto: crypto,
        api: api,
        vault: _vault,
      ).openPendingEnvelopes();
    } catch (_) {
      /* offline / none */
    }
  }

  /// Joins a circle from an invite link `https://host/i/<id>#<base64url(K_c)>`.
  /// The fragment never reaches the server: the invite is accepted by id, and
  /// K_c goes straight from the link into this device's vault.
  Future<bool> joinByLink(String link) async {
    final api = _api;
    if (api == null) return false;
    try {
      final crypto = await _ensureCrypto();
      final parsed = parseInviteLink(link, keyBytes: crypto.circleKeyBytes);
      switch (parsed) {
        case InviteLinkFailed(:final error):
          final l10n = currentL10n();
          state = state.copyWith(
            error: switch (error) {
              InviteLinkError.notAnInvite => l10n.inviteInvalid,
              InviteLinkError.missingKey => l10n.inviteMissingKey,
              InviteLinkError.malformedKey => l10n.inviteMalformed,
            },
          );
          return false;
        case InviteLinkOk(:final parts):
          final circleId = await api.acceptInvite(parts.inviteId);
          await _vault.saveCircleKey(circleId, parts.key);
          await refreshCircles();
          state = state.copyWith(selectedCircleId: circleId);
          await syncKeys();
          return true;
      }
    } catch (e) {
      state = state.copyWith(error: '$e');
      return false;
    }
  }

  /// Creates an invite to [circleId] and returns the link that actually works:
  /// `<server>/i/<inviteId>#<base64url(K_c)>`.
  ///
  /// Two halves from two places, and that is the whole point. The server issues
  /// the invite id knowing nothing about the key; this device staples K_c on as
  /// the URL fragment, which no browser or client ever puts on the wire. So the
  /// server can let someone in without ever being able to read what they are let
  /// into — and whoever holds the WHOLE link can join, which is exactly what the
  /// UI must say out loud.
  ///
  /// Returns null when signed out, when this device holds no key for the circle
  /// (an invite without K_c would join someone to ciphertext they can't read),
  /// or when the server refused — [AppSession.error] carries the reason.
  Future<String?> createInviteLink(String circleId, {int maxUses = 5}) async {
    final api = _api;
    final origin = state.serverUrl;
    if (api == null || origin == null) return null;
    final keyBytes = await _vault.loadCircleKey(circleId);
    if (keyBytes == null) return null;
    try {
      final inviteId = await api.createInvite(circleId, maxUses: maxUses);
      state = state.copyWith(error: null);
      return inviteLink(origin, inviteId, keyBytes);
    } on AulApiException catch (e) {
      state = state.copyWith(error: e.message, errorCode: e.code);
      return null;
    } catch (e) {
      state = state.copyWith(error: '$e');
      return null;
    }
  }

  // --- circle management (parity with the web CircleSwitcher) ---
  //
  // Reporting REACHES every circle whose key is on this device (see startSharing
  // / raiseSos) — selection does not gate that. What selection drives is the
  // management/profile VIEW, and with it the home screen's precision control,
  // which writes the SELECTED circle's mode and no other's.

  /// Focuses the management/profile view — and the home precision control — on
  /// [id].
  void selectCircle(String id) => state = state.copyWith(selectedCircleId: id);

  /// Decodes [circle]'s sealed name under its local K_c (the circle-name form,
  /// no AD — matching web). Returns null when there's no name, no local key, or
  /// it can't be opened, so the UI falls back to a generic label.
  Future<String?> decodeCircleName(CircleSummary circle) async {
    final enc = circle.nameEnc;
    if (enc == null) return null;
    final crypto = await _ensureCrypto();
    final keyring = await _keyringFor(circle.id);
    if (keyring.isEmpty) return null;
    try {
      final blob = base64.decode(enc);
      for (final key in keyring) {
        try {
          final name = utf8.decode(crypto.openFramed(blob, key));
          return name.isEmpty ? null : name;
        } catch (_) {
          // wrong/rotated key — try the next one in the ring
        }
      }
      return null;
    } catch (_) {
      return null; // malformed base64
    } finally {
      _disposeKeyring(keyring);
    }
  }

  /// Creates a new circle: generates a fresh K_c, seals the name under it (no
  /// AD — the circle-name form, matching web), stores the key locally, then
  /// selects the new circle. Returns false on failure (error is set on state).
  Future<bool> createCircle(String name) async {
    final api = _api;
    if (api == null) return false;
    try {
      final crypto = await _ensureCrypto();
      final key = crypto.generateCircleKey();
      try {
        final nameEnc = base64.encode(
          crypto.sealFramed(Uint8List.fromList(utf8.encode(name)), key),
        );
        final circle = await api.createCircle(nameEncB64: nameEnc);
        await _vault.saveCircleKey(circle.id, key.extractBytes());
        await refreshCircles();
        state = state.copyWith(selectedCircleId: circle.id, error: null);
        return true;
      } finally {
        key.dispose();
      }
    } on AulApiException catch (e) {
      state = state.copyWith(error: e.message, errorCode: e.code);
      return false;
    } catch (e) {
      state = state.copyWith(error: '$e');
      return false;
    }
  }

  /// Owner-only: re-seals the selected circle's name under its K_c (no AD, the
  /// circle-name form) and updates it, then refreshes. No-op without a key.
  Future<void> renameSelectedCircle(String name) async {
    final api = _api;
    final circle = state.selectedCircle;
    if (api == null || circle == null) return;
    final kBytes = await _vault.loadCircleKey(circle.id);
    if (kBytes == null) return;
    final crypto = await _ensureCrypto();
    final key = crypto.circleKeyFromBytes(kBytes);
    try {
      final nameEnc = base64.encode(
        crypto.sealFramed(Uint8List.fromList(utf8.encode(name)), key),
      );
      await api.renameCircle(circle.id, nameEnc);
      await refreshCircles();
    } finally {
      key.dispose();
    }
  }

  /// Owner-only: rotates the selected circle's key K_c. Generates a fresh key,
  /// bumps the server epoch, APPENDS the new key to the local ring as its new
  /// newest (so subsequent seals use it while every pre-rotation blob still opens
  /// under the older ring keys), then re-seals the new key to every member device
  /// as a sealed envelope. Requires a key already on this device (owner path):
  /// returns false without touching anything when none is held. Returns true on
  /// success; on failure sets [AppSession.error] and returns false.
  ///
  /// If reporting is active, re-issues [startSharing] so the sharing state stays
  /// consistent — but note the long-lived background isolate caches its per-circle
  /// sealing key from bootstrap, so it picks up the new key on its next (re)start;
  /// until then it may seal fresh pings under the previous key, which still open
  /// for all viewers because that key remains in the ring (v1 has no forward
  /// secrecy). Exposed for the next stage's rotate button + verify screen.
  Future<bool> rotateSelectedCircleKey() async {
    final api = _api;
    final circle = state.selectedCircle;
    if (api == null || circle == null) return false;
    // Rotation re-keys EXISTING data, so we must already hold the current key —
    // otherwise we'd orphan every pre-rotation blob for the whole circle.
    if (await _vault.loadCircleKey(circle.id) == null) return false;
    try {
      final crypto = await _ensureCrypto();
      await KeyManager(
        crypto: crypto,
        api: api,
        vault: _vault,
      ).rotateKey(circle.id);
      if (state.sharing) await startSharing();
      state = state.copyWith(error: null);
      return true;
    } on AulApiException catch (e) {
      state = state.copyWith(error: e.message, errorCode: e.code);
      return false;
    } catch (e) {
      state = state.copyWith(error: '$e');
      return false;
    }
  }

  /// Leaves the selected circle. On success wipes its local key, refreshes, and
  /// advances selection. A SOLE owner cannot leave: returns [LeaveResult.soleOwner]
  /// so the UI can offer to delete instead.
  Future<LeaveResult> leaveSelectedCircle() async {
    final api = _api;
    final circle = state.selectedCircle;
    if (api == null || circle == null) return LeaveResult.error;
    try {
      await api.leaveCircle(circle.id);
    } on SoleOwnerException {
      return LeaveResult.soleOwner;
    } on AulApiException {
      return LeaveResult.error;
    }
    await _forgetCircle(circle.id);
    return LeaveResult.left;
  }

  /// Owner-only: permanently deletes the selected circle for everyone, then
  /// wipes its local key, refreshes, and advances selection.
  Future<void> deleteSelectedCircle() async {
    final api = _api;
    final circle = state.selectedCircle;
    if (api == null || circle == null) return;
    await api.deleteCircle(circle.id);
    await _forgetCircle(circle.id);
  }

  /// Drops a circle's local key, refreshes the list, and moves selection to the
  /// first remaining circle (or clears it when none remain).
  Future<void> _forgetCircle(String circleId) async {
    await _vault.removeCircleKey(circleId);
    await refreshCircles();
    final remaining = state.circles;
    state = state.copyWith(
      selectedCircleId: remaining.isEmpty ? null : remaining.first.id,
    );
  }

  // --- per-circle profiles (nickname + avatar, sealed under K_c) ---

  /// Members of [circleId] with their sealed profiles. Empty when signed out.
  Future<List<Member>> membersOf(String circleId) async {
    final api = _api;
    if (api == null) return const [];
    return api.members(circleId);
  }

  /// Owner-only (enforced server-side): removes [userId] from [circleId]. The
  /// removed member keeps the K_c they already hold — v1 has no forward secrecy —
  /// so the caller should offer [rotateSelectedCircleKey] right after.
  Future<void> removeMemberFrom(String circleId, String userId) async {
    final api = _api;
    if (api == null) return;
    await api.removeMember(circleId, userId);
  }

  /// Seals the caller's own profile under [circleId]'s K_c and uploads it. No-op
  /// without a key for the circle.
  Future<void> saveProfile(
    String circleId, {
    required String nick,
    String? avatar,
  }) async {
    final api = _api;
    if (api == null) return;
    final kBytes = await _vault.loadCircleKey(circleId);
    if (kBytes == null) return;
    final crypto = await _ensureCrypto();
    final key = crypto.circleKeyFromBytes(kBytes);
    try {
      final enc = ProfileCodec(
        crypto,
      ).seal(nick: nick, avatar: avatar, key: key);
      await api.setProfile(circleId, enc);
    } finally {
      key.dispose();
    }
  }

  /// Clears the caller's own profile for [circleId] (server stores null).
  Future<void> clearProfile(String circleId) async {
    await _api?.setProfile(circleId, null);
  }

  /// Every member's display name in [circleId], keyed by user id: their nickname
  /// from the sealed per-circle profile, else their email, else a short user id —
  /// the same fallback chain the members list uses. Used to put a NAME on server
  /// metadata that only carries a user id (a place's `created_by`). Empty when
  /// signed out or offline.
  Future<Map<String, String>> memberDisplayNames(String circleId) async {
    final api = _api;
    if (api == null) return const {};
    try {
      final out = <String, String>{};
      for (final m in await api.members(circleId)) {
        final profile = await openMemberProfile(circleId, m.profileEnc);
        final nick = profile?.nick.trim() ?? '';
        out[m.userId] = nick.isNotEmpty
            ? nick
            : (m.email.isNotEmpty ? m.email : m.userId);
      }
      return out;
    } catch (_) {
      return const {}; // offline — the caller falls back to no owner label
    }
  }

  // --- notification mutes (parity with the web mutes.ts) ---
  //
  // Muting is enforced on the SERVER: it skips muted recipients when fanning a
  // notification out, so a mute genuinely stops other members' notifications
  // reaching this account — it is not local suppression. The PUT REPLACES the
  // whole set, so callers must send complete state (built with the pure
  // [Mutes.withCircleMuted] / [Mutes.withMemberMuted] helpers).

  /// The caller's own mutes in [circleId]. Falls back to [Mutes.none] whenever
  /// the set cannot be read (signed out, offline, or a server without the
  /// endpoint). Failing OPEN is deliberate: an unreadable mute set rendered as
  /// "muted" would tell the user that notifications are stopped when they are not.
  Future<Mutes> mutesOf(String circleId) async {
    final api = _api;
    if (api == null) return Mutes.none;
    try {
      return await api.mutes(circleId);
    } catch (_) {
      return Mutes.none;
    }
  }

  /// Replaces the caller's whole mute set for [circleId], returning what the
  /// server actually stored — so the UI settles on the truth rather than on what
  /// it hoped was stored. Returns null when signed out or the write failed (the
  /// server rejects a self-mute or a non-member with 400), leaving the caller to
  /// keep showing the previous state.
  Future<Mutes?> setMutes(String circleId, Mutes next) async {
    final api = _api;
    if (api == null) return null;
    try {
      return await api.setMutes(circleId, next);
    } catch (_) {
      return null;
    }
  }

  /// Decodes a member's sealed [profileEnc] using [circleId]'s local K_c. Returns
  /// null if there's no key, no profile, or it can't be opened (wrong key / AD).
  Future<({String nick, String? avatar})?> openMemberProfile(
    String circleId,
    String? profileEnc,
  ) async {
    if (profileEnc == null) return null;
    final crypto = await _ensureCrypto();
    final keyring = await _keyringFor(circleId);
    if (keyring.isEmpty) return null;
    try {
      return ProfileCodec(crypto).openWithKeyring(profileEnc, keyring);
    } finally {
      _disposeKeyring(keyring);
    }
  }

  // --- live map (Stage B) ---

  /// Fetches and decrypts the latest position of every device in [circleId] for
  /// the live MAP. Joins the device roster (platform + userId) and each member's
  /// per-circle profile (nickname + avatar) — all decrypted on-device with K_c —
  /// plus each member's current precision mode (so a paused member's pin renders
  /// as not-live) into a deviceId → [MemberPosition] map. Pings that don't
  /// decrypt are skipped by [buildMemberPositions]. This is the fetch the map
  /// poller calls on its interval.
  ///
  /// Returns an EMPTY map for "there is nothing to show" (signed out, no key for
  /// the circle, nobody sharing) and NULL for "couldn't find out" (offline, a
  /// transient server error). The caller must not treat those alike: an empty map
  /// blanks the map, and a dropped request is not evidence that everyone stopped
  /// sharing — least of all when the realtime socket has just delivered a
  /// position the poller would erase.
  Future<Map<String, MemberPosition>?> loadMemberPositions(
    String circleId,
  ) async {
    final api = _api;
    if (api == null) return const {};
    final crypto = await _ensureCrypto();
    final keyring = await _keyringFor(circleId);
    if (keyring.isEmpty) return const {}; // no key ⇒ nothing decryptable
    try {
      final pings = await api.latestPings(circleId);
      if (pings.isEmpty) return const {};
      final devices = await api.circleDevices(circleId);
      final devicesById = {for (final d in devices) d.id: d};
      // Decode each member's profile once, keyed by userId, for labels/avatars.
      final members = await api.members(circleId);
      final profileCodec = ProfileCodec(crypto);
      final profiles = <String, ({String nick, String? avatar})?>{};
      final emails = <String, String>{};
      // Each member's CURRENT sharing mode, straight off this fetch — the map
      // polls this method, so a pause shows up within one tick. Never read the
      // mode out of the last ping: a paused reporter sends none.
      final precision = <String, String>{};
      for (final m in members) {
        emails[m.userId] = m.email;
        precision[m.userId] = m.precisionMode;
        profiles[m.userId] = m.profileEnc == null
            ? null
            : profileCodec.openWithKeyring(m.profileEnc!, keyring);
      }
      return buildMemberPositions(
        pings: pings,
        codec: PingCodec(crypto),
        circleKeys: keyring,
        devicesById: devicesById,
        profilesByUserId: profiles,
        emailsByUserId: emails,
        precisionByUserId: precision,
      );
    } catch (_) {
      return null; // offline / transient — the poller keeps the last snapshot
    } finally {
      _disposeKeyring(keyring);
    }
  }

  /// Builds the realtime client for [circleId], handing it that circle's key ring
  /// so ping events are decrypted ON THIS DEVICE — the socket carries the same
  /// ciphertext the polling endpoint does, and the server can read neither.
  ///
  /// The returned client OWNS the keyring and frees it on dispose; the caller
  /// must dispose it. Null when signed out or when [AppSession.serverUrl] isn't a
  /// URL a socket can be built from — there is nothing to connect to, and the
  /// poller carries on regardless.
  ///
  /// A circle this device holds NO key for still gets a client: its pings are
  /// undecryptable and get skipped, but member/place/precision events still tell
  /// the UI when to refetch, and a key_envelope event is how this device learns it
  /// has just been given the key.
  Future<RealtimeClient?> createRealtimeClient(
    String circleId, {
    RealtimeHandlers handlers = const RealtimeHandlers(),
  }) async {
    final api = _api;
    final serverUrl = state.serverUrl;
    if (api == null || serverUrl == null) return null;
    final url = realtimeUrl(serverUrl);
    if (url == null) return null;
    final crypto = await _ensureCrypto();
    return RealtimeClient(
      circleId: circleId,
      codec: PingCodec(crypto),
      keyring: await _keyringFor(circleId),
      handlers: handlers,
      // Resolved per ATTEMPT, not once: a reconnect after a long background
      // stretch needs a token that is valid now, not the one that was valid when
      // the screen opened.
      open: () async {
        final token = await api.socketAccessToken();
        if (token == null) return null; // no session — nothing to authenticate
        return WsRealtimeChannel.connect(url, accessToken: token);
      },
    );
  }

  /// The member devices of [circleId] (id + platform + owning user + identity
  /// public key), for the verify-devices screen. Empty when signed out or offline.
  Future<List<CircleDevice>> devicesOf(String circleId) async {
    final api = _api;
    if (api == null) return const [];
    try {
      return await api.circleDevices(circleId);
    } catch (_) {
      return const [];
    }
  }

  // --- device verification (safety codes) ---
  //
  // A safety code is derived from THIS device's identity public key paired with
  // another device's — read aloud out of band, it detects a server-injected /
  // MITM key. No server involvement; nothing here leaves the device.

  /// This device's X25519 identity PUBLIC key — the half that pairs with another
  /// device's pubkey to derive their shared safety code. Null before an identity
  /// keypair exists (i.e. before the first sign-in).
  Future<Uint8List?> myIdentityPublicKey() async =>
      (await _vault.loadIdentity())?.publicKey;

  /// This device's server-assigned device id, used to exclude it from the
  /// verify-devices list. Null when this device isn't registered yet.
  Future<String?> myDeviceId() => _vault.loadDeviceId();

  // --- SOS centre (parity with the web SosBanner) ---
  //
  // Alerts are sealed under K_c with SosCodec (AD "aul-sos:v1"); the server
  // relays one opaque ciphertext column per alert plus metadata (id/device/time).

  /// Lists [circleId]'s active SOS alerts, decrypting each under the circle key
  /// (oldest-first). An alert whose payload cannot be opened — no/rotated key,
  /// wrong AD, malformed blob — is STILL returned from metadata (decrypted:false)
  /// so no emergency is silently missed; when this device has no key for the
  /// circle at all, every alert surfaces as undecrypted metadata. Empty when
  /// signed out or offline.
  Future<List<SosAlert>> loadSosAlerts(String circleId) async {
    final api = _api;
    if (api == null) return const [];
    final crypto = await _ensureCrypto();
    // Full ring (all epochs) so an alert sealed under a pre-rotation key still
    // opens; an alert no key opens is still surfaced from metadata upstream.
    final keyring = await _keyringFor(circleId);
    try {
      final codec = SosCodec(crypto);
      final out = <SosAlert>[
        for (final s in await api.listSos(circleId)) codec.open(s, keyring),
      ];
      out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return out;
    } catch (_) {
      return const []; // offline / transient — the poller keeps trying
    } finally {
      _disposeKeyring(keyring);
    }
  }

  /// Resolves (clears) an active SOS alert for the whole circle. No-op when
  /// signed out.
  Future<void> resolveSosAlert(String circleId, String sosId) async {
    await _api?.resolveSos(circleId, sosId);
  }

  // --- places / geofences (parity with the web PlacesPanel) ---
  //
  // Names + coordinates are sealed under K_c with PlaceCodec before they leave
  // the device; the server stores one opaque ciphertext column per place. All
  // three of these route through the shared codec (crypto/place_codec.dart), the
  // same one _loadForegroundPlaces uses, so there is one wire format.

  /// Fetches and decrypts [circleId]'s places for the places view + editor,
  /// sorted by name. Empty when signed out or without a key for the circle;
  /// undecryptable places (wrong/rotated key) are skipped.
  Future<List<Place>> placesOf(String circleId) async {
    final api = _api;
    if (api == null) return const [];
    final crypto = await _ensureCrypto();
    final keyring = await _keyringFor(circleId);
    if (keyring.isEmpty) return const []; // no key ⇒ nothing decryptable
    try {
      final codec = PlaceCodec(crypto);
      final out = <Place>[];
      for (final rp in await api.listPlaces(circleId)) {
        final p = codec.open(
          id: rp.id,
          version: rp.version,
          ciphertextB64: rp.ciphertextB64,
          keyring: keyring,
          createdBy: rp.createdBy,
        );
        if (p != null) out.add(p);
      }
      out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return out;
    } finally {
      _disposeKeyring(keyring);
    }
  }

  /// Seals then creates or updates a place under [circleId]'s K_c. With no [id]
  /// it creates a new place; with an [id] it updates that one, passing [version]
  /// for the server's optimistic-concurrency check (throws [AulApiException] on a
  /// 409 version clash, which the editor surfaces). Returns the saved [Place], or
  /// null when signed out / no key for the circle.
  Future<Place?> savePlace(
    String circleId, {
    String? id,
    int? version,
    required String name,
    required double lat,
    required double lng,
    required double radius,
  }) async {
    final api = _api;
    if (api == null) return null;
    final kBytes = await _vault.loadCircleKey(circleId);
    if (kBytes == null) return null;
    final crypto = await _ensureCrypto();
    final key = crypto.circleKeyFromBytes(kBytes);
    try {
      final ct = PlaceCodec(
        crypto,
      ).seal(name: name, lat: lat, lng: lng, radius: radius, key: key);
      final rp = id == null
          ? await api.createPlace(circleId, ct)
          : await api.updatePlace(circleId, id, ct, version ?? 1);
      return Place(
        id: rp.id,
        version: rp.version,
        name: name,
        lat: lat,
        lng: lng,
        radius: radius,
        createdBy: rp.createdBy,
      );
    } finally {
      key.dispose();
    }
  }

  /// Deletes a place by [id] from [circleId]. No-op when signed out.
  Future<void> deletePlaceById(String circleId, String id) async {
    await _api?.deletePlace(circleId, id);
  }

  // --- precision (what each circle sees of you) ---
  //
  // precision_mode is per-circle state the SERVER holds, and it is metadata the
  // circle can see: it is what greys out a paused member's marker for everyone
  // else. So a precision change must be told to the server, not merely applied to
  // the local reporter — otherwise this device would quietly stop sending while
  // the rest of the circle still saw a live-looking pin.

  /// The home screen's precision control: sets the SELECTED circle's mode, and
  /// ONLY that circle's — matching the web. It deliberately does NOT fan out.
  /// Fanning out is what made "City for work while family stays Precise"
  /// unreachable: one tap silently overwrote every other circle's choice.
  ///
  /// Returns false when there is no selected circle, when signed out, or when the
  /// server refused — so the control can spring back instead of lying.
  Future<bool> setPrecision(PrecisionMode mode) async {
    final circle = state.selectedCircle;
    if (circle == null) return false;
    return setCirclePrecision(circle.id, mode);
  }

  /// Sets ONE circle's precision mode (Precise / City / Paused) — the circles
  /// dashboard's per-row control, and the home control's selected circle. Only
  /// [circleId] changes; every other circle keeps whatever it was on.
  ///
  /// The write goes to the SERVER (`PUT /v1/circles/{id}/precision`) because
  /// precision_mode is metadata the circle can see: it is what greys out a paused
  /// member's marker for everyone else. Applying it only to the local reporter
  /// would quietly stop sending while the rest of the circle still saw a
  /// live-looking pin.
  ///
  /// Refreshes the circle list afterwards so everything derived from the server's
  /// value — this row, the home control, and the map's grey-marker read — settles
  /// on what was actually stored. Returns false when signed out or the server
  /// refused, so the caller can spring back instead of lying.
  Future<bool> setCirclePrecision(String circleId, PrecisionMode mode) async {
    final api = _api;
    if (api == null) return false;
    try {
      await api.setPrecision(circleId, mode.wire);
    } catch (_) {
      return false;
    }
    await refreshCircles();
    if (state.sharing) {
      await startSharing(); // re-apply: this circle's target just changed
    }
    return true;
  }

  /// Persists reporting targets and starts the foreground service. [mode] and
  /// [precisionOverride] let SOS force a fast, precise live cadence regardless of
  /// the user's chosen precision (so watchers get a live location in an emergency).
  Future<void> startSharing({
    TrackingMode mode = TrackingMode.normal,
    PrecisionMode? precisionOverride,
  }) async {
    final circles = state.circles;
    if (circles.isEmpty) return;
    // Resolved per circle, NOT from one global value: each circle's pings are
    // sealed at ITS OWN mode, so City for work and Precise for family coexist.
    // The background isolate seals from exactly these persisted targets.
    final resolved = resolveReportingTargets(
      circles,
      override: precisionOverride,
    );
    await _vault.saveReportingTargets([
      for (final t in resolved)
        {'id': t.circleId, 'precision': t.precision.wire},
    ]);

    // One GPS stream serves every circle, so it samples at the FINEST mode any
    // of them is on; the reporter then coarsens per target.
    final perCircle = [for (final t in resolved) t.precision];
    final precision = samplingPrecision(perCircle);

    const scheduler = AdaptiveScheduler();
    // Paused here means EVERY circle is paused (that is what _samplingPrecision
    // returns paused for), so don't hold the GPS open to seal nothing for nobody.
    if (precision == PrecisionMode.paused) {
      state = state.copyWith(sharing: false);
      // Pausing the CIRCLE must not kill a live share: the saved targets are
      // 'paused' so the isolate seals nothing for the circle, but the stream
      // itself stays up for the share that is still running.
      if (_shareNeedsLocation) {
        await _startShareOnlyLocation();
      } else {
        await _control.stop();
      }
      return;
    }
    // The circle wants the stream. The effective cadence is the fastest active
    // need — a live share (or an SOS) can be faster than the circle's own, and
    // when it is, it wins (SOS < share < circle).
    final profile = scheduler.profileForNeeds(
      circle: true,
      share: _shareNeedsLocation,
      sos: mode == TrackingMode.sos || state.sosActive,
      circlePrecision: precision,
    );
    final l10n = currentL10n();
    // Count the circles actually being reported to, not every circle the user is
    // in: a paused circle receives nothing, so naming it in the "sharing with"
    // notification would overstate who can see them.
    final receiving = perCircle.where((p) => p != PrecisionMode.paused).length;
    final label = l10n.circlesCount(receiving);
    // [precision] is the finest mode in play. With mixed modes the notification
    // names the sharpest thing this phone is sending anywhere — an understatement
    // would be the dangerous direction here.
    final note = mode == TrackingMode.sos
        ? l10n.sosNotification(label)
        : l10n.sharingNotification(label, _precisionLabel(l10n, precision));
    await _control.start(profile: profile, notificationText: note);
    state = state.copyWith(sharing: true);
    await _startForegroundRetention();
  }

  /// Raises an SOS to every circle whose key is on this device: seals a small
  /// payload (optional message + timestamp) under K_c and POSTs it, then forces
  /// fast precise live sharing so watchers get a location immediately. Returns
  /// false if nothing could be sent (no circles / keys). The sealed payload is
  /// opaque to the server; it only relays the alert and fans it out.
  Future<bool> raiseSos({String? message}) async {
    final api = _api;
    if (api == null || state.circles.isEmpty) return false;
    final crypto = await _ensureCrypto();
    final codec = SosCodec(crypto);
    // Attach the freshest location the foreground holds — this user's own last
    // decrypted position — so the alert carries a fix immediately, before the
    // forced precise cadence delivers its first live ping. Null (no known fix
    // yet) simply seals without coordinates, as before.
    final myId = state.userId;
    final self = myId == null
        ? null
        : positionsByUser(ref.read(memberPositionStoreProvider).positions)[myId];
    final lat = self?.fix.lat;
    final lng = self?.fix.lng;
    var sent = 0;
    for (final c in state.circles) {
      final kBytes = await _vault.loadCircleKey(c.id);
      if (kBytes == null) continue;
      final key = crypto.circleKeyFromBytes(kBytes);
      try {
        await api.createSos(
          c.id,
          codec.seal(key: key, message: message, lat: lat, lng: lng),
        );
        sent++;
      } catch (_) {
        // best effort per circle
      } finally {
        key.dispose();
      }
    }
    if (sent == 0) return false;
    state = state.copyWith(sosActive: true);
    await startSharing(
      mode: TrackingMode.sos,
      precisionOverride: PrecisionMode.precise,
    );
    return true;
  }

  /// Whether ANY circle on this device holds a key — i.e. whether [raiseSos]
  /// could seal anything at all. Drives the SOS control's disabled state, so an
  /// emergency button is never offered when pressing it could only fail.
  Future<bool> hasAnyCircleKey() async {
    for (final c in state.circles) {
      if (await _vault.loadCircleKey(c.id) != null) return true;
    }
    return false;
  }

  /// Clears the SOS state and returns reporting to the normal cadence/precision.
  Future<void> cancelSos() async {
    state = state.copyWith(sosActive: false);
    if (state.sharing) await startSharing();
  }

  Future<void> stopSharing() async {
    // Drop the targets FIRST: the background isolate seals for whatever is
    // persisted here, so leaving them behind would keep pinging the circle if
    // the service is restarted for a live share below.
    await _vault.saveReportingTargets(const []);
    state = state.copyWith(sharing: false);
    if (_shareNeedsLocation) {
      // A live share is still running off this same stream — it does not stop
      // because the circle did. It has its own deadline and its own key.
      await _startShareOnlyLocation();
      return;
    }
    await _control.stop();
  }

  // --- live-share location (Stage: share sharer) ---

  /// Flips whether a live share needs this device's position. Called by the
  /// share controller when its first session goes live and when its last one
  /// ends.
  ///
  /// A share NEVER opens a second GPS stream: it rides the same foreground
  /// service circle reporting uses. So this only starts that one service when
  /// nothing else was running it, and only stops it when nothing else still
  /// wants it.
  ///
  /// Starting the service is ALL this has to do. The fixes themselves are sealed
  /// under K_share and PUT by the location isolate, which reads the session list
  /// straight from the vault ([ShareKeyStore]) — the foreground neither sees a
  /// fix nor forwards one. That is what makes a share survive the app closing,
  /// which is most of the point of a share.
  Future<void> setShareNeedsLocation(bool needed) async {
    if (_shareNeedsLocation == needed) return;
    _shareNeedsLocation = needed;
    if (needed) {
      // The circle is already streaming, but at ITS cadence (30 s), which is
      // slower than a share needs (10 s). Reusing it unchanged would pin the
      // viewer to the circle's rate — so re-apply the profile, which now folds
      // in the share need and reconfigures the running service to the fastest
      // of the two (SOS < share < circle).
      if (state.sharing) {
        await startSharing();
        return;
      }
      // Reporting without an in-memory circle target is a share-only stream from
      // a previous run — already at the share cadence, so just ride it.
      if (await _control.isReporting()) return;
      await _startShareOnlyLocation();
      return;
    }
    // The share ended. If the circle still needs the stream, drop the cadence
    // back to the circle's own (30 s) rather than leaving the phone pinned at
    // the share's 10 s for a circle that does not need it — that is battery.
    if (state.sharing) {
      await startSharing();
      return;
    }
    await _control.stop();
  }

  /// Runs the one foreground location service for a live share ALONE: the live
  /// cadence, a notification that says a share link is what's running, and no
  /// circle reporting of its own (the persisted targets decide that, and they
  /// are empty or paused whenever this path is taken).
  Future<void> _startShareOnlyLocation() async {
    const scheduler = AdaptiveScheduler();
    // Share alone (the circle is paused/off), but honour the same precedence so
    // an SOS overlapping a share-only stream still wins: SOS < share.
    final profile = scheduler.profileForNeeds(
      circle: false,
      share: true,
      sos: state.sosActive,
      circlePrecision: PrecisionMode.precise,
    );
    await _control.start(
      profile: profile,
      notificationText: currentL10n().shareNotification,
    );
  }

  /// Retention (Phase 7): after sharing starts in the foreground, seed the
  /// background isolate's place cache and run the re-engagement "sharing off"
  /// check. All best-effort and behind the per-feature opt-in + server
  /// kill-switch; nothing fires unless the user opted in.
  Future<void> _startForegroundRetention() async {
    await _syncPlaceCache();
    final r = ref.read(retentionProvider);
    if (r.reengageActive) {
      final running = await _control.isReporting();
      await _reengageMonitor.onTrackingState(
        shouldBeSharing: true,
        serviceRunning: running,
        active: true,
        l10n: currentL10n(),
      );
    }
  }

  /// The localized label for [mode], used in the foreground-service notification.
  String _precisionLabel(AppLocalizations l10n, PrecisionMode mode) =>
      switch (mode) {
        PrecisionMode.precise => l10n.precisionPrecise,
        PrecisionMode.city => l10n.precisionCity,
        PrecisionMode.paused => l10n.precisionPaused,
      };

  // NOTHING HERE CONSUMES A FIX, AND NOTHING MAY. Every per-fix feature —
  // circle pings, live-share pings, geofence crossings, the low-battery
  // reminder — lives in the headless location isolate (see
  // `platform/background_service.dart`). Its stream runs whenever tracking is
  // on, foreground included, so a second consumer here would add no coverage; it
  // would only double every send and every alert, from two engines racing the
  // same durable state. The single owner is what makes that impossible rather
  // than unlikely.
  //
  // This is also where a `setForegroundLocationHandler` on the `app.aul/control`
  // channel used to be. Nothing on either platform ever invoked `onLocation`
  // there — Android and iOS both forward fixes on `app.aul/bg` — so the handler
  // never fired once in production, and it silently cost live share and the
  // low-battery reminder their entire existence. It has been deleted rather
  // than repointed: the fix belongs where the fixes already are.

  /// Seeds the background isolate's geofence place cache: every circle's places
  /// as the server served them (STILL SEALED), which circle each belongs to, and
  /// who this member is in that circle.
  ///
  /// The isolate is the one that evaluates crossings, and it could fetch this
  /// itself — but it would then be blind on its very first fix after a reboot,
  /// and blind forever offline. The foreground has the session, the circle list
  /// and the member profiles in hand already, so it leaves a warm cache behind
  /// each time sharing starts. The isolate refreshes it on its own TTL from
  /// there (see [BackgroundPlaces]), which is what stops a place added on the web
  /// from going unnoticed until the app is next opened.
  ///
  /// Nothing is decrypted to build this: what is cached is the same ciphertext
  /// the server holds, so no coordinate is written to the device in cleartext.
  /// [_myNameIn] IS decrypted profile text, which is why the cache lives in the
  /// keystore rather than in a plain database. Best-effort throughout: on any
  /// failure the previous cache stands, which is a better answer than none.
  Future<void> _syncPlaceCache() async {
    final api = _api;
    if (api == null) return;
    try {
      final places = <Map<String, dynamic>>[];
      final who = <String, String>{};
      for (final c in state.circles) {
        for (final rp in await api.listPlaces(c.id)) {
          places.add({
            'c': c.id,
            'id': rp.id,
            'v': rp.version,
            'ct': rp.ciphertextB64,
          });
        }
        final name = await _myNameIn(c.id);
        if (name != null) who[c.id] = name;
      }
      await _vault.saveGeofencePlaces({
        'at': DateTime.now().toUtc().millisecondsSinceEpoch,
        'who': who,
        'places': places,
      });
    } catch (_) {
      // offline / no places — leave whatever the isolate already had
    }
  }

  /// This member's display name in [circleId]: the nickname from their sealed
  /// per-circle profile, else their email. Null when it can't be resolved (signed
  /// out, offline, or no profile and no email) — the relay then falls back to the
  /// account email. Decrypted on-device: the server holds only the sealed blob.
  Future<String?> _myNameIn(String circleId) async {
    final api = _api;
    final me = state.userId;
    if (api == null || me == null) return null;
    try {
      for (final m in await api.members(circleId)) {
        if (m.userId != me) continue;
        final nick = (await openMemberProfile(
          circleId,
          m.profileEnc,
        ))?.nick.trim();
        if (nick != null && nick.isNotEmpty) return nick;
        return m.email.isNotEmpty ? m.email : null;
      }
    } catch (_) {
      // offline / no members — fall back upstream
    }
    return null;
  }

  Future<void> signOut() async {
    // Revoke the live shares first, while the tokens still work: a link that
    // outlived its owner's session would keep showing a stranger where they are.
    await ref.read(shareControllerProvider.notifier).revokeAllForSignOut();
    // Stop the pushes too, while the tokens still work — the server must not
    // keep waking this handset for a circle it just left. Deliberately BEFORE
    // the logout/wipe below: unregistering needs an authenticated call, and a
    // token that outlived its session would go on delivering (undecryptable,
    // and so silent, but still) to a signed-out device.
    await ref.read(pushMessagingProvider).unregister(_api);
    _shareNeedsLocation = false;
    await _control.stop();
    await _vault.saveReportingTargets(const []);
    try {
      await _api?.logout();
    } catch (_) {}
    // Wipes the geofence place cache and the durable inside-set along with the
    // keys, so the next account starts with neither this one's fences nor its
    // idea of which of them it is standing in.
    await _vault.wipe();
    _api = null;
    state = const AppSession(phase: AuthPhase.signedOut);
  }
}
