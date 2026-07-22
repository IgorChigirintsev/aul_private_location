import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

/// Safety codes let two people verify, out of band, that no server-injected
/// man-in-the-middle has substituted keys. Both devices independently derive the
/// SAME code from BOTH parties' X25519 public keys and compare it in person.
///
/// This is a byte-for-byte mirror of the Go implementation
/// (server/internal/crypto/safetycode.go), canonical scheme "aul-safety-code:v1":
///
///   low, high = sort(pubA, pubB)                       // lexicographic bytes
///   digest    = SHA256("aul-safety-code:v1" || 0x00 || low || high)
///   emoji[i]  = alphabet[digest[i] % 64]               // for i in 0..length
///
/// SHA-256 is used (not a libsodium-only primitive) precisely so the fingerprint
/// is trivially identical across Go, Dart and JS. It is validated against the
/// committed cross-language vectors in /vectors/crypto-vectors.json.
class SafetyCode {
  SafetyCode(this.emojis, this.digest);

  final List<String> emojis;
  final Uint8List digest;

  static const int publicKeyLength = 32;
  static const int length = 10;
  static const String _domain = 'aul-safety-code:v1';

  /// Canonical 64-emoji alphabet (index 0..63), frozen for v1. Must match the
  /// Go `SafetyEmojiAlphabet` exactly.
  static const List<String> alphabet = [
    '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', //
    '🐨', '🐯', '🦁', '🐮', '🐷', '🐸', '🐵', '🐔',
    '🐧', '🐦', '🦆', '🦉', '🐴', '🦄', '🐝', '🐛',
    '🦋', '🐌', '🐞', '🐢', '🐍', '🐙', '🐠', '🐬',
    '🐳', '🐘', '🐫', '🐑', '🍎', '🍊', '🍋', '🍌',
    '🍉', '🍇', '🍓', '🍒', '🍑', '🍅', '🌽', '🥕',
    '🍔', '🍕', '🍩', '🍪', '🎂', '🍫', '🍭', '🌵',
    '🌲', '🌸', '🌻', '🌈', '🌙', '🔥', '🌊', '💧',
  ];

  /// Derives the canonical safety code from two X25519 public keys. The result
  /// is independent of argument order.
  static SafetyCode compute(Uint8List pubA, Uint8List pubB) {
    if (pubA.length != publicKeyLength || pubB.length != publicKeyLength) {
      throw ArgumentError('public key must be $publicKeyLength bytes');
    }
    var low = pubA;
    var high = pubB;
    if (_compareBytes(pubA, pubB) > 0) {
      low = pubB;
      high = pubA;
    }
    final input = <int>[...ascii.encode(_domain), 0x00, ...low, ...high];
    final digest = Uint8List.fromList(c.sha256.convert(input).bytes);

    final emojis = <String>[
      for (var i = 0; i < length; i++) alphabet[digest[i] % 64],
    ];
    return SafetyCode(emojis, digest);
  }

  /// Emoji code, space-separated.
  String get display => emojis.join(' ');

  /// First 8 digest bytes as grouped hex (accessible alternative to emoji).
  String get hexFallback {
    final h = _hex(digest.sublist(0, 8));
    final parts = <String>[];
    for (var i = 0; i < h.length; i += 4) {
      parts.add(h.substring(i, i + 4));
    }
    return parts.join('-');
  }
}

int _compareBytes(Uint8List a, Uint8List b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

String _hex(List<int> bytes) {
  const digits = '0123456789abcdef';
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(digits[(b >> 4) & 0xf]);
    sb.write(digits[b & 0xf]);
  }
  return sb.toString();
}
