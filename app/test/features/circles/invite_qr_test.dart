import 'dart:typed_data';

import 'package:aul/src/features/circles/invite_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// A 32-byte key with distinctive bytes, so the fragment is realistically long.
Uint8List _key32() =>
    Uint8List.fromList(List.generate(32, (i) => (i * 7 + 3) & 0xFF));

void main() {
  testWidgets('the invite QR builds from the real link without throwing', (
    tester,
  ) async {
    // The EXACT string the app encodes: <origin>/i/<id>#<base64url(K_c)>.
    final link = inviteLink('https://aul.example', 'inv-123', _key32());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: QrImageView(data: link, version: QrVersions.auto, size: 200),
          ),
        ),
      ),
    );

    // It built and painted the link's QR — no encode/layout exception.
    expect(tester.takeException(), isNull);
    expect(find.byType(QrImageView), findsOneWidget);
  });
}
