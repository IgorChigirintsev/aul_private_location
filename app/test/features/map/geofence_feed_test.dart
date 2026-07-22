import 'package:aul/src/domain/location_fix.dart';
import 'package:aul/src/domain/place.dart';
import 'package:aul/src/features/map/geofence_feed.dart';
import 'package:aul/src/features/map/member_positions.dart';
import 'package:aul/src/tracking/geofence_engine.dart' show GeofenceKind;
import 'package:flutter_test/flutter_test.dart';

const _home = Place(
  id: 'home',
  version: 1,
  name: 'Home',
  lat: 43.2,
  lng: 76.8,
  radius: 100,
);
const _school = Place(
  id: 'school',
  version: 1,
  name: 'School',
  lat: 43.3,
  lng: 76.9,
  radius: 100,
);

final _t0 = DateTime.utc(2026, 1, 1, 9, 0);

/// A decrypted member position, the shape the map pipeline hands the feed.
MemberPosition _pos(
  String deviceId, {
  required double lat,
  required double lng,
  DateTime? at,
  String nick = 'Aisha',
}) => MemberPosition(
  deviceId: deviceId,
  nick: nick,
  fix: LocationFix(lat: lat, lng: lng, capturedAt: at ?? _t0),
);

Map<String, MemberPosition> _snapshot(List<MemberPosition> positions) => {
  for (final p in positions) p.deviceId: p,
};

void main() {
  // Inside Home, and far from everything.
  MemberPosition atHome(String id, {DateTime? at, String nick = 'Aisha'}) =>
      _pos(id, lat: 43.2, lng: 76.8, at: at, nick: nick);
  MemberPosition away(String id, {DateTime? at, String nick = 'Aisha'}) =>
      _pos(id, lat: 43.25, lng: 76.85, at: at, nick: nick);

  group('presence', () {
    test('a device inside a place is present, named as the map names it', () {
      final feed = GeofenceFeedController().update(
        _snapshot([atHome('d1', nick: 'Aisha')]),
        const [_home, _school],
        _t0,
      );
      expect(feed.presence, hasLength(1));
      expect(feed.presence.single.deviceId, 'd1');
      expect(feed.presence.single.placeName, 'Home');
      // The nickname, not the web's bare device-id prefix.
      expect(feed.presence.single.label, 'Aisha');
    });

    test('a device outside every place is present nowhere', () {
      final feed = GeofenceFeedController().update(
        _snapshot([away('d1')]),
        const [_home],
        _t0,
      );
      expect(feed.presence, isEmpty);
    });

    test('several members at several places all show', () {
      final feed = GeofenceFeedController().update(
        _snapshot([
          atHome('d1', nick: 'Aisha'),
          _pos('d2', lat: 43.3, lng: 76.9, nick: 'Bek'),
        ]),
        const [_home, _school],
        _t0,
      );
      expect(feed.presence, hasLength(2));
      expect(
        feed.presence.map((p) => '${p.label}@${p.placeName}'),
        containsAll(['Aisha@Home', 'Bek@School']),
      );
    });
  });

  group('presence ages out (a stale fix is not a location)', () {
    test('a position older than 15 minutes stops counting as inside', () {
      final ctl = GeofenceFeedController();
      // Fresh: present.
      expect(
        ctl.update(_snapshot([atHome('d1')]), const [_home], _t0).presence,
        hasLength(1),
      );

      // The same fix, 16 minutes later: the phone went quiet, so we no longer
      // know where it is — it must not appear stuck at home forever.
      final later = _t0.add(const Duration(minutes: 16));
      final feed = ctl.update(_snapshot([atHome('d1')]), const [_home], later);
      expect(feed.presence, isEmpty);
      // And it must not read as having LEFT: we stopped knowing, it didn't move.
      expect(feed.events, isEmpty);
    });

    test('a fix just under the freshness window still counts', () {
      final ctl = GeofenceFeedController();
      final later = _t0.add(const Duration(minutes: 14, seconds: 59));
      expect(
        ctl.update(_snapshot([atHome('d1')]), const [_home], later).presence,
        hasLength(1),
      );
    });

    test(
      'a device that goes stale and comes back re-announces its arrival',
      () {
        final ctl = GeofenceFeedController();
        ctl.update(_snapshot([atHome('d1')]), const [_home], _t0);
        // Ages out silently...
        final gone = _t0.add(const Duration(minutes: 20));
        expect(
          ctl.update(_snapshot([atHome('d1')]), const [_home], gone).events,
          isEmpty,
        );
        // ...and a fresh fix from inside is news again.
        final back = _t0.add(const Duration(minutes: 21));
        final feed = ctl.update(_snapshot([atHome('d1', at: back)]), const [
          _home,
        ], back);
        expect(feed.events, hasLength(1));
        expect(feed.events.single.kind, GeofenceKind.enter);
      },
    );
  });

  group('events', () {
    test(
      'the first pass with real data seeds silently — state is not news',
      () {
        // Whoever is already home has not just arrived. Announcing it with a
        // "just now" timestamp would be a lie with a clock on it.
        final ctl = GeofenceFeedController();
        final feed = ctl.update(_snapshot([atHome('d1')]), const [_home], _t0);
        expect(feed.presence, hasLength(1)); // they ARE there
        expect(feed.events, isEmpty); // but nothing happened
      },
    );

    test('an empty pass seeds nothing (data loads asynchronously)', () {
      final ctl = GeofenceFeedController();
      // Places haven't loaded yet — this pass must not count as the seed.
      ctl.update(_snapshot([atHome('d1')]), const [], _t0);
      // Now they load: still the first REAL pass, so still silent.
      final feed = ctl.update(_snapshot([atHome('d1')]), const [_home], _t0);
      expect(feed.presence, hasLength(1));
      expect(feed.events, isEmpty);
    });

    test('a crossing after the seed is an arrival', () {
      final ctl = GeofenceFeedController();
      ctl.update(_snapshot([away('d1')]), const [_home], _t0); // seed: outside
      final feed = ctl.update(_snapshot([atHome('d1')]), const [_home], _t0);
      expect(feed.events, hasLength(1));
      expect(feed.events.single.kind, GeofenceKind.enter);
      expect(feed.events.single.placeName, 'Home');
      expect(feed.events.single.label, 'Aisha');
      expect(feed.events.single.at, _t0);
    });

    test('leaving is an exit', () {
      final ctl = GeofenceFeedController();
      ctl.update(_snapshot([away('d1')]), const [_home], _t0);
      ctl.update(_snapshot([atHome('d1')]), const [_home], _t0);
      final feed = ctl.update(_snapshot([away('d1')]), const [_home], _t0);
      expect(feed.events.first.kind, GeofenceKind.exit);
      expect(feed.presence, isEmpty);
    });

    test('newest first, capped at 8', () {
      final ctl = GeofenceFeedController();
      ctl.update(_snapshot([away('d1')]), const [_home], _t0); // seed
      // Ten crossings: in, out, in, out…
      for (var i = 0; i < 10; i++) {
        final at = _t0.add(Duration(minutes: i));
        ctl.update(
          _snapshot([i.isEven ? atHome('d1', at: at) : away('d1', at: at)]),
          const [_home],
          at,
        );
      }
      final feed = ctl.update(
        _snapshot([atHome('d1', at: _t0.add(const Duration(minutes: 10)))]),
        const [_home],
        _t0.add(const Duration(minutes: 10)),
      );
      expect(feed.events, hasLength(kFeedMaxEvents));
      // Most recent first.
      expect(feed.events.first.at, _t0.add(const Duration(minutes: 10)));
      expect(feed.events.first.kind, GeofenceKind.enter);
    });

    test('hysteresis: jitter near the edge does not flap', () {
      final ctl = GeofenceFeedController();
      ctl.update(_snapshot([away('d1')]), const [_home], _t0); // seed outside
      // Inside the radius ⇒ enter.
      final feed1 = ctl.update(_snapshot([atHome('d1')]), const [_home], _t0);
      expect(feed1.events, hasLength(1));

      // Now drift to ~120 m out: past the 100 m radius but inside the 30 m
      // hysteresis band, so still "inside" — no phantom exit.
      final jitter = _pos('d1', lat: 43.20108, lng: 76.8, at: _t0);
      final feed2 = ctl.update(_snapshot([jitter]), const [_home], _t0);
      expect(feed2.events, hasLength(1)); // still just the arrival
      expect(feed2.presence, hasLength(1));
    });

    test('a deleted place drops out without a phantom exit', () {
      final ctl = GeofenceFeedController();
      ctl.update(_snapshot([away('d1')]), const [_home], _t0);
      ctl.update(_snapshot([atHome('d1')]), const [_home], _t0);
      // The place is gone from the circle: nobody "left" it.
      final feed = ctl.update(_snapshot([atHome('d1')]), const [_school], _t0);
      expect(feed.events, hasLength(1)); // only the earlier arrival
      expect(feed.events.single.kind, GeofenceKind.enter);
      expect(feed.presence, isEmpty);
    });

    test('one member moving does not announce anything for the others', () {
      final ctl = GeofenceFeedController();
      ctl.update(
        _snapshot([away('d1', nick: 'Aisha'), atHome('d2', nick: 'Bek')]),
        const [_home],
        _t0,
      );
      final feed = ctl.update(
        _snapshot([atHome('d1', nick: 'Aisha'), atHome('d2', nick: 'Bek')]),
        const [_home],
        _t0,
      );
      expect(feed.events, hasLength(1));
      expect(feed.events.single.label, 'Aisha');
      expect(feed.presence, hasLength(2));
    });
  });

  group('eta (rough "on the way" estimate — matches the web estimateEta)', () {
    // ~2.2 km due north of Home's centre; toEdge ≈ 2123 m after the 100 m radius.
    const movingLat = 43.22;
    const movingLng = 76.8;

    test('a moving member gets a sane estimate to the nearest place', () {
      final eta = estimateEta(movingLat, movingLng, 10, _home);
      expect(eta, isNotNull);
      // 2123 m / 10 m/s ≈ 212 s.
      expect(eta!.seconds, closeTo(212, 5));
      expect(eta.placeName, 'Home');
      expect(eta.distanceToEdgeMeters, closeTo(2123, 20));
    });

    test('below the ~0.5 m/s speed floor there is no estimate (not moving)', () {
      // MUTATION GUARD: drop the `speed < minSpeedMps` check and this passes a
      // non-null estimate — a parked phone would sprout a bogus ETA.
      expect(estimateEta(movingLat, movingLng, 0.3, _home), isNull);
    });

    test('an unknown speed yields no estimate', () {
      expect(estimateEta(movingLat, movingLng, null, _home), isNull);
    });

    test('already inside the geofence yields no estimate', () {
      // MUTATION GUARD: drop the `toEdge <= 0` check and this returns a (negative)
      // estimate instead of null — "you are here" would read as "arriving".
      expect(estimateEta(43.2, 76.8, 10, _home), isNull);
    });

    test('too far/slow to matter (> 3 h) yields no estimate', () {
      // ~33 km away at 0.6 m/s ⇒ ~15 h ⇒ over the 3 h cap.
      expect(estimateEta(43.5, 76.8, 0.6, _home), isNull);
    });

    test('nearestEta picks the soonest place among several', () {
      // Closer to School (43.3,76.9) than Home when sitting between them, moving.
      final eta = nearestEta(43.29, 76.89, 10, const [_home, _school]);
      expect(eta, isNotNull);
      expect(eta!.placeName, 'School');
    });

    MemberPosition moving(String id, {String nick = 'Aisha'}) => MemberPosition(
      deviceId: id,
      nick: nick,
      fix: LocationFix(
        lat: movingLat,
        lng: movingLng,
        capturedAt: _t0,
        speed: 10,
      ),
    );

    test('the feed shows one ETA row per moving member when arrival is on', () {
      final feed = GeofenceFeedController().update(
        _snapshot([moving('d1')]),
        const [_home],
        _t0,
        arrivalActive: true,
      );
      expect(feed.etas, hasLength(1));
      expect(feed.etas.single.label, 'Aisha');
      expect(feed.etas.single.placeName, 'Home');
    });

    test(
      'no ETA rows when the arrival feature is off (the same gate as web)',
      () {
        final feed = GeofenceFeedController().update(
          _snapshot([moving('d1')]),
          const [_home],
          _t0,
          // arrivalActive defaults to false.
        );
        expect(feed.etas, isEmpty);
      },
    );

    test('a member already inside a place gets no ETA row', () {
      final feed = GeofenceFeedController().update(
        _snapshot([atHome('d1')]),
        const [_home],
        _t0,
        arrivalActive: true,
      );
      expect(feed.etas, isEmpty);
      expect(feed.presence, hasLength(1));
    });
  });

  group('lastCrossings (the per-tick hook feature 2 fires notifications from)', () {
    test('the seeding pass exposes no crossings — state is not news', () {
      final ctl = GeofenceFeedController();
      final feed = ctl.update(_snapshot([atHome('d1')]), const [_home], _t0);
      expect(feed.presence, hasLength(1)); // they ARE there
      expect(ctl.lastCrossings, isEmpty); // but there is nothing to announce
    });

    test('an enter after the seed shows up once, then clears next tick', () {
      final ctl = GeofenceFeedController();
      ctl.update(_snapshot([away('d1')]), const [_home], _t0); // seed: outside
      ctl.update(_snapshot([atHome('d1')]), const [_home], _t0); // arrives
      expect(ctl.lastCrossings, hasLength(1));
      expect(ctl.lastCrossings.single.kind, GeofenceKind.enter);
      expect(ctl.lastCrossings.single.label, 'Aisha');
      expect(ctl.lastCrossings.single.placeName, 'Home');

      // A tick where nothing changed exposes NOTHING, so a caller does not
      // re-notify "Aisha arrived" every poll while she sits at Home.
      ctl.update(_snapshot([atHome('d1')]), const [_home], _t0);
      expect(ctl.lastCrossings, isEmpty);
    });

    test('unlike events (a rolling window), it is only THIS tick', () {
      final ctl = GeofenceFeedController();
      ctl.update(_snapshot([away('d1')]), const [_home], _t0); // seed
      ctl.update(_snapshot([atHome('d1')]), const [_home], _t0); // enter
      final feed = ctl.update(_snapshot([atHome('d1')]), const [_home], _t0);
      expect(feed.events, hasLength(1)); // the arrival is still on display
      expect(ctl.lastCrossings, isEmpty); // but it is no longer "new"
    });
  });

  test('an empty picture is empty (the panel hides itself)', () {
    final feed = GeofenceFeedController().update(const {}, const [], _t0);
    expect(feed.isEmpty, isTrue);
  });
}
