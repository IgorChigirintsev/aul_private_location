import 'dart:math' as math;

/// A decrypted place: a named location with a geofence radius. Name + coordinates
/// live only inside the K_c-sealed ciphertext on the server (never a plaintext
/// column) — this is the in-memory form after opening. See `PlaceCodec`
/// (crypto/place_codec.dart) for the seal/open wire format.
class Place {
  const Place({
    required this.id,
    required this.version,
    required this.name,
    required this.lat,
    required this.lng,
    required this.radius,
    this.createdBy,
  });

  final String id;
  final int version;
  final String name;
  final double lat;
  final double lng;
  final double radius; // metres (geofence radius)

  /// User id of the member who created the place (server metadata from
  /// `created_by` — never part of the sealed blob, so it needs no key). Resolved
  /// to a nickname for display; null on an older server or an unknown creator.
  final String? createdBy;
}

/// Great-circle distance in metres (haversine). Matches the web `distanceMeters`
/// so geofence enter/exit agree across clients.
double distanceMeters(double aLat, double aLng, double bLat, double bLng) {
  const r = 6371000.0;
  double toRad(double x) => x * math.pi / 180.0;
  final dLat = toRad(bLat - aLat);
  final dLng = toRad(bLng - aLng);
  final lat1 = toRad(aLat);
  final lat2 = toRad(bLat);
  final h =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(h)));
}
