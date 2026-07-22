import 'dart:convert';
import 'dart:typed_data';

import 'package:aul/l10n/app_localizations.dart';
import 'package:aul/src/controller.dart';
import 'package:aul/src/crypto/safety_code.dart';
import 'package:aul/src/data/api/models.dart';
import 'package:aul/src/features/circles/verify_devices_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 32-byte X25519 public key stub filled with [b] — enough for SafetyCode
/// (it only hashes the bytes; it never does real curve maths).
Uint8List _pub(int b) =>
    Uint8List(SafetyCode.publicKeyLength)..fillRange(0, 32, b);

/// A hermetic controller that hands the verify screen a fixed identity, device
/// id, device roster and member list — no vault, crypto, or network.
class _FakeController extends AppController {
  _FakeController({
    required this.myPub,
    required this.deviceId,
    required this.devices,
    required this.members,
  });

  final Uint8List myPub;
  final String deviceId;
  final List<CircleDevice> devices;
  final List<Member> members;

  @override
  AppSession build() =>
      const AppSession(phase: AuthPhase.signedIn, email: 'me@example.com');

  @override
  Future<Uint8List?> myIdentityPublicKey() async => myPub;

  @override
  Future<String?> myDeviceId() async => deviceId;

  @override
  Future<List<CircleDevice>> devicesOf(String circleId) async => devices;

  @override
  Future<List<Member>> membersOf(String circleId) async => members;

  @override
  Future<({String nick, String? avatar})?> openMemberProfile(
    String circleId,
    String? profileEnc,
  ) async {
    if (profileEnc == null) return null;
    final m = jsonDecode(profileEnc) as Map<String, dynamic>;
    return (nick: (m['nick'] as String?) ?? '', avatar: m['avatar'] as String?);
  }
}

CircleDevice _device(
  String id,
  String userId,
  String platform,
  Uint8List? pub,
) => CircleDevice(
  id: id,
  userId: userId,
  platform: platform,
  pubkeyB64: pub == null ? null : base64.encode(pub),
);

Member _member(String userId, String email, {String? nick}) => Member(
  userId: userId,
  email: email,
  role: 'member',
  precisionMode: 'precise',
  joinedAt: DateTime.utc(2026, 1, 1),
  profileEnc: nick == null ? null : jsonEncode({'nick': nick}),
);

Widget _wrap(_FakeController fake, Widget child) => ProviderScope(
  overrides: [controllerProvider.overrideWith(() => fake)],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  ),
);

void main() {
  testWidgets(
    'verify screen renders a safety code per other device and excludes this device',
    (tester) async {
      final myPub = _pub(1);
      final alicePub = _pub(2);
      final bobPub = _pub(3);

      final fake = _FakeController(
        myPub: myPub,
        deviceId: 'my-device',
        devices: [
          // This device — same key, excluded by device id.
          _device('my-device', 'u-me', 'android', myPub),
          _device('d-alice', 'u-alice', 'android', alicePub),
          _device('d-bob', 'u-bob', 'ios', bobPub),
          // No published key — nothing to compare against, excluded.
          _device('d-carol', 'u-carol', 'web', null),
        ],
        members: [
          _member('u-alice', 'alice@example.com', nick: 'Alice'),
          _member('u-bob', 'bob@example.com'), // no nick → email fallback
          _member('u-me', 'me@example.com', nick: 'Me'),
        ],
      );

      await tester.pumpWidget(
        _wrap(fake, const VerifyDevicesScreen(circleId: 'c1')),
      );
      await tester.pumpAndSettle();

      // Exactly the two other keyed devices are shown (this device + the
      // keyless device are excluded).
      expect(find.byType(Card), findsNWidgets(2));

      // Labels: Alice's nickname, Bob's email fallback.
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('bob@example.com'), findsOneWidget);

      // Each shows the deterministic safety code derived from BOTH keys.
      final aliceCode = SafetyCode.compute(myPub, alicePub);
      final bobCode = SafetyCode.compute(myPub, bobPub);
      expect(find.text(aliceCode.display), findsOneWidget);
      expect(find.text(bobCode.display), findsOneWidget);
      expect(find.text(aliceCode.hexFallback), findsOneWidget);

      // This device is not verifiable against itself — its self-code is absent.
      final selfCode = SafetyCode.compute(myPub, myPub);
      expect(find.text(selfCode.display), findsNothing);
    },
  );

  testWidgets('verify screen shows the empty state when no other devices', (
    tester,
  ) async {
    final myPub = _pub(1);
    final fake = _FakeController(
      myPub: myPub,
      deviceId: 'my-device',
      devices: [_device('my-device', 'u-me', 'android', myPub)],
      members: const [],
    );

    await tester.pumpWidget(
      _wrap(fake, const VerifyDevicesScreen(circleId: 'c1')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Card), findsNothing);
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.verifyDevicesEmpty), findsOneWidget);
  });
}
