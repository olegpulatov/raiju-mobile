// OMP collab WebSocket behavior translated for Raiju from
// @oh-my-pi/collab-web/src/lib/socket.ts. No relay implementation lives here.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'collab_codec.dart';
import 'collab_link.dart';

abstract interface class CollabChannel {
  Future<void> get ready;
  Stream<Object?> get stream;
  int? get closeCode;
  String? get closeReason;
  void add(List<int> data);
  Future<void> close([int? code, String? reason]);
}

final class WebSocketCollabChannel implements CollabChannel {
  WebSocketCollabChannel(Uri uri) : _channel = WebSocketChannel.connect(uri);
  final WebSocketChannel _channel;

  @override
  Future<void> get ready => _channel.ready;
  @override
  Stream<Object?> get stream => _channel.stream;
  @override
  int? get closeCode => _channel.closeCode;
  @override
  String? get closeReason => _channel.closeReason;
  @override
  void add(List<int> data) => _channel.sink.add(data);
  @override
  Future<void> close([int? code, String? reason]) async {
    await _channel.sink.close(code, reason);
  }
}

typedef CollabChannelFactory = CollabChannel Function(Uri uri);
typedef CollabDelay = Future<void> Function(Duration duration);

final class CollabSocketOptions {
  const CollabSocketOptions({
    this.channelFactory = _defaultChannelFactory,
    this.delay = _defaultDelay,
    this.randomDouble,
    this.maxReconnectAttempts = 8,
    this.baseBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    this.maxPendingOperations = 256,
  });

  final CollabChannelFactory channelFactory;
  final CollabDelay delay;
  final double Function()? randomDouble;
  final int maxReconnectAttempts;
  final Duration baseBackoff;
  final Duration maxBackoff;
  final int maxPendingOperations;
}

CollabChannel _defaultChannelFactory(Uri uri) => WebSocketCollabChannel(uri);
Future<void> _defaultDelay(Duration duration) => Future<void>.delayed(duration);

final class CollabSocket {
  CollabSocket({
    required Uri socketUri,
    required CollabFrameCodec codec,
    CollabSocketOptions options = const CollabSocketOptions(),
  }) : _socketUri = socketUri,
       _codec = codec,
       _options = options;

  final Uri _socketUri;
  final CollabFrameCodec _codec;
  final CollabSocketOptions _options;
  CollabChannel? _channel;
  StreamSubscription<Object?>? _subscription;
  _SerialQueue _sendQueue = _SerialQueue();
  _SerialQueue _receiveQueue = _SerialQueue();
  int _generation = 0;
  int _attempt = 0;
  bool _closed = true;
  bool _retryMissingRoom = false;

  Future<void> Function()? onOpen;
  void Function(Map<String, Object?> frame)? onFrame;
  void Function(String reason, bool willReconnect)? onClose;

  bool get isOpen => _channel != null && !_closed;

  void connect() {
    if (!_closed || _channel != null) return;
    _closed = false;
    _attempt = 0;
    _retryMissingRoom = false;
    _open();
  }

  Future<void> send(Map<String, Object?> frame) {
    if (_closed || _channel == null) {
      return Future<void>.error(
        const CollabSocketException(
          'The collaboration session is not connected.',
        ),
      );
    }
    final queue = _sendQueue;
    if (queue.pending >= _options.maxPendingOperations) {
      return Future<void>.error(
        const CollabSocketException('Too many pending collaboration messages.'),
      );
    }
    final generation = _generation;
    final channel = _channel!;
    queue.pending++;
    final operation = queue.chain.then((_) async {
      final sealed = await _codec.seal(frame);
      if (_closed ||
          generation != _generation ||
          !identical(channel, _channel)) {
        throw const CollabSocketException(
          'The connection changed before the message could be sent.',
        );
      }
      channel.add(packCollabEnvelope(0, sealed));
    });
    queue.chain = operation
        .catchError((_) {})
        .whenComplete(() => queue.pending--);
    return operation;
  }

  Future<void> close() async {
    if (_closed && _channel == null) return;
    _closed = true;
    _generation++;
    final subscription = _subscription;
    final channel = _channel;
    _subscription = null;
    _channel = null;
    await subscription?.cancel();
    if (channel != null) {
      try {
        await channel.close(1000, 'closed');
      } catch (_) {
        // Already closed.
      }
    }
  }

  void _open() {
    if (_closed) return;
    final generation = ++_generation;
    _sendQueue = _SerialQueue();
    _receiveQueue = _SerialQueue();
    final uri = _socketUri.replace(queryParameters: const {'role': 'guest'});
    late final CollabChannel channel;
    try {
      channel = _options.channelFactory(uri);
    } catch (_) {
      _handleClose(
        generation,
        0,
        'Unable to open the collaboration connection.',
      );
      return;
    }
    _channel = channel;
    channel.ready
        .then((_) async {
          if (_closed || generation != _generation || _channel != channel) {
            return;
          }
          _subscription = channel.stream.listen(
            (data) => _receive(generation, data),
            onError: (_) {},
            onDone: () => _handleClose(
              generation,
              channel.closeCode ?? 0,
              channel.closeReason ?? '',
            ),
            cancelOnError: false,
          );
          try {
            await onOpen?.call();
          } catch (_) {
            if (!_closed &&
                generation == _generation &&
                identical(channel, _channel)) {
              await _fatal(
                'Unable to start the encrypted collaboration session.',
              );
            }
          }
        })
        .catchError((_) {
          _handleClose(
            generation,
            channel.closeCode ?? 0,
            channel.closeReason ?? '',
          );
        });
  }

  void _receive(int generation, Object? data) {
    if (_closed || generation != _generation) return;
    if (data is String) {
      try {
        final control = jsonDecode(data);
        if (control is Map && control['t'] == 'room-closed') {
          _retryMissingRoom = true;
        }
      } catch (_) {
        // Malformed plaintext relay controls contain no session data; ignore.
      }
      return;
    }
    final bytes = switch (data) {
      Uint8List value => value,
      List<int> value => Uint8List.fromList(value),
      _ => null,
    };
    if (bytes == null) return;
    final queue = _receiveQueue;
    if (queue.pending >= _options.maxPendingOperations) {
      unawaited(
        _fatal('The collaboration connection could not keep up safely.'),
      );
      return;
    }
    final envelope = unpackCollabEnvelope(bytes);
    if (envelope == null) return;
    queue.pending++;
    queue.chain = queue.chain
        .then((_) async {
          if (_closed || generation != _generation) return;
          final frame = await _codec.open(envelope.payload);
          if (_closed || generation != _generation) return;
          _retryMissingRoom = false;
          _attempt = 0;
          onFrame?.call(frame);
        })
        .catchError((error) async {
          if (error is CollabCodecException &&
              !_closed &&
              generation == _generation) {
            await _fatal('Bad key or corrupted collaboration frame.');
          }
        })
        .whenComplete(() => queue.pending--);
  }

  void _handleClose(int generation, int code, String rawReason) {
    if (_closed || generation != _generation) return;
    final retryGeneration = ++_generation;
    _subscription = null;
    _channel = null;
    const known = <int, String>{
      4001: 'The host closed the collaboration room.',
      4004: 'The collaboration room does not exist.',
      4009: 'The collaboration room already has a host.',
      4029: 'The collaboration room is full.',
    };
    final reason =
        known[code] ??
        (rawReason.trim().isEmpty
            ? 'The collaboration connection was lost.'
            : 'The collaboration connection was closed.');
    final retryRoom = code == 4001 || (code == 4004 && _retryMissingRoom);
    final terminalKnown = known.containsKey(code) && !retryRoom;
    if (terminalKnown) {
      _closed = true;
      onClose?.call(reason, false);
      return;
    }
    if (_attempt >= _options.maxReconnectAttempts) {
      _closed = true;
      onClose?.call(
        'Unable to reconnect after ${_options.maxReconnectAttempts} attempts.',
        false,
      );
      return;
    }
    if (retryRoom) _retryMissingRoom = true;
    onClose?.call(reason, true);
    final delay = _backoff(_attempt++);
    _options.delay(delay).then((_) {
      if (!_closed && retryGeneration == _generation) _open();
    });
  }

  Duration _backoff(int attempt) {
    final multiplier = pow(2, attempt).toInt();
    final raw = _options.baseBackoff.inMilliseconds * multiplier;
    final capped = min(raw, _options.maxBackoff.inMilliseconds);
    final jitter =
        .75 + (_options.randomDouble?.call() ?? Random().nextDouble()) * .5;
    return Duration(milliseconds: (capped * jitter).round());
  }

  Future<void> _fatal(String reason) async {
    if (_closed) return;
    _closed = true;
    _generation++;
    final subscription = _subscription;
    final channel = _channel;
    _subscription = null;
    _channel = null;
    await subscription?.cancel();
    try {
      await channel?.close(1000, 'closed');
    } catch (_) {}
    onClose?.call(reason, false);
  }
}

final class _SerialQueue {
  Future<void> chain = Future<void>.value();
  int pending = 0;
}

final class CollabSocketException implements Exception {
  const CollabSocketException(this.message);
  final String message;
  @override
  String toString() => message;
}
