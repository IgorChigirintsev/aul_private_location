import 'dart:convert';
import 'dart:typed_data';

import 'package:aul/src/crypto/aul_crypto.dart';
import 'package:aul/src/crypto/profile_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AulCrypto crypto;
  late ProfileCodec codec;

  setUpAll(() async {
    crypto = await AulCrypto.load();
    codec = ProfileCodec(crypto);
  });

  test('round-trips a nickname + avatar under the same key', () {
    final key = crypto.generateCircleKey();
    const avatar = 'data:image/jpeg;base64,/9j/AAAA';
    final b64 = codec.seal(nick: 'Ata', avatar: avatar, key: key);
    final p = codec.open(b64, key);
    expect(p, isNotNull);
    expect(p!.nick, 'Ata');
    expect(p.avatar, avatar);
  });

  test('omits the avatar when none is set (keeps the blob small)', () {
    final key = crypto.generateCircleKey();
    final withAvatar = codec.seal(
      nick: 'Ata',
      avatar: 'data:image/jpeg;base64,/9j/AAAA',
      key: key,
    );
    final noAvatar = codec.seal(nick: 'Ata', key: key);
    expect(noAvatar.length, lessThan(withAvatar.length));
    final p = codec.open(noAvatar, key);
    expect(p, isNotNull);
    expect(p!.nick, 'Ata');
    expect(p.avatar, isNull);
  });

  test('preserves an empty nickname (falls back to the email in the UI)', () {
    final key = crypto.generateCircleKey();
    final p = codec.open(codec.seal(nick: '', key: key), key);
    expect(p, isNotNull);
    expect(p!.nick, '');
    expect(p.avatar, isNull);
  });

  test('wrong key → null', () {
    final b64 = codec.seal(nick: 'Ata', key: crypto.generateCircleKey());
    expect(codec.open(b64, crypto.generateCircleKey()), isNull);
  });

  test('never throws on malformed input → null', () {
    final key = crypto.generateCircleKey();
    expect(codec.open('not base64 !!!', key), isNull);
    expect(codec.open('', key), isNull);
  });

  test('cross-AD: a place-sealed blob does NOT open as a profile', () {
    final key = crypto.generateCircleKey();
    // Seal the same JSON under a DIFFERENT associated data ("aul-place:v1").
    final wrongAd = Uint8List.fromList(utf8.encode('aul-place:v1'));
    final framed = crypto.sealFramed(
      Uint8List.fromList(utf8.encode('{"nick":"Ata"}')),
      key,
      ad: wrongAd,
    );
    expect(codec.open(base64.encode(framed), key), isNull);
  });

  test('circle-name form (no AD) does NOT open as a profile', () {
    final key = crypto.generateCircleKey();
    // The circle name is sealed with a null AD; it must not open as a profile.
    final framed = crypto.sealFramed(
      Uint8List.fromList(utf8.encode('{"nick":"Ata"}')),
      key,
    );
    expect(codec.open(base64.encode(framed), key), isNull);
  });
}
