// MODIFIED FOR RAIJU: legacy Buzz Huddle audio transport is retained only for
// UI type compatibility and cannot open or write a WebSocket.
import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'huddle_auth.dart';
import '../relay/backend_disabled.dart';
import 'huddle_wire.dart';

typedef HuddleWebSocketFactory = WebSocketChannel Function(Uri uri);

WebSocketChannel _openHuddleWebSocket(Uri uri) =>
    throw buzzBackendUnavailable;

enum HuddleTransportPhase {
  idle,
  connecting,
  awaitingChallenge,
  authenticating,
  connected,
  closing,
  disconnected,
  failed,
}

enum HuddleTransportErrorCode {
  invalidState,
  connectionFailed,
  handshakeTimeout,
  authenticationFailed,
  relayRejected,
  protocolViolation,
  socketClosed,
  sendFailed,
  cancelled,
  disposed,
}

@immutable
final class HuddleTransportError implements Exception {
  final HuddleTransportErrorCode code;
  final String message;
  final String? relayCode;
  final Object? cause;

  const HuddleTransportError({
    required this.code,
    required this.message,
    this.relayCode,
    this.cause,
  });

  @override
  String toString() {
    final suffix = relayCode == null ? '' : ' ($relayCode)';
    return 'HuddleTransportError.${code.name}$suffix: $message';
  }
}

@immutable
final class HuddlePeer {
  final String pubkey;
  final int peerIndex;

  /// Occupancy epoch of `peerIndex` for this pubkey. Advances each time the
  /// index is reused by another occupancy; media frames are fenced against it
  /// so a prior occupant's in-flight audio cannot be mis-attributed after reuse.
  final int epoch;

  const HuddlePeer({
    required this.pubkey,
    required this.peerIndex,
    required this.epoch,
  });
}

enum HuddlePeerEventType { joined, left, replaced }

@immutable
final class HuddlePeerEvent {
  final HuddlePeerEventType type;
  final HuddlePeer peer;
  final HuddlePeer? replacement;

  const HuddlePeerEvent({
    required this.type,
    required this.peer,
    this.replacement,
  });
}

@immutable
final class HuddleTransportState {
  final HuddleTransportPhase phase;
  final int? localPeerIndex;
  final int? rosterRevision;
  final UnmodifiableMapView<int, HuddlePeer> peers;
  final HuddleTransportError? error;

  HuddleTransportState({
    required this.phase,
    this.localPeerIndex,
    this.rosterRevision,
    Map<int, HuddlePeer> peers = const {},
    this.error,
  }) : peers = UnmodifiableMapView(Map<int, HuddlePeer>.from(peers));

  factory HuddleTransportState.idle() =>
      HuddleTransportState(phase: HuddleTransportPhase.idle);
}

/// Dedicated Huddle audio transport.
///
/// This socket intentionally does not reuse [RelaySocket]: the main Nostr
/// connection speaks JSON arrays and ignores binary messages, while Huddle
/// audio uses JSON objects for its handshake/control plane and binary Opus v2
/// frames for media. [connect] completes only after the relay's `joined`
/// response, making authentication and room admission observable to callers.
abstract interface class HuddleTransportClient {
  HuddleTransportState get state;
  Stream<HuddleTransportState> get states;
  Stream<HuddleRemoteAudioFrame> get remoteAudioFrames;
  Stream<HuddlePeerEvent> get peerEvents;
  Stream<HuddleTransportError> get issues;

  Future<void> connect();
  void sendOpusFrame({
    required HuddleAudioHeader header,
    required Uint8List opusPayload,
  });
  Future<void> disconnect();
  Future<void> dispose();
}

final class HuddleTransport implements HuddleTransportClient {
  final HuddleConnectionParameters parameters;
  final Duration connectTimeout;
  final Duration handshakeTimeout;

  final StreamController<HuddleTransportState> _stateController =
      StreamController.broadcast(sync: true);
  final StreamController<HuddleRemoteAudioFrame> _audioController =
      StreamController.broadcast(sync: true);
  final StreamController<HuddlePeerEvent> _peerController =
      StreamController.broadcast(sync: true);
  final StreamController<HuddleTransportError> _issueController =
      StreamController.broadcast(sync: true);

  HuddleTransportState _state = HuddleTransportState.idle();
  bool _disposed = false;

  HuddleTransport({
    required this.parameters,
    this.connectTimeout = const Duration(seconds: 8),
    this.handshakeTimeout = const Duration(seconds: 5),
    HuddleWebSocketFactory channelFactory = _openHuddleWebSocket,
  });

  @override
  HuddleTransportState get state => _state;

  @override
  Stream<HuddleTransportState> get states => _stateController.stream;

  @override
  Stream<HuddleRemoteAudioFrame> get remoteAudioFrames =>
      _audioController.stream;

  @override
  Stream<HuddlePeerEvent> get peerEvents => _peerController.stream;

  @override
  Stream<HuddleTransportError> get issues => _issueController.stream;

  @override
  Future<void> connect() async {
    throw buzzBackendUnavailable;
  }

  @override
  void sendOpusFrame({
    required HuddleAudioHeader header,
    required Uint8List opusPayload,
  }) {
    throw buzzBackendUnavailable;
  }

  @override
  Future<void> disconnect() async {
    if (_state.phase == HuddleTransportPhase.idle ||
        _state.phase == HuddleTransportPhase.disconnected) {
      return;
    }
    if (_disposed) return;
    _state = HuddleTransportState(
      phase: HuddleTransportPhase.disconnected,
    );
    _stateController.add(_state);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _disposed = true;
    await _stateController.close();
    await _audioController.close();
    await _peerController.close();
    await _issueController.close();
  }
}
