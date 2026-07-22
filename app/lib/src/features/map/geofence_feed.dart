import '../../domain/place.dart';
import '../../tracking/geofence_engine.dart' show GeofenceKind;
import 'member_positions.dart';

/// A position older than this tells us nothing about where its device is NOW, so
/// it must not count as being inside a place — otherwise a phone that went
/// offline (or paused) at home would appear stuck at home forever. Matches the
/// web GeofenceFeed's `FRESH_MS`.
const Duration kPresenceFreshness = Duration(minutes: 15);

/// How many recent crossings the feed keeps. Same as the web's slice(0, 8).
const int kFeedMaxEvents = 8;

/// How many "on the way" ETA rows the feed keeps. Same as the web's slice(0, 5).
const int kFeedMaxEtas = 5;

/// Below this ground speed a device is treated as "not moving", so no ETA is
/// shown. ~0.5 m/s ≈ 1.8 km/h. Matches the web `estimateEta` default.
const double kEtaMinSpeedMps = 0.5;

/// ETAs longer than this are too far/slow to be useful and are suppressed.
/// 3 hours, matching the web `estimateEta` default (`3 * 60 * 60` seconds).
const double kEtaMaxSeconds = 3 * 60 * 60;

/// A rough client-side ETA for one member heading toward one place: the
/// straight-line distance to the geofence EDGE divided by the last-known ground
/// speed. A deliberately crude estimate (no routing, no heading), computed
/// entirely from already-decrypted data — the server sees neither coordinates
/// nor speed. Mirrors the web `EtaEstimate` in `web/src/data/geofence.ts`.
class EtaEstimate {
  const EtaEstimate({
    required this.placeId,
    required this.placeName,
    required this.distanceToEdgeMeters,
    required this.seconds,
  });

  final String placeId;
  final String placeName;

  /// Straight-line distance to the geofence edge, in metres.
  final double distanceToEdgeMeters;

  /// Rough time-to-arrival in seconds (distance-to-edge / last-known speed).
  final double seconds;
}

/// One member's "on the way" row: the nearest place they have a usable ETA to.
class MemberEta {
  const MemberEta({
    required this.deviceId,
    required this.label,
    required this.placeId,
    required this.placeName,
    required this.seconds,
  });

  final String deviceId;
  final String label;
  final String placeId;
  final String placeName;
  final double seconds;
}

/// Rough ETA for a member at ([lat], [lng]) moving at [speed] m/s toward
/// [place]: the distance to the geofence edge over the speed.
///
/// Returns null when there is nothing sensible to show — exactly the web rules:
/// the speed is unknown or below [minSpeedMps] (treated as stationary), the
/// member is already inside the geofence, or the ETA exceeds [maxSeconds].
EtaEstimate? estimateEta(
  double lat,
  double lng,
  double? speed,
  Place place, {
  double minSpeedMps = kEtaMinSpeedMps,
  double maxSeconds = kEtaMaxSeconds,
}) {
  if (speed == null || speed < minSpeedMps) return null;
  final toEdge = distanceMeters(lat, lng, place.lat, place.lng) - place.radius;
  if (toEdge <= 0) return null; // already within the geofence
  final seconds = toEdge / speed;
  if (seconds > maxSeconds) return null;
  return EtaEstimate(
    placeId: place.id,
    placeName: place.name,
    distanceToEdgeMeters: toEdge,
    seconds: seconds,
  );
}

/// The single nearest place a moving member has a usable ETA to, so the feed can
/// show one "on the way" line per member. Null when none apply. Mirrors the web
/// `nearestEta`.
EtaEstimate? nearestEta(
  double lat,
  double lng,
  double? speed,
  List<Place> places, {
  double minSpeedMps = kEtaMinSpeedMps,
  double maxSeconds = kEtaMaxSeconds,
}) {
  EtaEstimate? best;
  for (final place in places) {
    final eta = estimateEta(
      lat,
      lng,
      speed,
      place,
      minSpeedMps: minSpeedMps,
      maxSeconds: maxSeconds,
    );
    if (eta != null && (best == null || eta.seconds < best.seconds)) best = eta;
  }
  return best;
}

/// One member's device, inside one place, right now.
class Presence {
  const Presence({
    required this.deviceId,
    required this.label,
    required this.placeId,
    required this.placeName,
  });

  final String deviceId;

  /// The member's display name (nickname → email → device id) — resolved by
  /// [MemberPosition.label], so the feed names people the way the map does
  /// rather than showing the web's bare device-id prefix.
  final String label;
  final String placeId;
  final String placeName;
}

/// One member's device crossing one place's fence.
class MemberCrossing {
  const MemberCrossing({
    required this.deviceId,
    required this.label,
    required this.placeId,
    required this.placeName,
    required this.kind,
    required this.at,
  });

  final String deviceId;
  final String label;
  final String placeId;
  final String placeName;
  final GeofenceKind kind;
  final DateTime at;
}

/// What the panel renders: who is inside a place now, plus the recent crossings
/// (newest first).
class GeofenceFeed {
  const GeofenceFeed({
    this.presence = const [],
    this.events = const [],
    this.etas = const [],
  });

  final List<Presence> presence;
  final List<MemberCrossing> events;

  /// Members who are moving toward a place (nearest place, soonest first). Only
  /// populated when the arrival feature is active — same gate as the web feed.
  final List<MemberEta> etas;

  bool get isEmpty => presence.isEmpty && events.isEmpty && etas.isEmpty;
}

/// Computes the live geofence picture entirely client-side, from decrypted
/// member positions vs decrypted places — exactly as the web GeofenceFeed does,
/// and for the same reason: the server has neither, so nobody else could.
///
/// Mirrors the web `GeofenceTracker`: inside-state is keyed per (device, place)
/// with hysteresis — a device counts as inside once it is within the radius and
/// stays inside until it moves beyond radius + [hysteresisM], so a phone
/// hovering near a boundary doesn't flap arrive/depart on GPS jitter.
///
/// One deliberate deviation from the web: the FIRST pass that sees real data
/// only seeds the inside-set, emitting no events. Whoever is already at home is
/// state, not news — announcing "arrived at Home, just now" for someone who has
/// been there for hours would be a lie with a timestamp on it.
class GeofenceFeedController {
  GeofenceFeedController({
    this.hysteresisM = 30,
    this.freshness = kPresenceFreshness,
    this.maxEvents = kFeedMaxEvents,
  });

  final double hysteresisM;
  final Duration freshness;
  final int maxEvents;

  /// Keys (`"<deviceId> <placeId>"`) currently inside.
  final Set<String> _inside = <String>{};
  final List<MemberCrossing> _events = [];
  List<MemberCrossing> _lastCrossings = const [];
  bool _seeded = false;

  static String _key(String deviceId, String placeId) => '$deviceId $placeId';

  /// The crossings that flipped on the MOST RECENT [update] — empty on the
  /// seeding pass and on any tick where nothing changed. Unlike [GeofenceFeed.
  /// events] (a rolling window kept for display), this is exactly what just
  /// happened, so a caller can fire a one-per-crossing side effect — e.g. an
  /// in-app "member arrived" notification — without re-alerting every tick.
  List<MemberCrossing> get lastCrossings => _lastCrossings;

  /// Feeds the freshest snapshot and returns the picture to render. Call it on
  /// every poll tick — and on a timer even when nothing changed, so stale
  /// positions age out of presence.
  GeofenceFeed update(
    Map<String, MemberPosition> positions,
    List<Place> places,
    DateTime now, {
    bool arrivalActive = false,
  }) {
    // Only reason about devices with a recent fix: a stale one ages out of
    // presence AND out of the inside-set, without a phantom "left".
    final fresh = [
      for (final p in positions.values)
        if (now.difference(p.fix.capturedAt) < freshness) p,
    ];

    final crossings = <MemberCrossing>[];
    final live = <String>{};
    for (final pos in fresh) {
      for (final place in places) {
        final key = _key(pos.deviceId, place.id);
        live.add(key);
        final d = distanceMeters(
          pos.fix.lat,
          pos.fix.lng,
          place.lat,
          place.lng,
        );
        final was = _inside.contains(key);
        final isInside = was
            ? d <= place.radius + hysteresisM
            : d <= place.radius;
        if (isInside == was) continue;
        if (isInside) {
          _inside.add(key);
        } else {
          _inside.remove(key);
        }
        crossings.add(
          MemberCrossing(
            deviceId: pos.deviceId,
            label: pos.label,
            placeId: place.id,
            placeName: place.name,
            kind: isInside ? GeofenceKind.enter : GeofenceKind.exit,
            at: now,
          ),
        );
      }
    }
    // A device that went stale, or a place that was deleted, drops out of the
    // inside-set silently — it did not "leave", we simply stopped knowing.
    _inside.removeWhere((k) => !live.contains(k));

    if (_seeded && crossings.isNotEmpty) {
      _events.insertAll(0, crossings.reversed); // most recent first
      if (_events.length > maxEvents) {
        _events.removeRange(maxEvents, _events.length);
      }
    }
    // The seeding pass announces nothing (whoever is already at a place is state,
    // not news), so `lastCrossings` stays empty until `_seeded` — read here,
    // before the flag is set below, so this same pass is still treated as seeding.
    _lastCrossings = _seeded
        ? List<MemberCrossing>.unmodifiable(crossings)
        : const [];
    // Only a pass that saw both halves of the picture counts as seeded: places
    // and positions load asynchronously, and an empty pass seeds nothing.
    if (fresh.isNotEmpty && places.isNotEmpty) _seeded = true;

    final presence = <Presence>[];
    final insideDevices = <String>{};
    for (final pos in fresh) {
      for (final place in places) {
        if (!_inside.contains(_key(pos.deviceId, place.id))) continue;
        insideDevices.add(pos.deviceId);
        presence.add(
          Presence(
            deviceId: pos.deviceId,
            label: pos.label,
            placeId: place.id,
            placeName: place.name,
          ),
        );
      }
    }

    // ETA: a rough estimate for members who are moving and not already inside a
    // place. Only computed when the arrival feature is active — same gate the
    // web feed uses. One row per member (their nearest place), soonest first.
    final etas = <MemberEta>[];
    if (arrivalActive) {
      for (final pos in fresh) {
        if (insideDevices.contains(pos.deviceId)) continue;
        final eta = nearestEta(pos.fix.lat, pos.fix.lng, pos.fix.speed, places);
        if (eta != null) {
          etas.add(
            MemberEta(
              deviceId: pos.deviceId,
              label: pos.label,
              placeId: eta.placeId,
              placeName: eta.placeName,
              seconds: eta.seconds,
            ),
          );
        }
      }
      etas.sort((a, b) => a.seconds.compareTo(b.seconds));
      if (etas.length > kFeedMaxEtas) {
        etas.removeRange(kFeedMaxEtas, etas.length);
      }
    }

    return GeofenceFeed(
      presence: presence,
      events: List.unmodifiable(_events),
      etas: List.unmodifiable(etas),
    );
  }
}
