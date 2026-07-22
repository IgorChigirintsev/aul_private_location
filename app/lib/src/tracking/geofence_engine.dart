import '../domain/place.dart';

enum GeofenceKind { enter, exit }

/// A geofence crossing for the device's own location against one place.
class GeofenceTransition {
  const GeofenceTransition({
    required this.placeId,
    required this.placeName,
    required this.kind,
    required this.at,
  });

  final String placeId;
  final String placeName;
  final GeofenceKind kind;
  final DateTime at;
}

/// Client-side geofence engine over the reporter's OWN fix stream. The server
/// never sees coordinates (D-0035), so enter/exit is computed here from the
/// decrypted places synced to this device.
///
/// Hysteresis: a place is "entered" when the fix comes within its radius and is
/// only "exited" once the fix moves beyond radius + [hysteresisM]. That band
/// stops GPS jitter near a boundary from flapping enter/exit. Mirrors the web
/// `GeofenceTracker` algorithm so both clients agree.
///
/// The engine is PURE and in-memory on purpose: it is the algorithm, and it is
/// pinned against the web's by test. Durability is a property of the CALLER —
/// see [restoreInside] and `tracking/geofence_state.dart` for why the inside-set
/// has to outlive the process, and [ArrivalMonitor] for who writes it back.
class GeofenceEngine {
  /// [restoreInside] seeds the inside-set from durable storage, so a restarted
  /// isolate KNOWS it was already at home and stays quiet instead of announcing
  /// an arrival nobody made.
  GeofenceEngine({this.hysteresisM = 30, Set<String>? restoreInside})
    : _inside = {...?restoreInside};

  final double hysteresisM;
  final Set<String> _inside;

  /// Feeds the latest own-location fix and the synced places; returns the
  /// crossings that just occurred. Places no longer present are pruned without
  /// emitting a spurious exit.
  List<GeofenceTransition> update(
    double lat,
    double lng,
    List<Place> places,
    DateTime now,
  ) {
    final events = <GeofenceTransition>[];
    final live = <String>{};

    for (final place in places) {
      live.add(place.id);
      final d = distanceMeters(lat, lng, place.lat, place.lng);
      final was = _inside.contains(place.id);
      final isInside = was
          ? d <= place.radius + hysteresisM
          : d <= place.radius;
      if (isInside && !was) {
        _inside.add(place.id);
        events.add(
          GeofenceTransition(
            placeId: place.id,
            placeName: place.name,
            kind: GeofenceKind.enter,
            at: now,
          ),
        );
      } else if (!isInside && was) {
        _inside.remove(place.id);
        events.add(
          GeofenceTransition(
            placeId: place.id,
            placeName: place.name,
            kind: GeofenceKind.exit,
            at: now,
          ),
        );
      }
    }

    _inside.removeWhere((id) => !live.contains(id));
    return events;
  }

  bool isInside(String placeId) => _inside.contains(placeId);

  Set<String> get insidePlaceIds => Set<String>.unmodifiable(_inside);
}
