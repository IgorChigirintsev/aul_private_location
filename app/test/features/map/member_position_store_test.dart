import 'package:aul/src/domain/location_fix.dart';
import 'package:aul/src/features/map/member_position_store.dart';
import 'package:aul/src/features/map/member_positions.dart';
import 'package:flutter_test/flutter_test.dart';

LocationFix _fix(DateTime at, {double lat = 1, int? battery}) =>
    LocationFix(lat: lat, lng: 2, battery: battery, capturedAt: at);

MemberPosition _pos(
  String deviceId,
  DateTime at, {
  double lat = 1,
  String nick = 'Aisha',
  String precisionMode = 'precise',
}) => MemberPosition(
  deviceId: deviceId,
  fix: _fix(at, lat: lat),
  userId: 'user-$deviceId',
  platform: 'android',
  precisionMode: precisionMode,
  nick: nick,
  email: 'a@example.org',
);

final _t0 = DateTime.utc(2026, 7, 15, 12);

void main() {
  late MemberPositionStore store;

  setUp(() => store = MemberPositionStore());
  tearDown(() => store.dispose());

  group('the newest capture per device wins — the rule both producers share', () {
    test('a live fix newer than what we hold is applied', () {
      store.bulk({'dev': _pos('dev', _t0, lat: 1)});
      store.applyFix('dev', _fix(_t0.add(const Duration(seconds: 5)), lat: 9));
      expect(store.positions['dev']!.fix.lat, 9);
    });

    test('an OLDER live fix is ignored (out-of-order delivery is safe)', () {
      store.bulk({'dev': _pos('dev', _t0, lat: 1)});
      store.applyFix(
        'dev',
        _fix(_t0.subtract(const Duration(minutes: 1)), lat: 9),
      );
      expect(
        store.positions['dev']!.fix.lat,
        1,
        reason: 'a late-arriving old ping must not walk the marker backwards',
      );
    });

    test('the SAME capture applied twice is a no-op — no double-apply', () async {
      // The socket delivers a ping; the next poll returns the very same ping.
      // This is the overlap the store exists to absorb.
      store.applyFix('dev', _fix(_t0, lat: 5));
      final emitted = <Map<String, MemberPosition>>[];
      store.stream.listen(emitted.add);

      store.applyFix('dev', _fix(_t0, lat: 5));
      store.applyFix('dev', _fix(_t0, lat: 5));
      // The stream is a broadcast controller: it delivers on a later microtask,
      // so a synchronous expect here would pass whether or not it emitted.
      await pumpEventQueue();

      expect(store.positions['dev']!.fix.lat, 5);
      expect(
        emitted,
        isEmpty,
        reason: 'a re-delivered position must not churn the map',
      );
    });
  });

  group('poll snapshots', () {
    test('a poll decides WHO is in the picture: a dropped device goes', () {
      store.bulk({'a': _pos('a', _t0), 'b': _pos('b', _t0)});
      store.bulk({'a': _pos('a', _t0)});
      expect(store.positions.keys, ['a']);
    });

    test('a poll brings fresh METADATA over a live fix', () {
      // The socket moved the marker, then the poll answers with an older fix but
      // a newer nickname (they renamed themselves in this circle).
      store.applyFix('dev', _fix(_t0.add(const Duration(minutes: 1)), lat: 9));
      store.bulk({'dev': _pos('dev', _t0, lat: 1, nick: 'Aisha Renamed')});

      final pos = store.positions['dev']!;
      expect(pos.nick, 'Aisha Renamed', reason: 'poll metadata wins');
      expect(
        pos.fix.lat,
        9,
        reason:
            'the newer LIVE fix survives a poll that answers with a stale one',
      );
      expect(pos.userId, 'user-dev', reason: 'the whole join is taken');
    });

    test('a poll with a NEWER fix replaces the live one wholesale', () {
      store.applyFix('dev', _fix(_t0, lat: 9));
      store.bulk({
        'dev': _pos('dev', _t0.add(const Duration(minutes: 1)), lat: 3),
      });
      expect(store.positions['dev']!.fix.lat, 3);
    });

    test('a paused member from the poll keeps their precision mode', () {
      // This is what greys the marker out, and it only ever comes from the poll —
      // a ping event has no idea whether its sender has since paused.
      store.bulk({'dev': _pos('dev', _t0, precisionMode: 'paused')});
      store.applyFix('dev', _fix(_t0.add(const Duration(seconds: 30))));
      expect(store.positions['dev']!.isPaused, isTrue);
    });
  });

  group('a device seen live before it was ever polled', () {
    test('shows up immediately, labelled by device id', () {
      store.applyFix('new-dev', _fix(_t0));
      final pos = store.positions['new-dev']!;
      expect(pos.deviceId, 'new-dev');
      expect(pos.label, 'new-dev', reason: 'no join yet — fall back to the id');
      expect(pos.userId, isNull);
      // Unknown ⇒ treated as live, same as buildMemberPositions and the web.
      expect(pos.isPaused, isFalse);
    });

    test('is dressed properly by the next poll', () {
      store.applyFix('dev', _fix(_t0.add(const Duration(minutes: 5)), lat: 9));
      store.bulk({'dev': _pos('dev', _t0)});
      final pos = store.positions['dev']!;
      expect(pos.label, 'Aisha');
      expect(pos.fix.lat, 9, reason: 'still the newest fix');
    });
  });

  group('stream + lifecycle', () {
    test('emits a snapshot on each real change', () async {
      final emitted = <Map<String, MemberPosition>>[];
      store.stream.listen(emitted.add);

      store.bulk({'a': _pos('a', _t0)});
      store.applyFix('a', _fix(_t0.add(const Duration(seconds: 1))));
      await pumpEventQueue();

      expect(emitted, hasLength(2));
      expect(emitted.last.keys, ['a']);
    });

    test('reset clears everything (a circle switch)', () async {
      store.bulk({'a': _pos('a', _t0)});
      store.reset();
      expect(store.positions, isEmpty);
      // Nothing to clear ⇒ nothing to announce.
      final emitted = <Map<String, MemberPosition>>[];
      store.stream.listen(emitted.add);
      store.reset();
      await pumpEventQueue();
      expect(emitted, isEmpty);
    });

    test('positions is a snapshot the caller cannot mutate', () {
      store.bulk({'a': _pos('a', _t0)});
      expect(() => store.positions.remove('a'), throwsUnsupportedError);
    });

    test('writes after dispose are ignored rather than throwing', () {
      store.bulk({'a': _pos('a', _t0)});
      store.dispose();
      expect(() => store.applyFix('a', _fix(_t0)), returnsNormally);
      expect(() => store.bulk({'b': _pos('b', _t0)}), returnsNormally);
      expect(store.dispose, returnsNormally);
    });
  });
}
