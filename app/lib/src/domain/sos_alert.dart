/// A decrypted (or undecryptable) SOS alert for the SOS centre. The sealed
/// payload — optional last-known location + free-text message — lives only inside
/// the K_c ciphertext the server relays; this is the in-memory form after opening
/// (see `SosCodec`, crypto/sos_codec.dart).
///
/// When no key on this device opens the ciphertext the alert is STILL surfaced
/// with [decrypted] == false and just its metadata (id, device, time), so a
/// watcher is never left unaware that someone raised an emergency — mirroring the
/// web `openSos`.
class SosAlert {
  const SosAlert({
    required this.id,
    required this.createdAt,
    this.deviceId,
    this.lat,
    this.lng,
    this.message,
    this.ts,
    this.decrypted = false,
  });

  final String id;

  /// Server-assigned creation time (metadata; always present).
  final DateTime createdAt;

  /// The raising device, when the server reports it.
  final String? deviceId;

  /// Last-known location from the sealed payload (both present or both absent).
  final double? lat;
  final double? lng;

  /// Free-text message from the sealed payload, if any.
  final String? message;

  /// Client capture timestamp (epoch ms) from the sealed payload, if present.
  final int? ts;

  /// Whether a circle key on this device opened the payload. When false only the
  /// metadata fields are populated.
  final bool decrypted;

  /// Whether a last-known location is available to show/plot.
  bool get hasLocation => lat != null && lng != null;
}
