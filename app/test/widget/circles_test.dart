import 'dart:convert';

import 'package:aul/l10n/app_localizations.dart';
import 'package:aul/src/controller.dart';
import 'package:aul/src/data/api/models.dart';
import 'package:aul/src/features/circles/circle_switcher.dart';
import 'package:aul/src/features/circles/members_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A hermetic [AppController] that returns a fixed session and canned circle
/// names / members — no vault, crypto, or network. [openMemberProfile] decodes a
/// member's `profileEnc` treated as plain JSON (the tests seal nothing real).
class _FakeController extends AppController {
  _FakeController({
    required this.session,
    this.names = const {},
    this.members = const [],
    this.inviteLink,
  });

  final AppSession session;
  final Map<String, String> names;
  final List<Member> members;

  /// What [createInviteLink] returns; null models a failure (offline, refused,
  /// or no circle key on this device).
  final String? inviteLink;

  /// Circle ids [createInviteLink] was called with.
  final List<String> invitesCreated = [];

  @override
  AppSession build() => session;

  @override
  Future<String?> createInviteLink(String circleId, {int maxUses = 5}) async {
    invitesCreated.add(circleId);
    return inviteLink;
  }

  @override
  void selectCircle(String id) => state = state.copyWith(selectedCircleId: id);

  @override
  Future<String?> decodeCircleName(CircleSummary circle) async =>
      names[circle.id];

  @override
  Future<List<Member>> membersOf(String circleId) async => members;

  @override
  Future<({String nick, String? avatar})?> openMemberProfile(
    String circleId,
    String? profileEnc,
  ) async {
    if (profileEnc == null) return null;
    final m = jsonDecode(profileEnc) as Map<String, dynamic>;
    return (nick: (m['nick'] as String?) ?? '', avatar: m['avatar'] as String?);
  }
}

CircleSummary _circle(String id, {String role = 'member'}) => CircleSummary(
  id: id,
  role: role,
  keyEpoch: 1,
  retentionDays: 7,
  precisionMode: 'precise',
  nameEnc: 'ignored-in-tests',
);

Member _member(
  String userId,
  String email, {
  String role = 'member',
  String? profileEnc,
}) => Member(
  userId: userId,
  email: email,
  role: role,
  precisionMode: 'precise',
  joinedAt: DateTime.utc(2026, 1, 1),
  profileEnc: profileEnc,
);

Widget _wrap(_FakeController fake, Widget child) => ProviderScope(
  overrides: [controllerProvider.overrideWith(() => fake)],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  ),
);

void main() {
  // A 1×1 transparent PNG data URL — enough to exercise the avatar path without
  // relying on real image decoding.
  const pngDataUrl =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

  testWidgets(
    'members list renders nicknames, email fallback, avatar and (you)',
    (tester) async {
      final fake = _FakeController(
        session: const AppSession(
          phase: AuthPhase.signedIn,
          email: 'me@example.com',
        ),
        members: [
          _member(
            'u1',
            'alice@example.com',
            profileEnc: jsonEncode({
              'nick': 'Alice Wonder',
              'avatar': pngDataUrl,
            }),
          ),
          _member('u2', 'bob@example.com'), // no profile → email fallback
          _member(
            'u3',
            'me@example.com',
            profileEnc: jsonEncode({'nick': 'Me Myself'}),
          ),
        ],
      );

      await tester.pumpWidget(_wrap(fake, const MembersScreen(circleId: 'c1')));
      await tester.pumpAndSettle();

      // Nickname shown when set; email shown when no profile.
      expect(find.text('Alice Wonder'), findsOneWidget);
      expect(find.text('bob@example.com'), findsOneWidget);
      expect(find.text('Me Myself'), findsOneWidget);

      // The current user is marked "(you)".
      expect(find.text('(you)'), findsOneWidget);

      // Alice's avatar decodes to a MemoryImage-backed CircleAvatar.
      final withImage = tester
          .widgetList<CircleAvatar>(find.byType(CircleAvatar))
          .where((a) => a.backgroundImage is MemoryImage);
      expect(withImage, isNotEmpty);
    },
  );

  testWidgets('circle switcher lists circles and switches selection', (
    tester,
  ) async {
    final fake = _FakeController(
      session: AppSession(
        phase: AuthPhase.signedIn,
        circles: [
          _circle('c1', role: 'owner'),
          _circle('c2'),
        ],
        selectedCircleId: 'c1',
      ),
      names: const {'c1': 'Family', 'c2': 'Work'},
    );

    await tester.pumpWidget(
      _wrap(fake, Scaffold(appBar: AppBar(title: const CircleSwitcher()))),
    );
    await tester.pumpAndSettle();

    // The pill shows the current circle's decrypted name.
    expect(find.text('Family'), findsOneWidget);

    // Open the management sheet.
    await tester.tap(find.byType(CircleSwitcher));
    await tester.pumpAndSettle();

    // Both circles are listed (Family appears in pill + list), with the owner
    // badge and the switcher header.
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Family'), findsNWidgets(2));
    expect(find.text('owner'), findsOneWidget);

    // Switch to "Work": the sheet closes and the pill updates.
    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();
    expect(find.text('Work'), findsOneWidget); // now the pill
    expect(find.text('Family'), findsNothing); // no longer selected/listed
  });

  group('invite', () {
    const link =
        'https://aul.example/i/inv-123#F1sBBQ4TGh0kKzI5QEdOVVxjanF4f4aNlJuiqbC3';

    Future<void> openInvite(WidgetTester tester, _FakeController fake) async {
      await tester.pumpWidget(
        _wrap(fake, Scaffold(appBar: AppBar(title: const CircleSwitcher()))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CircleSwitcher));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Invite to your circle'));
      await tester.pumpAndSettle();
    }

    _FakeController fake({String? inviteLink = link}) => _FakeController(
      session: AppSession(
        phase: AuthPhase.signedIn,
        circles: [_circle('c1', role: 'owner')],
        selectedCircleId: 'c1',
      ),
      names: const {'c1': 'Family'},
      inviteLink: inviteLink,
    );

    testWidgets('the sheet offers an Invite action for the selected circle', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(fake(), Scaffold(appBar: AppBar(title: const CircleSwitcher()))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CircleSwitcher));
      await tester.pumpAndSettle();

      // Sat next to the other circle actions — an app-only user can now GROW a
      // circle, not just join one.
      expect(find.text('Invite to your circle'), findsOneWidget);
      expect(find.text('Share a link that lets someone join'), findsOneWidget);
    });

    testWidgets('it mints a link for the SELECTED circle and shows it', (
      tester,
    ) async {
      final f = fake();
      await openInvite(tester, f);

      expect(f.invitesCreated, ['c1']);
      expect(find.text(link), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets('the copy button puts the whole link on the clipboard', (
      tester,
    ) async {
      // Capture the platform clipboard call: the link is worthless without its
      // fragment, so a copy that dropped it would be a silent trap.
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await openInvite(tester, fake());
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();

      expect(copied, [link]);
      expect(copied.single, contains('#')); // the key rode along
      expect(find.text('Copied'), findsOneWidget);
    });

    testWidgets('the dialog says out loud what the link can do', (
      tester,
    ) async {
      await openInvite(tester, fake());

      // Not fine print: the key is in the fragment, and whoever holds the whole
      // link gets in.
      final note = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .firstWhere((s) => s.contains('Anyone with the whole link'));
      expect(note, contains('never receives'));
      expect(note, contains('only with family'));
    });

    testWidgets('a failure says so instead of showing a broken link', (
      tester,
    ) async {
      await openInvite(tester, fake(inviteLink: null));

      expect(find.text('Could not create an invite'), findsOneWidget);
      expect(find.text('Copy'), findsNothing);
    });
  });

  testWidgets('an owner sees the rotate-key item and the verify item', (
    tester,
  ) async {
    final owner = _FakeController(
      session: AppSession(
        phase: AuthPhase.signedIn,
        circles: [_circle('c1', role: 'owner')],
        selectedCircleId: 'c1',
      ),
      names: const {'c1': 'Family'},
    );
    await tester.pumpWidget(
      _wrap(owner, Scaffold(appBar: AppBar(title: const CircleSwitcher()))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CircleSwitcher));
    await tester.pumpAndSettle();

    expect(find.text('Rotate circle key'), findsOneWidget);
    expect(find.text('Verify devices'), findsOneWidget);
  });

  testWidgets('a member sees the verify item but not the owner-only rotate', (
    tester,
  ) async {
    final member = _FakeController(
      session: AppSession(
        phase: AuthPhase.signedIn,
        circles: [_circle('c2', role: 'member')],
        selectedCircleId: 'c2',
      ),
      names: const {'c2': 'Work'},
    );
    await tester.pumpWidget(
      _wrap(member, Scaffold(appBar: AppBar(title: const CircleSwitcher()))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CircleSwitcher));
    await tester.pumpAndSettle();

    expect(find.text('Rotate circle key'), findsNothing);
    expect(find.text('Verify devices'), findsOneWidget);
  });
}
