import 'dart:convert';

import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:aul/src/crypto/ping_codec.dart';
import 'package:aul/src/data/api/models.dart';
import 'package:aul/src/domain/location_fix.dart';
import 'package:aul/src/features/map/member_positions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';

/// A 1×1 transparent PNG as a data URL — a minimal valid avatar to exercise the
/// data-URL → bytes decode path.
const _pngDataUrl =
    'data:image/png;base64,'
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AulCrypto crypto;
  late PingCodec codec;
  setUpAll(() async {
    crypto = await AulCrypto.load();
    codec = PingCodec(crypto);
  });

  /// Seals [fix] under [key] into the RemotePing shape the server relays.
  RemotePing sealedPing(String deviceId, LocationFix fix, SecureKey key) {
    final blob = codec.seal(fix, key);
    return RemotePing(
      deviceId: deviceId,
      nonceB64: base64.encode(blob.nonce),
      ciphertextB64: base64.encode(blob.ciphertext),
      capturedAt: fix.capturedAt,
    );
  }

  LocationFix fixAt(double lat, double lng, DateTime at) => LocationFix(
    lat: lat,
    lng: lng,
    accuracy: 10,
    battery: 70,
    capturedAt: at,
  );

  test('decrypts each ping into a position keyed by device', () {
    final key = crypto.generateCircleKey();
    final t = DateTime.utc(2026, 7, 14, 9);
    final pings = [
      sealedPing('devA', fixAt(43.238, 76.889, t), key),
      sealedPing('devB', fixAt(51.5, -0.12, t), key),
    ];

    final out = buildMemberPositions(
      pings: pings,
      codec: codec,
      circleKeys: [key],
    );

    expect(out.keys, unorderedEquals(['devA', 'devB']));
    expect(out['devA']!.fix.lat, closeTo(43.238, 1e-9));
    expect(out['devA']!.fix.lng, closeTo(76.889, 1e-9));
    expect(out['devB']!.fix.lat, closeTo(51.5, 1e-9));
  });

  test('joins device platform + profile nick/avatar/email for the marker', () {
    final key = crypto.generateCircleKey();
    final t = DateTime.utc(2026, 7, 14, 9);
    final out = buildMemberPositions(
      pings: [sealedPing('devA', fixAt(1, 2, t), key)],
      codec: codec,
      circleKeys: [key],
      devicesById: {
        'devA': const CircleDevice(id: 'devA', userId: 'u1', platform: 'web'),
      },
      profilesByUserId: {'u1': (nick: 'Alice', avatar: _pngDataUrl)},
      emailsByUserId: {'u1': 'alice@example.com'},
    );

    final pos = out['devA']!;
    expect(pos.userId, 'u1');
    expect(pos.platform, 'web');
    expect(pos.isPc, isTrue); // web ⇒ PC tag
    expect(pos.nick, 'Alice');
    expect(pos.label, 'Alice');
    expect(pos.initial, 'A');
    expect(pos.avatarBytes, isNotNull);
    expect(pos.avatarBytes, isNotEmpty);
  });

  test('label falls back to email, then device id; phone tag for android', () {
    final key = crypto.generateCircleKey();
    final t = DateTime.utc(2026, 7, 14, 9);
    final out = buildMemberPositions(
      pings: [
        sealedPing('withEmail', fixAt(1, 1, t), key),
        sealedPing('bare', fixAt(2, 2, t), key),
      ],
      codec: codec,
      circleKeys: [key],
      devicesById: {
        'withEmail': const CircleDevice(
          id: 'withEmail',
          userId: 'u2',
          platform: 'android',
        ),
      },
      emailsByUserId: {'u2': 'bob@example.com'},
    );

    // Device in roster, no profile ⇒ email label + phone tag.
    expect(out['withEmail']!.label, 'bob@example.com');
    expect(out['withEmail']!.isPc, isFalse);
    // Device NOT in roster ⇒ empty platform, label falls back to the device id.
    expect(out['bare']!.platform, '');
    expect(out['bare']!.label, 'bare');
  });

  test('flags a paused member from the members list, not from their ping', () {
    final key = crypto.generateCircleKey();
    final t = DateTime.utc(2026, 7, 14, 9);

    // Both members have a decodable last position. Only the members list — server
    // metadata, always current — says who is still sharing: a paused reporter
    // stops sending, so its last ping still looks exactly like a live one.
    final out = buildMemberPositions(
      pings: [
        sealedPing('devPaused', fixAt(43.238, 76.889, t), key),
        sealedPing('devLive', fixAt(51.5, -0.12, t), key),
      ],
      codec: codec,
      circleKeys: [key],
      devicesById: {
        'devPaused': const CircleDevice(
          id: 'devPaused',
          userId: 'uPaused',
          platform: 'android',
        ),
        'devLive': const CircleDevice(
          id: 'devLive',
          userId: 'uLive',
          platform: 'android',
        ),
      },
      precisionByUserId: {'uPaused': 'paused', 'uLive': 'precise'},
    );

    final paused = out['devPaused']!;
    expect(paused.precisionMode, 'paused');
    expect(paused.isPaused, isTrue);
    // The pin must STAY at the last place they shared — greyed out, never moved
    // or dropped.
    expect(paused.fix.lat, closeTo(43.238, 1e-9));
    expect(paused.fix.lng, closeTo(76.889, 1e-9));

    expect(out['devLive']!.isPaused, isFalse);
    expect(out['devLive']!.precisionMode, 'precise');
  });

  test('city mode is live; unknown/absent precision defaults to live', () {
    final key = crypto.generateCircleKey();
    final t = DateTime.utc(2026, 7, 14, 9);

    final out = buildMemberPositions(
      pings: [
        sealedPing('devCity', fixAt(1, 1, t), key),
        sealedPing('devUnknown', fixAt(2, 2, t), key),
        sealedPing('devNoRoster', fixAt(3, 3, t), key),
      ],
      codec: codec,
      circleKeys: [key],
      devicesById: {
        'devCity': const CircleDevice(
          id: 'devCity',
          userId: 'uCity',
          platform: 'android',
        ),
        'devUnknown': const CircleDevice(
          id: 'devUnknown',
          userId: 'uMissing',
          platform: 'android',
        ),
      },
      precisionByUserId: {'uCity': 'city'},
    );

    // Coarse sharing is still sharing — not greyed out.
    expect(out['devCity']!.isPaused, isFalse);
    // Owner absent from the members list ⇒ treat as live, not paused.
    expect(out['devUnknown']!.isPaused, isFalse);
    // Device not in the roster at all ⇒ no userId ⇒ still live.
    expect(out['devNoRoster']!.userId, isNull);
    expect(out['devNoRoster']!.isPaused, isFalse);
  });

  test('silently skips pings that do not decrypt under the key', () {
    final key = crypto.generateCircleKey();
    final wrongKey = crypto.generateCircleKey();
    final t = DateTime.utc(2026, 7, 14, 9);

    final pings = [
      sealedPing('good', fixAt(10, 20, t), key),
      // Sealed under a different key — must be dropped, not throw.
      sealedPing('wrongKey', fixAt(30, 40, t), wrongKey),
      // Structurally garbage base64 — must also be dropped.
      RemotePing(
        deviceId: 'garbage',
        nonceB64: 'not-base64-!!',
        ciphertextB64: 'also-garbage',
        capturedAt: t,
      ),
    ];

    final out = buildMemberPositions(
      pings: pings,
      codec: codec,
      circleKeys: [key],
    );

    expect(out.keys, ['good']);
    expect(out['good']!.fix.lat, closeTo(10, 1e-9));
  });

  test('rotation-safe: decrypts pings sealed under any key in the ring', () {
    final oldKey = crypto.generateCircleKey();
    final newKey = crypto.generateCircleKey();
    final t = DateTime.utc(2026, 7, 14, 9);

    // A ping from before a rotation (oldKey) and one after it (newKey).
    final out = buildMemberPositions(
      pings: [
        sealedPing('preRotate', fixAt(43.238, 76.889, t), oldKey),
        sealedPing('postRotate', fixAt(51.5, -0.12, t), newKey),
      ],
      codec: codec,
      circleKeys: [oldKey, newKey], // full ring
    );

    expect(out.keys, unorderedEquals(['preRotate', 'postRotate']));
    expect(out['preRotate']!.fix.lat, closeTo(43.238, 1e-9));
    expect(out['postRotate']!.fix.lat, closeTo(51.5, 1e-9));
  });

  test('keeps the newest capture when a device has multiple pings', () {
    final key = crypto.generateCircleKey();
    final older = DateTime.utc(2026, 7, 14, 9);
    final newer = DateTime.utc(2026, 7, 14, 10);

    // Older AFTER newer in list order — the newer capture must still win.
    final out = buildMemberPositions(
      pings: [
        sealedPing('dev', fixAt(60, 60, newer), key),
        sealedPing('dev', fixAt(10, 10, older), key),
      ],
      codec: codec,
      circleKeys: [key],
    );

    expect(out.length, 1);
    expect(out['dev']!.fix.lat, closeTo(60, 1e-9));
    expect(out['dev']!.fix.capturedAt, newer);
  });

  test('decodeAvatarDataUrl handles null and malformed input', () {
    expect(decodeAvatarDataUrl(null), isNull);
    expect(decodeAvatarDataUrl('no-comma-here'), isNull);
    expect(decodeAvatarDataUrl(_pngDataUrl), isNotNull);
  });

  group('battery + freshness are threaded through from the sealed ping', () {
    test('battery survives the decrypt and reaches the position model', () {
      final key = crypto.generateCircleKey();
      final t = DateTime.utc(2026, 7, 14, 9);
      final out = buildMemberPositions(
        pings: [
          sealedPing(
            'dev',
            LocationFix(lat: 43.2, lng: 76.8, battery: 42, capturedAt: t),
            key,
          ),
        ],
        codec: codec,
        circleKeys: [key],
      );

      // It rode inside the ciphertext: the server relayed it without seeing it.
      expect(out['dev']!.battery, 42);
      expect(out['dev']!.updatedAt, t, reason: 'the fix timestamp, not now()');
    });

    test('a reporter that sends no battery yields null, not a fake zero', () {
      final key = crypto.generateCircleKey();
      final out = buildMemberPositions(
        pings: [
          sealedPing(
            'dev',
            LocationFix(
              lat: 43.2,
              lng: 76.8,
              capturedAt: DateTime.utc(2026, 7, 14),
            ),
            key,
          ),
        ],
        codec: codec,
        circleKeys: [key],
      );
      // Null means "they didn't say", which the UI shows as nothing at all. Zero
      // would mean "flat", and would light the row up red.
      expect(out['dev']!.battery, isNull);
    });

    test('a CITY-mode member still reports battery', () {
      final key = crypto.generateCircleKey();
      final precise = LocationFix(
        lat: 43.238949,
        lng: 76.889709,
        battery: 42,
        speed: 3,
        capturedAt: DateTime.utc(2026, 7, 14),
      );
      final out = buildMemberPositions(
        pings: [sealedPing('dev', precise.forMode(PrecisionMode.city), key)],
        codec: codec,
        circleKeys: [key],
      );

      // Coarsening hides WHERE you are, which is the point of city mode. Battery
      // is not a location signal, and the web reporter has always sent it in city
      // mode — dropping it here left city members blank on the web dashboard.
      expect(out['dev']!.battery, 42);
      expect(out['dev']!.fix.mode, PrecisionMode.city);
      expect(
        out['dev']!.fix.speed,
        isNull,
        reason: 'movement IS location detail',
      );
      expect(out['dev']!.fix.lat, closeTo(43.24, 1e-9));
    });

    test('copyWith swaps the fix and keeps the whole join', () {
      final key = crypto.generateCircleKey();
      final out = buildMemberPositions(
        pings: [
          sealedPing('dev', fixAt(1, 1, DateTime.utc(2026, 7, 14, 9)), key),
        ],
        codec: codec,
        circleKeys: [key],
        devicesById: {
          'dev': CircleDevice(id: 'dev', userId: 'u1', platform: 'web'),
        },
        profilesByUserId: {'u1': (nick: 'Aisha', avatar: _pngDataUrl)},
        emailsByUserId: {'u1': 'a@example.org'},
        precisionByUserId: {'u1': 'paused'},
      );

      final moved = out['dev']!.copyWith(
        fix: LocationFix(
          lat: 9,
          lng: 9,
          battery: 12,
          capturedAt: DateTime.utc(2026, 7, 14, 10),
        ),
      );

      // This is the path a realtime ping takes: it carries a device id and a fix
      // and nothing else, so everything else must survive from the last poll.
      expect(moved.fix.lat, 9);
      expect(moved.battery, 12);
      expect(moved.nick, 'Aisha');
      expect(moved.email, 'a@example.org');
      expect(moved.userId, 'u1');
      expect(moved.isPc, isTrue);
      expect(moved.isPaused, isTrue);
      expect(moved.avatarBytes, isNotNull);
    });
  });

  group('positionsByUser — positions arrive per device, people are per user', () {
    MemberPosition posFor(String deviceId, String? userId, DateTime at) =>
        MemberPosition(
          deviceId: deviceId,
          fix: LocationFix(lat: 1, lng: 2, capturedAt: at),
          userId: userId,
        );

    test('a member with two devices is represented by the fresher one', () {
      final phone = posFor('phone', 'u1', DateTime.utc(2026, 7, 14, 10));
      final laptop = posFor('laptop', 'u1', DateTime.utc(2026, 7, 14, 9));
      final byUser = positionsByUser({'laptop': laptop, 'phone': phone});
      expect(byUser.keys, ['u1']);
      expect(byUser['u1']!.deviceId, 'phone');
    });

    test('ordering does not decide it — the timestamp does', () {
      final phone = posFor('phone', 'u1', DateTime.utc(2026, 7, 14, 10));
      final laptop = posFor('laptop', 'u1', DateTime.utc(2026, 7, 14, 9));
      expect(
        positionsByUser({'phone': phone, 'laptop': laptop})['u1']!.deviceId,
        'phone',
      );
    });

    test('each member gets their OWN position, never a neighbour\'s', () {
      final byUser = positionsByUser({
        'a': posFor('a', 'u1', DateTime.utc(2026, 7, 14, 10)),
        'b': posFor('b', 'u2', DateTime.utc(2026, 7, 14, 9)),
      });
      expect(byUser['u1']!.deviceId, 'a');
      expect(byUser['b'], isNull);
      expect(byUser['u2']!.deviceId, 'b');
    });

    test('a position with no known owner is dropped', () {
      // The device roster didn't resolve (offline mid-join). An unattributable
      // pin cannot be put on anyone's row — showing it against a guess would be
      // worse than showing nothing.
      final byUser = positionsByUser({
        'orphan': posFor('orphan', null, DateTime.utc(2026, 7, 14)),
      });
      expect(byUser, isEmpty);
    });
  });
}
