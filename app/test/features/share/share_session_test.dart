import 'dart:typed_data';

import 'package:aul/src/data/api/models.dart';
import 'package:aul/src/features/share/share_session.dart';
import 'package:flutter_test/flutter_test.dart';

ShareSession _session({
  String id = 'abc',
  required DateTime expiresAt,
  bool revoked = false,
  bool viewerBound = false,
}) => ShareSession(
  id: id,
  createdAt: expiresAt.subtract(const Duration(minutes: 15)),
  expiresAt: expiresAt,
  viewerBound: viewerBound,
  revoked: revoked,
);

void main() {
  group('shareLink', () {
    test('is <origin>/s/<id>#<base64url(K_share)>', () {
      expect(
        shareLink('https://aul.example', 'sess-1', 'AAAA_BBB-CCC'),
        'https://aul.example/s/sess-1#AAAA_BBB-CCC',
      );
    });

    test('a trailing slash on the origin does not double up', () {
      expect(
        shareLink('https://aul.example/', 'sess-1', 'KEY'),
        'https://aul.example/s/sess-1#KEY',
      );
    });

    test('the key rides in the fragment — never the path or the query', () {
      final link = shareLink('https://aul.example', 'sess-1', 'SECRET-KEY');
      final uri = Uri.parse(link);
      expect(uri.fragment, 'SECRET-KEY');
      expect(uri.path, '/s/sess-1');
      expect(uri.query, isEmpty);
    });
  });

  group('base64url', () {
    test('round-trips 32 key bytes unpadded', () {
      final raw = Uint8List.fromList(List.generate(32, (i) => i * 7 % 256));
      final encoded = toBase64Url(raw);

      expect(encoded, isNot(contains('=')));
      expect(encoded, isNot(contains('+')));
      expect(encoded, isNot(contains('/')));
      expect(fromBase64Url(encoded), raw);
    });

    test('decodes what a link fragment carries back to 32 bytes', () {
      final raw = Uint8List.fromList(List.filled(32, 0xFF));
      expect(fromBase64Url(toBase64Url(raw)).length, 32);
    });
  });

  group('isShareLive', () {
    final now = DateTime.utc(2026, 7, 15, 12);

    test('is live before the deadline', () {
      expect(
        isShareLive(
          _session(expiresAt: now.add(const Duration(minutes: 1))),
          now,
        ),
        isTrue,
      );
    });

    test('is dead at and after the deadline', () {
      expect(isShareLive(_session(expiresAt: now), now), isFalse);
      expect(
        isShareLive(
          _session(expiresAt: now.subtract(const Duration(seconds: 1))),
          now,
        ),
        isFalse,
      );
    });

    test('a revoked session is dead even with time left', () {
      expect(
        isShareLive(
          _session(expiresAt: now.add(const Duration(hours: 1)), revoked: true),
          now,
        ),
        isFalse,
      );
    });
  });

  group('msUntilDeadline', () {
    final now = DateTime.utc(2026, 7, 15, 12);

    test('counts down to the deadline', () {
      expect(
        msUntilDeadline(now.add(const Duration(seconds: 90)), now),
        90 * 1000,
      );
    });

    test('floors at zero rather than going negative', () {
      expect(msUntilDeadline(now.subtract(const Duration(hours: 5)), now), 0);
    });

    test('fails CLOSED on a missing deadline', () {
      // Reads as expired: garbage in must stop a share, never extend one.
      expect(msUntilDeadline(null, now), 0);
    });

    test('is timezone-agnostic (compares instants, not wall clocks)', () {
      final deadline = now.add(const Duration(minutes: 10));
      expect(
        msUntilDeadline(deadline.toLocal(), now),
        msUntilDeadline(deadline, now),
      );
    });
  });

  group('formatCountdown', () {
    test('is mm:ss under an hour', () {
      expect(formatCountdown(9 * 60000 + 7000), '09:07');
      expect(formatCountdown(59 * 60000 + 59000), '59:59');
    });

    test('rolls over to h:mm:ss at an hour', () {
      expect(formatCountdown(3600 * 1000), '1:00:00');
      expect(formatCountdown(3661 * 1000), '1:01:01');
    });

    test('rounds up, so a live share never reads 00:00', () {
      expect(formatCountdown(1), '00:01');
      expect(formatCountdown(400), '00:01');
    });

    test('an expired share reads 00:00', () {
      expect(formatCountdown(0), '00:00');
      expect(formatCountdown(-5000), '00:00');
    });
  });

  group('ttl choices', () {
    test('are 15/30/60 min, and the server cap is the longest offered', () {
      expect(kShareTtlChoicesSeconds, [900, 1800, 3600]);
      expect(kShareTtlChoicesSeconds.last, 3600); // the server clamps here
      expect(kShareTtlChoicesSeconds, contains(kShareTtlDefaultSeconds));
    });

    test('every choice is inside the server range 60..3600', () {
      for (final c in kShareTtlChoicesSeconds) {
        expect(c, greaterThanOrEqualTo(60));
        expect(c, lessThanOrEqualTo(3600));
      }
    });
  });

  group('ShareSession.fromJson', () {
    test('reads the server contract', () {
      final s = ShareSession.fromJson({
        'id': 'sess-1',
        'created_at': '2026-07-15T12:00:00Z',
        'expires_at': '2026-07-15T12:15:00Z',
        'viewer_bound': true,
        'revoked': false,
      });
      expect(s.id, 'sess-1');
      expect(s.expiresAt, DateTime.utc(2026, 7, 15, 12, 15));
      expect(s.viewerBound, isTrue);
      expect(s.revoked, isFalse);
    });

    test('missing flags default to not-bound, not-revoked', () {
      final s = ShareSession.fromJson({
        'id': 'sess-1',
        'created_at': '2026-07-15T12:00:00Z',
        'expires_at': '2026-07-15T12:15:00Z',
      });
      expect(s.viewerBound, isFalse);
      expect(s.revoked, isFalse);
    });
  });
}
