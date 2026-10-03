import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'harness.dart';
import 'ompd_connection.dart';

/// One connection, with a hard physical-frame bound matching ompd RPC v1.
final class OmpdWire {
  OmpdWire._(this._socket, this.timeout, this.maxFrameBytes) {
    _subscription = _socket.listen(
      _receive,
      onError: (_) => _fail(),
      onDone: () => _fail(),
      cancelOnError: true,
    );
  }

  static Future<OmpdWire> connect(
    OmpdEndpoint endpoint, {
    required Duration timeout,
    int maxFrameBytes = 1024 * 1024,
  }) async {
    try {
      final socket = await Socket.connect(
        endpoint.host,
        endpoint.port,
        timeout: timeout,
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      return OmpdWire._(socket, timeout, maxFrameBytes);
    } catch (_) {
      throw const HarnessException(
        'Cannot reach the relay. Check the trusted network and address.',
      );
    }
  }

  final Socket _socket;
  final Duration timeout;
  final int maxFrameBytes;
  final _frames = StreamController<Map<String, Object?>>();
  final _partial = <int>[];
  late final StreamSubscription<List<int>> _subscription;
  Timer? _partialTimer;
  bool _closed = false;
  Future<void> _writing = Future.value();

  Stream<Map<String, Object?>> get frames => _frames.stream;

  void _receive(List<int> bytes) {
    if (_closed) return;
    for (final byte in bytes) {
      if (_partial.length + 1 > maxFrameBytes) {
        _fail(
          'Relay frame is too large. This relay supports bounded RPC v1 history only.',
        );
        return;
      }
      if (byte == 10) {
        _partialTimer?.cancel();
        _partialTimer = null;
        try {
          final value = jsonDecode(utf8.decode(_partial));
          if (value is! Map<String, dynamic>) throw const FormatException();
          _frames.add(Map<String, Object?>.from(value));
        } catch (_) {
          _fail('The relay sent an invalid protocol frame.');
          return;
        }
        _partial.clear();
      } else {
        _partial.add(byte);
        _partialTimer ??= Timer(
          timeout,
          () => _fail('The relay sent an incomplete frame.'),
        );
      }
    }
  }

  Future<void> send(Map<String, Object?> frame) {
    final bytes = utf8.encode('${jsonEncode(frame)}\n');
    if (bytes.length > maxFrameBytes) {
      throw const HarnessException('This request is too large for the relay.');
    }
    final operation = _writing.then((_) async {
      if (_closed) {
        throw const HarnessException('The relay connection is closed.');
      }
      try {
        _socket.add(bytes);
        await _socket.flush().timeout(timeout);
      } catch (_) {
        _fail();
        throw const HarnessException(
          'Relay delivery is uncertain. Inspect history before retrying.',
        );
      }
    });
    _writing = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  void _fail([
    String message =
        'The relay connection closed. Reconnect to refresh history.',
  ]) {
    if (_closed) return;
    _closed = true;
    _partialTimer?.cancel();
    _socket.destroy();
    _frames.addError(HarnessException(message));
    unawaited(_frames.close());
  }

  Future<void> close() async {
    _closed = true;
    _partialTimer?.cancel();
    _socket.destroy();
    await _subscription.cancel();
    unawaited(_frames.close());
  }
}
