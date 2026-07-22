import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Message keys in an ARB file: every top-level key that is not metadata
/// (`@key` descriptions) nor the `@@locale` marker.
Set<String> _messageKeys(String path) {
  final json =
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return json.keys.where((k) => !k.startsWith('@')).toSet();
}

void main() {
  test('app_en.arb and app_ru.arb declare the same message keys', () {
    final en = _messageKeys('lib/l10n/app_en.arb');
    final ru = _messageKeys('lib/l10n/app_ru.arb');

    // Neither locale should be missing or have extra keys — a mismatch means a
    // string was added/removed in one language but not the other.
    final missingInRu = en.difference(ru);
    final missingInEn = ru.difference(en);

    expect(
      missingInRu,
      isEmpty,
      reason: 'Keys present in EN but missing from RU: $missingInRu',
    );
    expect(
      missingInEn,
      isEmpty,
      reason: 'Keys present in RU but missing from EN: $missingInEn',
    );
    expect(en, isNotEmpty);
  });
}
