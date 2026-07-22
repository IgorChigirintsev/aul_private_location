import '../../crypto/aul_crypto.dart';
import '../../crypto/notify_codec.dart';
import '../../data/api/api_client.dart';
import '../../data/key_vault.dart';
import '../../tracking/geofence_engine.dart';

/// Announces THIS device's own geofence crossings to the rest of the circle.
///
/// The mover is the only client that can announce: the crossing is computed from
/// its own fix stream, which nobody else has (D-0035 — the server never sees
/// coordinates). So when the phone crosses a fence it seals "who / where / when"
/// under K_c and hands the blob to the server, which relays it as an opaque Web
/// Push payload to everyone else in that circle. The server learns that the
/// circle had an event, and nothing more.
///
/// Best-effort by design: offline, a 503 (the operator configured no push), a
/// rate limit or any other failure is swallowed. A missed notification is not
/// worth an error in the UI, and there is nothing here worth retrying — by the
/// time a retry landed, the arrival would be old news.
class NotifyRelay {
  NotifyRelay({
    required AulApi api,
    required AulCrypto crypto,
    required KeyVault vault,
    required String? Function(String placeId) circleOfPlace,
    required String Function(String circleId) whoIn,
  }) : _api = api,
       _crypto = crypto,
       _vault = vault,
       _circleOfPlace = circleOfPlace,
       _whoIn = whoIn;

  final AulApi _api;
  final AulCrypto _crypto;
  final KeyVault _vault;

  /// Which circle owns the place that was crossed — a place belongs to exactly
  /// one circle, and only that circle may be told. Null for an unknown place
  /// (e.g. one deleted since the fence was seeded), which relays nothing.
  final String? Function(String placeId) _circleOfPlace;

  /// This member's display name in a circle: the nickname they chose there,
  /// falling back to their email. Per circle on purpose — you are whoever that
  /// circle knows you as.
  final String Function(String circleId) _whoIn;

  /// Seals [t] under the owning circle's K_c and POSTs it. Silent no-op when the
  /// place belongs to no known circle, when this device holds no key for that
  /// circle (nothing to seal under), or when the request fails for any reason.
  Future<void> onCrossing(GeofenceTransition t) async {
    final circleId = _circleOfPlace(t.placeId);
    if (circleId == null) return;
    final keyBytes = await _vault.loadCircleKey(circleId);
    if (keyBytes == null) return;
    final key = _crypto.circleKeyFromBytes(keyBytes);
    try {
      final payload = NotifyCodec(_crypto).seal(
        NotifyPayload(
          kind: t.kind == GeofenceKind.enter
              ? NotifyKind.arrival
              : NotifyKind.departure,
          place: t.placeName,
          who: _whoIn(circleId),
          ts: t.at.millisecondsSinceEpoch,
        ),
        key,
      );
      await _api.notifyCircle(circleId, payload);
    } catch (_) {
      /* offline / rate-limited / rejected — nothing worth retrying */
    } finally {
      key.dispose();
    }
  }
}
