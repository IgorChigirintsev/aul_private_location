import 'dart:convert';

import 'package:aul/src/data/api/models.dart';
import 'package:aul/src/domain/location_fix.dart';
import 'package:aul/src/features/circles/circles_dashboard_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 1×1 transparent PNG data URL — enough to exercise the avatar path.
const _pngDataUrl =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

CircleSummary _circle(
  String id, {
  String role = 'member',
  String precisionMode = 'precise',
}) => CircleSummary(
  id: id,
  role: role,
  keyEpoch: 1,
  retentionDays: 7,
  precisionMode: precisionMode,
  nameEnc: 'sealed-$id',
);

Member _member(String userId, String email, {String? profileEnc}) => Member(
  userId: userId,
  email: email,
  role: 'member',
  precisionMode: 'precise',
  joinedAt: DateTime.utc(2026, 1, 1),
  profileEnc: profileEnc,
);

/// Builds rows against per-circle fixtures. Each lookup is keyed by circle id, so
/// a row that reached for the "selected" circle's data would resolve the WRONG
/// nickname/avatar/mutes and fail the expectations.
Future<List<CircleDashboardRow>> _build({
  required List<CircleSummary> circles,
  String? myUserId = 'me',
  Map<String, String> names = const {},
  Map<String, List<Member>> members = const {},
  Map<String, Mutes> mutes = const {},
  List<String>? profileOpenLog,
}) => buildCircleDashboardRows(
  circles: circles,
  myUserId: myUserId,
  decodeName: (c) async => names[c.id],
  membersOf: (circleId) async => members[circleId] ?? const [],
  openProfile: (circleId, profileEnc) async {
    profileOpenLog?.add(circleId);
    if (profileEnc == null) return null;
    // Stand in for K_c: a profile only opens under ITS OWN circle's key, so a
    // blob is tagged with the circle it was sealed for.
    final m = jsonDecode(profileEnc) as Map<String, dynamic>;
    if (m['circle'] != circleId) return null; // wrong key ⇒ won't open
    return (nick: (m['nick'] as String?) ?? '', avatar: m['avatar'] as String?);
  },
  mutesOf: (circleId) async => mutes[circleId] ?? Mutes.none,
);

String _profile(String circleId, {String? nick, String? avatar}) =>
    jsonEncode({'circle': circleId, 'nick': nick, 'avatar': avatar});

void main() {
  group('CircleDashboardRow resolves each circle from ITS OWN state', () {
    test(
      'name, nick and avatar come from the row\'s circle, not the first',
      () async {
        final rows = await _build(
          circles: [_circle('c1'), _circle('c2')],
          names: const {'c1': 'Family', 'c2': 'Work'},
          members: {
            'c1': [
              _member(
                'me',
                'me@example.com',
                profileEnc: _profile('c1', nick: 'Dad', avatar: _pngDataUrl),
              ),
            ],
            'c2': [
              _member(
                'me',
                'me@example.com',
                profileEnc: _profile('c2', nick: 'Igor C.'),
              ),
            ],
          },
        );

        expect(rows, hasLength(2));
        // Each row shows the nickname the user chose in THAT circle.
        expect(rows[0].name, 'Family');
        expect(rows[0].nick, 'Dad');
        expect(rows[0].avatarBytes, isNotNull);

        expect(rows[1].name, 'Work');
        expect(rows[1].nick, 'Igor C.');
        // No avatar set in c2 — it must NOT inherit c1's.
        expect(rows[1].avatarBytes, isNull);
      },
    );

    test(
      'each row is opened with its OWN circle id (per-circle keyring)',
      () async {
        final opened = <String>[];
        await _build(
          circles: [_circle('c1'), _circle('c2'), _circle('c3')],
          members: {
            'c1': [
              _member(
                'me',
                'me@example.com',
                profileEnc: _profile('c1', nick: 'A'),
              ),
            ],
            'c2': [
              _member(
                'me',
                'me@example.com',
                profileEnc: _profile('c2', nick: 'B'),
              ),
            ],
            'c3': [
              _member(
                'me',
                'me@example.com',
                profileEnc: _profile('c3', nick: 'C'),
              ),
            ],
          },
          profileOpenLog: opened,
        );
        expect(opened, ['c1', 'c2', 'c3']);
      },
    );

    test('each row shows THAT circle\'s own precision_mode', () async {
      final rows = await _build(
        circles: [
          _circle('c1', precisionMode: 'precise'),
          _circle('c2', precisionMode: 'paused'),
          _circle('c3', precisionMode: 'city'),
        ],
      );

      // Three circles, three different modes, all at once — the arrangement the
      // old single global control could not express.
      expect(rows[0].precision, PrecisionMode.precise);
      expect(rows[1].precision, PrecisionMode.paused);
      expect(rows[2].precision, PrecisionMode.city);

      // `visible` keeps meaning exactly what the old on/off switch meant, so the
      // row still tells the truth about who sees anything at all.
      expect(rows[0].visible, isTrue);
      // Paused ⇒ nothing shared, and the circle greys this member's marker.
      expect(rows[1].visible, isFalse);
      // City is still sharing — coarser, but seen.
      expect(rows[2].visible, isTrue);
    });

    test('an unknown mode from a newer server degrades to precise', () async {
      final rows = await _build(
        circles: [_circle('c1', precisionMode: 'zoned')],
      );
      expect(rows[0].precision, PrecisionMode.precise);
      expect(rows[0].visible, isTrue);
    });

    test('mute state is that circle\'s own, not another\'s', () async {
      final rows = await _build(
        circles: [_circle('c1'), _circle('c2')],
        mutes: const {
          'c1': Mutes(circleMuted: true),
          'c2': Mutes(circleMuted: false, mutedUserIds: ['u9']),
        },
      );
      expect(rows[0].circleMuted, isTrue);
      expect(rows[1].circleMuted, isFalse);
      // The per-member mutes ride along with the row that owns them.
      expect(rows[1].mutes.isMemberMuted('u9'), isTrue);
      expect(rows[0].mutes.isMemberMuted('u9'), isFalse);
    });

    test(
      'an unreadable mute set fails OPEN (never renders as muted)',
      () async {
        final rows = await _build(circles: [_circle('c1')]); // no mutes fixture
        expect(rows.single.circleMuted, isFalse);
      },
    );

    test('a profile sealed for another circle does not open here', () async {
      final rows = await _build(
        circles: [_circle('c2')],
        names: const {'c2': 'Work'},
        members: {
          // Sealed under c1's key — c2's keyring must not open it.
          'c2': [
            _member(
              'me',
              'me@example.com',
              profileEnc: _profile('c1', nick: 'Dad'),
            ),
          ],
        },
      );
      expect(rows.single.nick, isNull);
      expect(rows.single.name, 'Work');
    });

    test('picks the caller\'s own member row, not another member\'s', () async {
      final rows = await _build(
        circles: [_circle('c1')],
        members: {
          'c1': [
            _member(
              'other',
              'alice@example.com',
              profileEnc: _profile('c1', nick: 'Alice'),
            ),
            _member(
              'me',
              'me@example.com',
              profileEnc: _profile('c1', nick: 'Dad'),
            ),
          ],
        },
      );
      expect(rows.single.nick, 'Dad');
    });

    test(
      'no nickname set in a circle leaves nick null (UI shows the fallback)',
      () async {
        final rows = await _build(
          circles: [_circle('c1')],
          names: const {'c1': 'Family'},
          members: {
            'c1': [_member('me', 'me@example.com')], // no profile at all
          },
        );
        expect(rows.single.nick, isNull);
        expect(rows.single.avatarBytes, isNull);
      },
    );

    test('a blank nickname is treated as unset', () async {
      final rows = await _build(
        circles: [_circle('c1')],
        members: {
          'c1': [
            _member(
              'me',
              'me@example.com',
              profileEnc: _profile('c1', nick: '   '),
            ),
          ],
        },
      );
      expect(rows.single.nick, isNull);
    });

    test(
      'an undecodable circle name leaves name null (UI shows the fallback)',
      () async {
        final rows = await _build(circles: [_circle('c1')], names: const {});
        expect(rows.single.name, isNull);
      },
    );

    test('without a known user id, no member profile is borrowed', () async {
      final rows = await _build(
        circles: [_circle('c1')],
        myUserId: null,
        members: {
          'c1': [
            _member(
              'other',
              'alice@example.com',
              profileEnc: _profile('c1', nick: 'Alice'),
            ),
          ],
        },
      );
      expect(rows.single.nick, isNull);
    });

    test('the owner badge follows the row\'s own role', () async {
      final rows = await _build(
        circles: [
          _circle('c1', role: 'owner'),
          _circle('c2'),
        ],
      );
      expect(rows[0].isOwner, isTrue);
      expect(rows[1].isOwner, isFalse);
    });

    test('no circles ⇒ no rows', () async {
      expect(await _build(circles: const []), isEmpty);
    });
  });
}
