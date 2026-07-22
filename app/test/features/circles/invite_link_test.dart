import 'dart:typed_data';

import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:aul/src/features/circles/invite_link.dart';
import 'package:flutter_test/flutter_test.dart';

/// A key of the right length whose bytes are distinctive enough that a mangled
/// round-trip shows up as a byte mismatch rather than a lucky pass.
Uint8List _key32() =>
    Uint8List.fromList(List.generate(32, (i) => (i * 7 + 3) & 0xFF));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the generated link parses with the app\'s OWN join logic', () {
    // THE property: an invite this app creates must be joinable by this app (and
    // by the web, which reads the same shape). A generator that agrees only with
    // itself would ship a link nobody can use.
    test('round-trips: build → parse → the same id and the same key bytes', () {
      final key = _key32();
      final link = inviteLink('https://aul.example', 'inv-123', key);

      final parsed = parseInviteLink(link, keyBytes: 32);
      expect(parsed, isA<InviteLinkOk>());
      final parts = (parsed as InviteLinkOk).parts;
      expect(parts.inviteId, 'inv-123');
      expect(parts.key, key);
    });

    test(
      'the link has the exact web shape: <origin>/i/<id>#<base64url(K_c)>',
      () {
        final link = inviteLink('https://aul.example', 'inv-123', _key32());
        expect(link, startsWith('https://aul.example/i/inv-123#'));

        final fragment = link.split('#')[1];
        // base64url, unpadded — the alphabet a URL fragment survives intact.
        expect(fragment, isNot(contains('=')));
        expect(fragment, isNot(contains('+')));
        expect(fragment, isNot(contains('/')));
        expect(fragment, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      },
    );

    test('the circle key is ONLY in the fragment — never in the path/query', () {
      final key = _key32();
      final link = inviteLink('https://aul.example', 'inv-123', key);
      final uri = Uri.parse(link);
      // What the server would ever see of this URL: everything before the '#'.
      final serverVisible = link.substring(0, link.indexOf('#'));
      expect(serverVisible, 'https://aul.example/i/inv-123');
      expect(uri.query, isEmpty);
      expect(uri.path, '/i/inv-123');
      // The key material appears nowhere but the fragment.
      expect(serverVisible.contains(uri.fragment), isFalse);
    });

    test('a real 32-byte libsodium key survives the round-trip', () async {
      final crypto = await AulCrypto.load();
      final key = crypto.generateCircleKey();
      final raw = key.extractBytes();
      key.dispose();

      final parsed = parseInviteLink(
        inviteLink('https://aul.example', 'inv-9', raw),
        keyBytes: crypto.circleKeyBytes,
      );
      expect((parsed as InviteLinkOk).parts.key, raw);
    });

    test('a trailing slash on the server URL does not double up', () {
      final link = inviteLink('https://aul.example/', 'inv-1', _key32());
      expect(link, startsWith('https://aul.example/i/inv-1#'));
      expect(parseInviteLink(link, keyBytes: 32), isA<InviteLinkOk>());
    });

    test('a pasted link with surrounding whitespace still parses', () {
      final link = inviteLink('https://aul.example', 'inv-1', _key32());
      expect(parseInviteLink('  $link\n', keyBytes: 32), isA<InviteLinkOk>());
    });

    test('any host and any path prefix are accepted', () {
      final key = _key32();
      for (final origin in [
        'http://localhost:8080',
        'https://aul.example',
        'https://example.org/aul',
      ]) {
        final parsed = parseInviteLink(
          inviteLink(origin, 'inv-1', key),
          keyBytes: 32,
        );
        expect((parsed as InviteLinkOk).parts.inviteId, 'inv-1');
      }
    });
  });

  group('rejections carry the reason', () {
    InviteLinkError? errorOf(String raw) {
      final r = parseInviteLink(raw, keyBytes: 32);
      return r is InviteLinkFailed ? r.error : null;
    }

    test('a link that is not an invite', () {
      expect(
        errorOf('https://aul.example/s/abc#xyz'),
        InviteLinkError.notAnInvite,
      );
      expect(errorOf('https://aul.example/'), InviteLinkError.notAnInvite);
      expect(errorOf('nonsense'), InviteLinkError.notAnInvite);
      expect(errorOf('https://aul.example/i/'), InviteLinkError.notAnInvite);
    });

    test('an invite with no key fragment is useless, and says so', () {
      expect(
        errorOf('https://aul.example/i/inv-1'),
        InviteLinkError.missingKey,
      );
      expect(
        errorOf('https://aul.example/i/inv-1#'),
        InviteLinkError.missingKey,
      );
    });

    test('a fragment that is not a 32-byte key is malformed', () {
      // Right alphabet, wrong length.
      expect(
        errorOf('https://aul.example/i/inv-1#abcd'),
        InviteLinkError.malformedKey,
      );
      // Not base64 at all.
      expect(
        errorOf('https://aul.example/i/inv-1#!!!!'),
        InviteLinkError.malformedKey,
      );
      // 31 bytes: one short is still wrong.
      final short = inviteLink(
        'https://aul.example',
        'inv-1',
        Uint8List.fromList(List.filled(31, 1)),
      );
      expect(errorOf(short), InviteLinkError.malformedKey);
    });
  });
}
