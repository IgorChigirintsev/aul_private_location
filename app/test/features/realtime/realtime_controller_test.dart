import 'package:aul/src/controller.dart';
import 'package:aul/src/data/secret_store.dart';
import 'package:aul/src/features/realtime/realtime_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The realtime controller against a signed-OUT session — the state every app
/// launch starts in, and the one where a socket has nothing to connect to.
///
/// The socket itself is exercised in realtime_client_test.dart against a fake
/// channel; what matters here is that merely watching the provider is safe and
/// silent, since the home screen watches it unconditionally.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [
        // No device keystore in a test; nothing is stored, so `_restore` finds
        // no session and settles on signed-out.
        secretStoreProvider.overrideWithValue(InMemorySecretStore()),
      ],
    );
  });

  tearDown(() => container.dispose());

  test(
    'signed out: watching it is inert — no circle, nothing to connect to',
    () {
      final signals = container.read(realtimeProvider);
      expect(signals.connected, isFalse);
      expect(signals.sos, 0);
      expect(signals.places, 0);
      expect(signals.members, 0);
    },
  );

  test(
    'the position store starts empty and is shared, not rebuilt per read',
    () {
      final store = container.read(memberPositionStoreProvider);
      expect(store.positions, isEmpty);
      // The map and the members screen must read the SAME store, or a position
      // delivered to one would be invisible to the other.
      expect(
        identical(container.read(memberPositionStoreProvider), store),
        isTrue,
      );
    },
  );

  test('disposing the container closes the store rather than leaking it', () {
    final store = container.read(memberPositionStoreProvider);
    container.dispose();
    // Disposed: writes are ignored instead of throwing (the stream is closed).
    expect(() => store.bulk(const {}), returnsNormally);
  });
}
