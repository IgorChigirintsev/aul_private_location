import 'package:aul/l10n/app_localizations.dart';
import 'package:aul/src/features/realtime/connection_banner.dart';
import 'package:aul/src/features/realtime/realtime_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [RealtimeController] whose connected flag the test drives directly — no
/// socket, no server. The real controller's [build] connects a client; this
/// override replaces it with a plain state the test can flip, which is all the
/// banner reads.
class _FakeRealtime extends RealtimeController {
  _FakeRealtime(this._connected, {DateTime? disconnectedSince})
    : _initialSince = disconnectedSince;

  final bool _connected;
  final DateTime? _initialSince;

  @override
  RealtimeSignals build() => RealtimeSignals(
    connected: _connected,
    disconnectedSince: _initialSince,
  );

  void setConnected(bool connected) =>
      state = state.copyWith(connected: connected);
}

const _pausedText = 'Live updates paused — reconnecting…';
const _pausedIcon = Icons.cloud_off_outlined;

void main() {
  Widget harness(
    ProviderContainer container, {
    Duration showDelay = Duration.zero,
  }) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: ConnectionBanner(showDelay: showDelay)),
    ),
  );

  ProviderContainer containerConnected() {
    final container = ProviderContainer(
      overrides: [realtimeProvider.overrideWith(() => _FakeRealtime(true))],
    );
    addTearDown(container.dispose);
    return container;
  }

  _FakeRealtime realtimeOf(ProviderContainer c) =>
      c.read(realtimeProvider.notifier) as _FakeRealtime;

  testWidgets(
    'the disconnect flag flips a visible banner, and reconnect hides it',
    (tester) async {
      final container = containerConnected();
      await tester.pumpWidget(harness(container));

      // Socket up: the app is live, so there is nothing to own up to.
      expect(find.byIcon(_pausedIcon), findsNothing);
      expect(find.text(_pausedText), findsNothing);

      // The socket drops. An offline/unreachable server can't announce itself, so
      // the client concludes it from its own connection state.
      realtimeOf(container).setConnected(false);
      await tester.pump(); // rebuild + arm the (zero-delay) reveal
      await tester.pump(const Duration(milliseconds: 1)); // fire it + rebuild
      expect(find.byIcon(_pausedIcon), findsOneWidget);
      expect(find.text(_pausedText), findsOneWidget);

      // Back on the socket: the banner disappears at once.
      realtimeOf(container).setConnected(true);
      await tester.pump();
      expect(find.byIcon(_pausedIcon), findsNothing);
      expect(find.text(_pausedText), findsNothing);
    },
  );

  testWidgets('a blip shorter than the delay never flashes the banner', (
    tester,
  ) async {
    final container = containerConnected();
    // A real cold-start connect (or a momentary drop) must stay silent.
    await tester.pumpWidget(
      harness(container, showDelay: const Duration(seconds: 4)),
    );

    realtimeOf(container).setConnected(false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2)); // still within the grace
    expect(find.byIcon(_pausedIcon), findsNothing);

    // Reconnects before the delay elapses — the arming timer is cancelled and the
    // banner is never shown.
    realtimeOf(container).setConnected(true);
    await tester.pump(const Duration(seconds: 3));
    expect(find.byIcon(_pausedIcon), findsNothing);
  });

  testWidgets('an outage that outlasts the delay does show the banner', (
    tester,
  ) async {
    final container = containerConnected();
    await tester.pumpWidget(
      harness(container, showDelay: const Duration(seconds: 4)),
    );

    realtimeOf(container).setConnected(false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5)); // past the grace
    expect(find.byIcon(_pausedIcon), findsOneWidget);
  });

  testWidgets(
    'the offline banner says HOW stale the map may be (last connected N ago)',
    (tester) async {
      // Disconnected 14 minutes ago — the load-bearing staleness readout for a
      // safety app, so a viewer never trusts a frozen map as live.
      final since = DateTime.now().subtract(const Duration(minutes: 14));
      final container = ProviderContainer(
        overrides: [
          realtimeProvider.overrideWith(
            () => _FakeRealtime(false, disconnectedSince: since),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(harness(container)); // zero reveal delay
      await tester.pump(const Duration(milliseconds: 1));

      expect(find.text(_pausedText), findsOneWidget);
      // The staleness line, carrying the age (EN default locale).
      expect(
        find.textContaining('Locations may be stale'),
        findsOneWidget,
      );
      expect(find.textContaining('14 min ago'), findsOneWidget);
    },
  );
}
