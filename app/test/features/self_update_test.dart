import 'dart:convert';

import 'package:aul/src/features/self_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('verifyApkSha256', () {
    final bytes = utf8.encode('hello');
    // Known SHA-256 of "hello".
    const good =
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';

    test('accepts a matching digest (case-insensitive)', () {
      expect(verifyApkSha256(bytes, good), isTrue);
      expect(verifyApkSha256(bytes, good.toUpperCase()), isTrue);
    });

    test('rejects a mismatched digest', () {
      expect(verifyApkSha256(bytes, 'de' * 32), isFalse);
    });

    test('rejects a wrong-length digest', () {
      expect(verifyApkSha256(bytes, 'abcd'), isFalse);
    });
  });
}
