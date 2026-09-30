// MODIFIED FOR RAIJU: the retained Buzz/Nostr socket is hard-disabled. OMP
// collaboration WebSockets are separate and remain the only chat transport.

import 'package:flutter/foundation.dart';

import 'backend_disabled.dart';

/// Low-level websocket connection with NIP-42 authentication.
///
/// Handles the raw websocket lifecycle: connect, authenticate via NIP-42
/// challenge/response, send/receive JSON frames, and disconnect.
///
/// Does NOT handle reconnection — that is [RelaySessionNotifier]'s job.
enum SocketState { disconnected, connecting, authenticating, connected }

class RelayAuthRejectedException implements Exception {
  final String message;

  const RelayAuthRejectedException(this.message);

  @override
  String toString() => 'Relay authentication rejected: $message';
}

Exception classifyRelayAuthFailure(String message) {
  if (message.startsWith('error:')) return Exception(message);
  return RelayAuthRejectedException(message);
}

class RelaySocket {
  /// Interval retained for compatibility with socket timing tests.
  static const pingInterval = Duration(seconds: 30);

  @visibleForTesting
  static Duration debugPingInterval = pingInterval;

  final void Function(List<dynamic> message) _onMessage;
  SocketState _state = SocketState.disconnected;

  RelaySocket({
    required String wsUrl,
    required String? nsec,
    required void Function(List<dynamic> message) onMessage,
    required void Function() onConnected,
    required void Function(Object? error) onDisconnected,
  }) : _onMessage = onMessage;

  SocketState get state => _state;

  /// Buzz relay connections are disabled in Raiju.
  Future<void> connect() async {
    _state = SocketState.disconnected;
    throw buzzBackendUnavailable;
  }

  /// Buzz relay writes are disabled in Raiju.
  void send(List<dynamic> payload) {
    throw buzzBackendUnavailable;
  }

  Future<void> disconnect() async {
    _state = SocketState.disconnected;
  }

  void dispose() {
    _state = SocketState.disconnected;
  }

  @visibleForTesting
  void debugHandleOkForTest(List<dynamic> data) => _onMessage(data);
}
