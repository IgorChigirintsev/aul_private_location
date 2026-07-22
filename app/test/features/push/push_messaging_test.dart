import 'dart:convert';
import 'dart:typed_data';

import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:aul/src/crypto/notify_codec.dart';
import 'package:aul/src/data/key_vault.dart';
import 'package:aul/src/data/secret_store.dart';
import 'package:aul/src/features/notifications/notification_service.dart';
import 'package:aul/src/features/push/push_messaging.dart';
import 'package:aul/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';

import '../retention/fake_notification_service.dart';

/// The receiving half of the notify loop: a data-only FCM message carries the
/// SAME sealed blob the sender staples together (notify_relay_test covers the
/// sending half), and it is opened on-device or not rendered at all.
///
/// The rule under test, stated once: **anything we cannot decrypt shows
/// nothing.** Not the ciphertext, not a generic line. Every "shows nothing"
/// expectation below is that rule in a different disguise.
void main() {
  late AulCrypto crypto;
  late AppLocalizations l10n;

  setUpAll(() async {
    crypto = await AulCrypto.load();
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  /// A vault holding [keys] as circle key rings, one circle per entry.
  Future<KeyVault> vaultWith(Map<String, List<Uint8List>> circles) async {
    final vault = KeyVault(InMemorySecretStore());
    for (final e in circles.entries) {
      for (final k in e.value) {
        await vault.addCircleKey(e.key, k);
      }
    }
    return vault;
  }

  Uint8List randomKey() => crypto.generateCircleKey().extractBytes();

  String seal(NotifyPayload p, Uint8List keyBytes) {
    final key = crypto.circleKeyFromBytes(keyBytes);
    try {
      return NotifyCodec(crypto).seal(p, key);
    } finally {
      key.dispose();
    }
  }

  final payload = NotifyPayload(
    kind: NotifyKind.arrival,
    place: 'Home',
    who: 'Ann',
    ts: 1700000000000,
  );

  group('handleNotifyData — decrypts and renders', () {
    test('opens a blob sealed under a circle key this device holds', () async {
      final k = randomKey();
      final vault = await vaultWith({
        'circle-1': [k],
      });
      final notifications = FakeNotificationService();

      final shown = await handleNotifyData(
        {'payload_enc': seal(payload, k)},
        notifications: notifications,
        crypto: crypto,
        vault: vault,
        l10n: l10n,
      );

      expect(shown, isTrue);
      expect(notifications.shown, hasLength(1));
      // The plaintext was produced HERE, from bytes the server could not read.
      expect(notifications.shown.single.body, 'Ann arrived at Home');
      expect(notifications.shown.single.title, 'Circle update');
    });

    test('renders a departure with the "left" string', () async {
      final k = randomKey();
      final vault = await vaultWith({
        'circle-1': [k],
      });
      final notifications = FakeNotificationService();

      await handleNotifyData(
        {
          'payload_enc': seal(
            NotifyPayload(
              kind: NotifyKind.departure,
              place: 'School',
              who: 'Bob',
              ts: 1700000000000,
            ),
            k,
          ),
        },
        notifications: notifications,
        crypto: crypto,
        vault: vault,
        l10n: l10n,
      );

      expect(notifications.shown.single.body, 'Bob left School');
    });

    test('finds the right key among many circles', () async {
      // The push says nothing about which circle it belongs to — that is the
      // metadata Aul refuses to leak — so the receiver must try the whole bunch.
      final target = randomKey();
      final vault = await vaultWith({
        'circle-1': [randomKey(), randomKey()],
        'circle-2': [randomKey()],
        'circle-3': [randomKey(), target],
      });
      final notifications = FakeNotificationService();

      final shown = await handleNotifyData(
        {'payload_enc': seal(payload, target)},
        notifications: notifications,
        crypto: crypto,
        vault: vault,
        l10n: l10n,
      );

      expect(shown, isTrue);
      expect(notifications.shown.single.body, 'Ann arrived at Home');
    });

    test('opens a blob sealed under a PRE-rotation key', () async {
      // Rotation-safe: a push carries no key epoch, and a blob sealed just
      // before a rotation must still open after it.
      final old = randomKey();
      final blob = seal(payload, old);
      final vault = await vaultWith({
        'circle-1': [old, randomKey()], // oldest → newest; sealed under oldest
      });
      final notifications = FakeNotificationService();

      expect(
        await handleNotifyData(
          {'payload_enc': blob},
          notifications: notifications,
          crypto: crypto,
          vault: vault,
          l10n: l10n,
        ),
        isTrue,
      );
    });
  });

  group('handleNotifyData — shows NOTHING when it cannot decrypt', () {
    /// Every case here must render nothing at all.
    Future<void> expectSilent(
      String reason,
      Map<String, dynamic> data,
      KeyVault vault,
    ) async {
      final notifications = FakeNotificationService();
      final shown = await handleNotifyData(
        data,
        notifications: notifications,
        crypto: crypto,
        vault: vault,
        l10n: l10n,
      );
      expect(shown, isFalse, reason: reason);
      expect(notifications.shown, isEmpty, reason: reason);
    }

    test('wrong key — a circle this device has no key for', () async {
      final blob = seal(payload, randomKey()); // sealed under a key we lack
      await expectSilent(
        'a blob we hold no key for must not be rendered',
        {'payload_enc': blob},
        await vaultWith({
          'circle-1': [randomKey()],
        }),
      );
    });

    test('no keys at all — signed out', () async {
      await expectSilent(
        'a signed-out device must render nothing',
        {'payload_enc': seal(payload, randomKey())},
        KeyVault(InMemorySecretStore()),
      );
    });

    test('malformed — not base64', () async {
      await expectSilent(
        'garbage must not be rendered',
        {'payload_enc': 'this is not base64 !!!'},
        await vaultWith({
          'circle-1': [randomKey()],
        }),
      );
    });

    test('malformed — base64 of random bytes', () async {
      await expectSilent(
        'an unauthenticated blob must not be rendered',
        {'payload_enc': base64.encode(List.filled(64, 7))},
        await vaultWith({
          'circle-1': [randomKey()],
        }),
      );
    });

    test('truncated — shorter than a nonce', () async {
      await expectSilent(
        'a truncated blob must not crash or render',
        {'payload_enc': base64.encode(List.filled(4, 1))},
        await vaultWith({
          'circle-1': [randomKey()],
        }),
      );
    });

    test('tampered ciphertext — authentic prefix, flipped byte', () async {
      final k = randomKey();
      final blob = base64.decode(seal(payload, k));
      blob[blob.length - 1] ^= 0xff; // break the Poly1305 tag
      await expectSilent(
        'a tampered blob must fail the AEAD tag and render nothing',
        {'payload_enc': base64.encode(blob)},
        await vaultWith({
          'circle-1': [k],
        }),
      );
    });

    test('wrong associated data — a place blob is not a notify blob', () async {
      // Domain separation: sealing with a different AD must not open here, or a
      // ciphertext of one type could be replayed as another.
      final k = randomKey();
      final key = crypto.circleKeyFromBytes(k);
      final foreign = base64.encode(
        crypto.sealFramed(
          Uint8List.fromList(utf8.encode('{"t":"arrival"}')),
          key,
          ad: Uint8List.fromList(utf8.encode('aul-place:v1')),
        ),
      );
      key.dispose();
      await expectSilent(
        'a blob sealed with another AD must not open as a notify',
        {'payload_enc': foreign},
        await vaultWith({
          'circle-1': [k],
        }),
      );
    });

    test('authentic but malformed plaintext', () async {
      // Correctly sealed under our key, but the JSON is not a payload. There is
      // nothing truthful to render.
      final k = randomKey();
      final key = crypto.circleKeyFromBytes(k);
      final blob = base64.encode(
        crypto.sealFramed(
          Uint8List.fromList(utf8.encode('{"t":"not-a-kind"}')),
          key,
          ad: Uint8List.fromList(utf8.encode('aul-notify:v1')),
        ),
      );
      key.dispose();
      await expectSilent(
        'an authentic but malformed payload must render nothing',
        {'payload_enc': blob},
        await vaultWith({
          'circle-1': [k],
        }),
      );
    });

    test('missing / empty / non-string payload_enc', () async {
      final vault = await vaultWith({
        'circle-1': [randomKey()],
      });
      await expectSilent('no payload_enc key', const {}, vault);
      await expectSilent('empty payload_enc', {'payload_enc': ''}, vault);
      await expectSilent('non-string payload_enc', {'payload_enc': 42}, vault);
      // A data-only message with no blob at all: the server never sends this,
      // but a notification-key message would land here and must stay silent.
      await expectSilent('unrelated data keys only', {
        'title': 'Ann arrived at Home',
      }, vault);
    });

    test('a corrupt vault entry costs only that circle', () async {
      // One unreadable circle must not deny the user every other circle's
      // notifications.
      final good = randomKey();
      final store = InMemorySecretStore();
      await store.put('circle_key_broken', '!!! not base64 !!!');
      final vault = KeyVault(store);
      await vault.addCircleKey('circle-good', good);

      final notifications = FakeNotificationService();
      expect(
        await handleNotifyData(
          {'payload_enc': seal(payload, good)},
          notifications: notifications,
          crypto: crypto,
          vault: vault,
          l10n: l10n,
        ),
        isTrue,
      );
      expect(notifications.shown, hasLength(1));
    });
  });

  group('pushSlot — mirrors the web service worker\'s notification tag', () {
    NotifyPayload p(NotifyKind kind, String who, String place) =>
        NotifyPayload(kind: kind, place: place, who: who, ts: 1);

    test(
      'same person + place + kind reuses the slot (replaces, not stacks)',
      () {
        // ts deliberately differs: a re-arrival must replace the stale line.
        expect(
          pushSlot(p(NotifyKind.arrival, 'Ann', 'Home')),
          pushSlot(
            NotifyPayload(
              kind: NotifyKind.arrival,
              place: 'Home',
              who: 'Ann',
              ts: 999,
            ),
          ),
        );
      },
    );

    test('an arrival is not erased by a departure', () {
      expect(
        pushSlot(p(NotifyKind.arrival, 'Ann', 'Home')),
        isNot(pushSlot(p(NotifyKind.departure, 'Ann', 'Home'))),
      );
    });

    test('two people are two notifications', () {
      expect(
        pushSlot(p(NotifyKind.arrival, 'Ann', 'Home')),
        isNot(pushSlot(p(NotifyKind.arrival, 'Bob', 'Home'))),
      );
    });

    test('stays clear of the fixed reminder slots', () {
      for (final who in ['Ann', 'Bob', 'Zoë', '', 'x' * 64]) {
        final slot = pushSlot(p(NotifyKind.arrival, who, 'Home'));
        expect(slot, greaterThanOrEqualTo(NotifId.pushBase));
        expect(slot, lessThan(NotifId.pushBase + NotifId.pushSlots));
        // Never collides with a tracking reminder / arrival alert.
        expect(slot, isNot(NotifId.arrival));
        expect(slot, isNot(NotifId.trackingOff));
      }
    });
  });
}
