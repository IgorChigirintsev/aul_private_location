import 'dart:typed_data';

import 'package:aul/src/data/api/api_client.dart';
import 'package:aul/src/data/api/models.dart';
import 'package:aul/src/data/key_vault.dart';
import 'package:aul/src/data/secret_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Captures what the client PUT so the replace contract can be asserted on the
/// WIRE, not just on the helpers. Echoes the request body back the way the real
/// server does (it responds with what it stored).
class _FakeMutesAdapter implements HttpClientAdapter {
  _FakeMutesAdapter({this.getResponse, this.status = 200});

  /// Body returned for GET /mutes.
  final String? getResponse;
  final int status;

  final List<String> putBodies = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'PUT') {
      putBodies.add(options.data.toString());
      // The server echoes the stored state.
      final data = options.data as Map<String, dynamic>;
      return ResponseBody.fromString(
        '{"circle_muted":${data['circle_muted']},'
        '"muted_user_ids":${_jsonIds(data['muted_user_ids'] as List)}}',
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      getResponse ?? '{"circle_muted":false,"muted_user_ids":[]}',
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  static String _jsonIds(List ids) => '[${ids.map((i) => '"$i"').join(',')}]';

  @override
  void close({bool force = false}) {}
}

AulApi _api(_FakeMutesAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
  dio.httpClientAdapter = adapter;
  return AulApi(
    baseUrl: 'https://example.test',
    vault: KeyVault(InMemorySecretStore()),
    dio: dio,
  );
}

void main() {
  group('Mutes set helpers (mirror the web pure helpers)', () {
    test('withCircleMuted flips only the circle flag, keeping the members', () {
      const current = Mutes(circleMuted: false, mutedUserIds: ['u1', 'u2']);

      final muted = current.withCircleMuted(true);
      expect(muted.circleMuted, isTrue);
      expect(muted.mutedUserIds, ['u1', 'u2']);

      final unmuted = muted.withCircleMuted(false);
      expect(unmuted.circleMuted, isFalse);
      expect(unmuted.mutedUserIds, ['u1', 'u2']);
    });

    test('withMemberMuted adds a member, keeping the circle flag', () {
      const current = Mutes(circleMuted: true, mutedUserIds: ['u1']);
      final next = current.withMemberMuted('u2', true);
      expect(next.circleMuted, isTrue);
      expect(next.mutedUserIds, containsAll(['u1', 'u2']));
    });

    test('withMemberMuted removes a member without touching the others', () {
      const current = Mutes(mutedUserIds: ['u1', 'u2', 'u3']);
      final next = current.withMemberMuted('u2', false);
      expect(next.mutedUserIds, ['u1', 'u3']);
    });

    test('muting an already-muted member never duplicates the id', () {
      const current = Mutes(mutedUserIds: ['u1']);
      final next = current.withMemberMuted('u1', true);
      expect(next.mutedUserIds, ['u1']);
    });

    test('unmuting a member who is not muted is a no-op', () {
      const current = Mutes(mutedUserIds: ['u1']);
      expect(current.withMemberMuted('u9', false).mutedUserIds, ['u1']);
    });

    test('the helpers are pure — the receiver is never mutated', () {
      const current = Mutes(circleMuted: false, mutedUserIds: ['u1']);
      current.withMemberMuted('u2', true);
      current.withCircleMuted(true);
      expect(current.circleMuted, isFalse);
      expect(current.mutedUserIds, ['u1']);
    });

    test('isMemberMuted ignores the whole-circle flag', () {
      const m = Mutes(circleMuted: true, mutedUserIds: ['u1']);
      expect(m.isMemberMuted('u1'), isTrue);
      expect(m.isMemberMuted('u2'), isFalse);
    });

    test('Mutes.none is the fail-open default: nothing muted', () {
      expect(Mutes.none.circleMuted, isFalse);
      expect(Mutes.none.mutedUserIds, isEmpty);
    });
  });

  group('Mutes JSON', () {
    test('fromJson reads the server shape', () {
      final m = Mutes.fromJson({
        'circle_muted': true,
        'muted_user_ids': ['u1', 'u2'],
      });
      expect(m.circleMuted, isTrue);
      expect(m.mutedUserIds, ['u1', 'u2']);
    });

    test('fromJson tolerates a missing/absent set (older server)', () {
      final m = Mutes.fromJson({});
      expect(m.circleMuted, isFalse);
      expect(m.mutedUserIds, isEmpty);
    });

    test('toJson emits the wire keys', () {
      const m = Mutes(circleMuted: true, mutedUserIds: ['u1']);
      expect(m.toJson(), {
        'circle_muted': true,
        'muted_user_ids': ['u1'],
      });
    });
  });

  group('PUT /mutes is a REPLACE, not a patch', () {
    test('setMutes sends the COMPLETE desired state, not a delta', () async {
      final adapter = _FakeMutesAdapter();
      final api = _api(adapter);

      // Start from a set with two members muted, then add a third.
      const current = Mutes(circleMuted: true, mutedUserIds: ['u1', 'u2']);
      await api.setMutes('c1', current.withMemberMuted('u3', true));

      expect(adapter.putBodies, hasLength(1));
      final body = adapter.putBodies.single;
      // Every id the caller still wants muted must be on the wire: the server
      // replaces the whole set, so an omitted id would be silently UNmuted.
      expect(body, contains('u1'));
      expect(body, contains('u2'));
      expect(body, contains('u3'));
      expect(body, contains('circle_muted: true'));
    });

    test(
      'unmuting sends the remaining set, so the server drops just that one',
      () async {
        final adapter = _FakeMutesAdapter();
        final api = _api(adapter);

        const current = Mutes(mutedUserIds: ['u1', 'u2']);
        final stored = await api.setMutes(
          'c1',
          current.withMemberMuted('u1', false),
        );

        expect(adapter.putBodies.single, isNot(contains('u1')));
        expect(adapter.putBodies.single, contains('u2'));
        // The client settles on the server's echo of what it stored.
        expect(stored.mutedUserIds, ['u2']);
      },
    );

    test('the PUT is idempotent: repeating it sends the same state', () async {
      final adapter = _FakeMutesAdapter();
      final api = _api(adapter);

      const set = Mutes(circleMuted: false, mutedUserIds: ['u1']);
      final first = await api.setMutes('c1', set);
      final second = await api.setMutes('c1', first);

      expect(adapter.putBodies[0], adapter.putBodies[1]);
      expect(second.mutedUserIds, ['u1']);
      expect(second.circleMuted, isFalse);
    });

    test(
      'setMutes returns what the server stored, not what was hoped',
      () async {
        final adapter = _FakeMutesAdapter();
        final api = _api(adapter);
        final stored = await api.setMutes(
          'c1',
          const Mutes(circleMuted: true, mutedUserIds: ['u1']),
        );
        expect(stored.circleMuted, isTrue);
        expect(stored.mutedUserIds, ['u1']);
      },
    );

    test('mutes() reads the caller\'s own set', () async {
      final adapter = _FakeMutesAdapter(
        getResponse: '{"circle_muted":true,"muted_user_ids":["u7"]}',
      );
      final m = await _api(adapter).mutes('c1');
      expect(m.circleMuted, isTrue);
      expect(m.mutedUserIds, ['u7']);
    });

    test('a server error surfaces as AulApiException', () async {
      final adapter = _FakeMutesAdapter(status: 400);
      expect(() => _api(adapter).mutes('c1'), throwsA(isA<AulApiException>()));
    });
  });
}
