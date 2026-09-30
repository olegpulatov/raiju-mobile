import 'dart:async';
import 'dart:typed_data';

import 'package:buzz/harness/collab_codec.dart';
import 'package:buzz/harness/collab_link.dart';
import 'package:buzz/harness/collab_socket.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decrypts and delivers frames strictly in arrival order', () async {
    final channel = _SocketChannel();
    final codec = _DeferredCodec();
    final frames = <int>[];
    final socket = CollabSocket(
      socketUri: Uri.parse('wss://relay.example/r/room123456'),
      codec: codec,
      options: CollabSocketOptions(channelFactory: (_) => channel),
    )..onFrame = (frame) => frames.add(frame['n']! as int);
    socket.connect();
    await pumpEventQueue();
    channel.push(packCollabEnvelope(0, [1]));
    channel.push(packCollabEnvelope(0, [2]));
    await pumpEventQueue();
    expect(codec.pending, hasLength(1));
    codec.pending.removeAt(0).complete({'t': 'future', 'n': 1});
    await pumpEventQueue();
    expect(codec.pending, hasLength(1));
    codec.pending.removeAt(0).complete({'t': 'future', 'n': 2});
    await pumpEventQueue();
    expect(frames, [1, 2]);
    await socket.close();
  });

  test(
    'reconnect queue is not blocked by a stale unfinished decrypt',
    () async {
      final first = _SocketChannel();
      final second = _SocketChannel();
      var channelIndex = 0;
      final channels = [first, second];
      final codec = _DeferredCodec();
      final frames = <Map<String, Object?>>[];
      final retryGate = Completer<void>();
      final socket = CollabSocket(
        socketUri: Uri.parse('wss://relay.example/r/room123456'),
        codec: codec,
        options: CollabSocketOptions(
          channelFactory: (_) => channels[channelIndex++],
          delay: (_) => retryGate.future,
          randomDouble: () => .5,
        ),
      )..onFrame = frames.add;
      socket.connect();
      await pumpEventQueue();
      first.push(packCollabEnvelope(0, [1]));
      await pumpEventQueue();
      final stale = codec.pending.single;
      await first.hostClose(1006);
      retryGate.complete();
      await pumpEventQueue();
      second.push(packCollabEnvelope(0, [2]));
      await pumpEventQueue();
      expect(codec.pending, hasLength(2));
      codec.pending.last.complete({'t': 'future', 'n': 2});
      await pumpEventQueue();
      expect(frames, [
        {'t': 'future', 'n': 2},
      ]);
      stale.completeError(const CollabCodecException('stale bad frame'));
      await pumpEventQueue();
      expect(frames, hasLength(1));
      expect(socket.isOpen, isTrue);
      await socket.close();
    },
  );
}

final class _DeferredCodec implements CollabFrameCodec {
  final List<Completer<Map<String, Object?>>> pending = [];

  @override
  Future<Map<String, Object?>> open(List<int> sealed) {
    final completer = Completer<Map<String, Object?>>();
    pending.add(completer);
    return completer.future;
  }

  @override
  Future<Uint8List> seal(Map<String, Object?> frame) async => Uint8List(1);
}

final class _SocketChannel implements CollabChannel {
  final StreamController<Object?> _controller = StreamController<Object?>();
  int? _code;

  @override
  Future<void> get ready async {}
  @override
  Stream<Object?> get stream => _controller.stream;
  @override
  int? get closeCode => _code;
  @override
  String? get closeReason => null;
  @override
  void add(List<int> data) {}
  void push(List<int> data) => _controller.add(Uint8List.fromList(data));

  Future<void> hostClose(int code) async {
    _code = code;
    await _controller.close();
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_controller.isClosed) await _controller.close();
  }
}
