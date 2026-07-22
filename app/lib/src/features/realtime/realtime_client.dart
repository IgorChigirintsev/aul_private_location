import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:sodium/sodium.dart';

import '../../crypto/ping_codec.dart';
import '../../data/api/models.dart';
import '../../domain/location_fix.dart';

/// Builds the `/v1/realtime` WebSocket URL for a server at [serverUrl].
///
/// The app talks to an ARBITRARY server the user typed, so this cannot assume a
/// host the way the web client can (it reads `location.host`). It maps the
/// scheme — https ⇒ wss, http ⇒ ws — and keeps host, port, and any base path, so
/// a server mounted under `https://example.org/aul` yields
/// `wss://example.org/aul/v1/realtime`.
///
/// Returns null for anything that isn't an http/https/ws/wss URL with a host:
/// there is no socket to open, and guessing would only produce a connect loop
/// against nothing.
Uri? realtimeUrl(String serverUrl) {
  final base = Uri.tryParse(serverUrl.trim());
  if (base == null || base.host.isEmpty) return null;
  final scheme = switch (base.scheme.toLowerCase()) {
    'https' || 'wss' => 'wss',
    'http' || 'ws' => 'ws',
    _ => null,
  };
  if (scheme == null) return null;
  // Strip a trailing slash so we never build a `//v1/realtime` path.
  var basePath = base.path;
  while (basePath.endsWith('/')) {
    basePath = basePath.substring(0, basePath.length - 1);
  }
  return Uri(
    scheme: scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: '$basePath/v1/realtime',
  );
}

/// The socket [RealtimeClient] talks over: a read-only stream of frames plus a
/// close. Deliberately NOT `WebSocketChannel` itself — the protocol is entirely
/// server→client (the client never sends a frame), and narrowing the surface to
/// what is actually used is what lets the whole client be tested against a plain
/// [StreamController] with no server, no sockets, and no timing.
abstract class RealtimeChannel {
  /// Frames from the server. An error or a done closes the connection, and the
  /// client reconnects.
  Stream<dynamic> get stream;

  /// Closes the underlying socket. Idempotent.
  Future<void> close();
}

/// Opens a connection, or returns null when one cannot be opened right now (no
/// session to authenticate with, an unusable server URL). Returning null is not
/// fatal — the client backs off and asks again.
typedef RealtimeOpener = Future<RealtimeChannel?> Function();

/// What the app does with each event the server pushes. Mirrors the web's
/// `RealtimeHandlers` (web/src/data/realtime.ts), with [onPosition] replacing the
/// web's direct write into its positions store.
class RealtimeHandlers {
  const RealtimeHandlers({
    this.onPosition,
    this.onSos,
    this.onSosResolved,
    this.onPlaceUpdated,
    this.onPrecision,
    this.onMemberChanged,
    this.onKeyEnvelope,
    this.onStatus,
  });

  /// A member moved: their device id and the fix decrypted from the ping. Fires
  /// only for pings this device holds a key for.
  final void Function(String deviceId, LocationFix fix)? onPosition;

  /// Someone raised an SOS; the payload is the sealed alert as the SOS list
  /// endpoint returns it.
  final void Function(Map<String, dynamic> payload)? onSos;

  /// An SOS was resolved, by id.
  final void Function(String sosId)? onSosResolved;

  /// A place was created, edited, or deleted — refetch the circle's places.
  final void Function()? onPlaceUpdated;

  /// Someone changed how they share. Refetch the members list: it carries
  /// precision_mode, which is what greys out a paused member's marker for
  /// everyone else. This is the whole point of the event.
  final void Function()? onPrecision;

  /// The membership changed (joined, left, removed) — refetch the members.
  final void Function()? onMemberChanged;

  /// A circle key was re-sealed to this device (a rotation). Picking it up
  /// promptly is what keeps the map from going blank after an owner rotates.
  final void Function()? onKeyEnvelope;

  /// Connection state changed. False means the app is on polling alone.
  final void Function(bool connected)? onStatus;
}

/// The app's client for `/v1/realtime` — the same live channel the web dashboard
/// uses, and the app's answer to having only polled before.
///
/// Receives the server's encrypted ping events and decrypts them HERE, on this
/// device, with the circle keyring, exactly like the web (`RealtimeClient` +
/// `pingToPosition`). The socket carries ciphertext; the server relays events it
/// cannot read.
///
/// Scoped to ONE circle — the [circleId] whose keyring it holds. The server
/// subscribes a connection to every circle the user belongs to, so events for
/// other circles do arrive; they are dropped, because this client has neither the
/// key to open their pings nor a screen to refresh for them.
///
/// Reconnects with exponential backoff and never gives up on its own. It is a
/// SUPPLEMENT to polling, not a replacement: while it is down, the poller still
/// covers the gap, which is why a failed connect is quiet rather than an error
/// the user has to see.
class RealtimeClient {
  RealtimeClient({
    required this.circleId,
    required RealtimeOpener open,
    required PingCodec codec,
    required List<SecureKey> keyring,
    this.handlers = const RealtimeHandlers(),
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
  }) : _open = open,
       _codec = codec,
       _keyring = keyring;

  /// The circle this client is subscribed to, and the only one whose events it
  /// acts on.
  final String circleId;

  final RealtimeOpener _open;
  final PingCodec _codec;

  /// The circle's full key ring (all epochs, oldest → newest) for opening pings —
  /// rotation-safe, like every other decrypt path in the app.
  ///
  /// OWNED: [dispose] frees these keys. The client outlives any single call, so
  /// it cannot borrow a keyring some caller will free underneath it.
  final List<SecureKey> _keyring;

  final RealtimeHandlers handlers;
  final Duration initialBackoff;
  final Duration maxBackoff;

  RealtimeChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _retry;
  bool _disposed = false;
  bool _connecting = false;
  late Duration _backoff = initialBackoff;

  /// Whether a socket is currently open.
  bool get connected => _channel != null;

  /// Opens the socket, and keeps it open for the client's lifetime. Safe to call
  /// more than once — an in-flight or established connection is left alone.
  void connect() {
    if (_disposed) return;
    unawaited(_connectOnce());
  }

  Future<void> _connectOnce() async {
    if (_disposed || _connecting || _channel != null) return;
    _connecting = true;
    RealtimeChannel? channel;
    try {
      channel = await _open();
    } catch (_) {
      channel = null; // couldn't even build a connection — back off and retry
    }
    _connecting = false;
    if (_disposed) {
      unawaited(channel?.close());
      return;
    }
    if (channel == null) {
      _scheduleRetry();
      return;
    }
    _channel = channel;
    handlers.onStatus?.call(true);
    _sub = channel.stream.listen(
      _handleFrame,
      onError: (_) => _dropped(),
      onDone: _dropped,
      cancelOnError: false,
    );
  }

  void _handleFrame(dynamic data) {
    if (_disposed) return;
    // The backoff resets on the first frame RECEIVED, not on "channel created".
    // A WebSocket connect returns before the handshake completes, so a server
    // that 401s us looks exactly like a successful connect and only fails on the
    // stream — resetting on connect would turn the backoff into a hot loop
    // against a server that is refusing us. A frame in hand proves the upgrade
    // AND the auth worked (the server's first act is a `welcome` frame).
    _backoff = initialBackoff;
    if (data is! String) return; // the server only ever sends text frames
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return; // not JSON — ignore rather than tear the connection down
    }
    if (decoded is! Map<String, dynamic>) return;
    final type = decoded['type'];
    if (type is! String) return;
    // Events for the user's OTHER circles share this connection; they are not
    // ours to act on. (`welcome` carries no circle_id and falls out here too.)
    if (decoded['circle_id'] != circleId) return;
    final payload = decoded['payload'];
    switch (type) {
      case 'ping':
        if (payload is! Map<String, dynamic>) return;
        _handlePing(payload);
      case 'sos':
        if (payload is Map<String, dynamic>) handlers.onSos?.call(payload);
      case 'sos_resolved':
        final id = payload is Map<String, dynamic> ? payload['id'] : null;
        if (id is String) handlers.onSosResolved?.call(id);
      case 'place_updated':
        handlers.onPlaceUpdated?.call();
      case 'precision_mode':
        handlers.onPrecision?.call();
      case 'member_changed':
        handlers.onMemberChanged?.call();
      case 'key_envelope':
        handlers.onKeyEnvelope?.call();
      default:
        break; // unknown/newer event type — ignore
    }
  }

  /// Decrypts a ping event into a position. A ping no key opens is SKIPPED
  /// silently: on a server relaying ciphertext, "can't read it" is a normal
  /// state (a member sealing under a key this device hasn't been given yet), not
  /// an error worth surfacing.
  void _handlePing(Map<String, dynamic> payload) {
    final RemotePing ping;
    try {
      ping = RemotePing.fromJson(payload);
    } catch (_) {
      return; // malformed event — skip
    }
    if (_keyring.isEmpty) return; // no key ⇒ nothing decryptable
    final LocationFix? fix;
    try {
      fix = _codec.openWithKeyring(
        base64.decode(ping.nonceB64),
        base64.decode(ping.ciphertextB64),
        _keyring,
      );
    } catch (_) {
      return; // malformed base64 — skip
    }
    if (fix == null) return; // no key opened it — skip
    handlers.onPosition?.call(ping.deviceId, fix);
  }

  /// The socket closed or errored. Tear the remains down and queue a retry.
  void _dropped() {
    if (_disposed || _channel == null) return;
    unawaited(_sub?.cancel());
    _sub = null;
    final channel = _channel;
    _channel = null;
    unawaited(channel?.close());
    handlers.onStatus?.call(false);
    _scheduleRetry();
  }

  /// Retries after the current backoff, then doubles it up to [maxBackoff]. A
  /// dropped socket usually means the network went away or the server restarted;
  /// backing off keeps a whole circle's phones from stampeding it on the way back
  /// up. Polling covers the gap meanwhile.
  void _scheduleRetry() {
    if (_disposed || _retry != null) return;
    final wait = _backoff;
    _backoff = Duration(
      milliseconds: math.min(
        _backoff.inMilliseconds * 2,
        maxBackoff.inMilliseconds,
      ),
    );
    _retry = Timer(wait, () {
      _retry = null;
      unawaited(_connectOnce());
    });
  }

  /// Closes the socket, cancels any pending reconnect, and frees the keyring.
  /// Idempotent. After this the client is inert — a retry in flight will not
  /// resurrect it.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retry?.cancel();
    _retry = null;
    unawaited(_sub?.cancel());
    _sub = null;
    final channel = _channel;
    _channel = null;
    unawaited(channel?.close());
    for (final key in _keyring) {
      key.dispose();
    }
  }
}
