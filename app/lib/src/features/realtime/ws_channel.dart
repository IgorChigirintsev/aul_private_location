import 'dart:async';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'realtime_client.dart';

/// The real [RealtimeChannel]: a WebSocket to `/v1/realtime`.
///
/// AUTH — the server (server/internal/httpapi/ws.go) resolves the token from, in
/// order: an `Authorization: Bearer` header, the httpOnly access cookie, then an
/// `access_token` query parameter. The browser has no choice and rides the
/// cookie. A native client is offered the header or the query parameter, and this
/// uses the HEADER: a token in the URL ends up in server access logs and proxy
/// logs, whereas a header does not. That is why this is [IOWebSocketChannel] and
/// not the portable `WebSocketChannel.connect` — the portable constructor cannot
/// send headers. The app is Android-only, so dart:io is always there.
///
/// ORIGIN — ws.go sets `OriginPatterns` to the server's public origin. That check
/// only applies to requests that CARRY an Origin header, which is a browser
/// thing: it exists to stop another site's page from opening a socket with the
/// user's cookies. A native client sends no Origin and no cookies, so it is not
/// what the allow-list is defending against, and it passes without needing to be
/// listed.
class WsRealtimeChannel implements RealtimeChannel {
  WsRealtimeChannel(this._channel);

  /// Opens a socket to [url], authenticating with [accessToken].
  factory WsRealtimeChannel.connect(Uri url, {required String accessToken}) =>
      WsRealtimeChannel(
        IOWebSocketChannel.connect(
          url,
          headers: {'Authorization': 'Bearer $accessToken'},
          // Matches the server's 30 s server→client ping: if two of them go
          // unanswered the socket is dead, and we want the stream to say so and
          // trigger a reconnect rather than hang on a half-open TCP connection
          // (exactly what a phone leaving Wi-Fi mid-session leaves behind).
          pingInterval: const Duration(seconds: 45),
        ),
      );

  final WebSocketChannel _channel;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  Future<void> close() async {
    try {
      await _channel.sink.close();
    } catch (_) {
      // Already closed, or never finished connecting — either way it is shut.
    }
  }
}
