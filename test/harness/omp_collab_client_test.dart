import 'dart:async';
import 'dart:typed_data';

import 'package:buzz/harness/collab_codec.dart';
import 'package:buzz/harness/collab_link.dart';
import 'package:buzz/harness/collab_socket.dart';
import 'package:buzz/harness/harness.dart';
import 'package:buzz/harness/omp_collab_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = Uint8List.fromList(List<int>.generate(32, (index) => index));
  final token = Uint8List.fromList(
    List<int>.generate(16, (index) => index + 128),
  );
  const room = 'AbCdEf123456_-Xy';
  late String fullLink;
  late CollabCodec codec;

  setUp(() {
    fullLink = '$room.${encodeBase64Url([...key, ...token])}';
    codec = CollabCodec(key);
  });

  test(
    'handshake carries v3 token and host authorization gates mutations',
    () async {
      final channel = _FakeChannel();
      final client = _clientWith([channel]);
      final connecting = client.connect(fullLink, displayName: '  Alice  ');
      await _settleAsync();
      final hello = await _decodeSent(codec, channel.sent.single);
      expect(hello, {
        't': 'hello',
        'proto': 3,
        'name': 'Alice',
        'writeToken': encodeBase64Url(token),
      });

      await _push(codec, channel, _welcome(readOnly: true, entryCount: 0));
      await expectLater(connecting, completes);
      expect(client.snapshot.readOnly, isTrue);
      await expectLater(
        client.sendPrompt('no'),
        throwsA(isA<HarnessException>()),
      );

      await client.dispose();
    },
  );

  test(
    'writable live client sends prompt, abort, response and explicit cancel once',
    () async {
      final channel = _FakeChannel();
      final client = _clientWith([channel]);
      final connecting = client.connect(fullLink);
      await _settleAsync();
      await _push(codec, channel, _welcome(readOnly: false, entryCount: 0));
      await connecting;
      await _push(codec, channel, {
        't': 'ui-request',
        'request': {
          'reqId': 4,
          'kind': 'editor',
          'title': 'Confirm text',
          'prefill': 'draft',
        },
      });
      await client.sendPrompt(' hello ');
      await client.abort();
      await client.respond(4, null);
      await _settleAsync();

      final frames = <Map<String, Object?>>[];
      for (final envelope in channel.sent.skip(1)) {
        frames.add(await _decodeSent(codec, envelope));
      }
      expect(frames, [
        {'t': 'prompt', 'text': 'hello'},
        {'t': 'abort'},
        {'t': 'ui-response', 'reqId': 4},
      ]);
      expect(client.snapshot.questions, isEmpty);
      await client.dispose();
    },
  );

  test('reconnect sends a new hello and welcome resets old history', () async {
    final first = _FakeChannel();
    final second = _FakeChannel();
    final client = _clientWith([first, second]);
    final connecting = client.connect(fullLink);
    await _settleAsync();
    await _push(codec, first, _welcome(readOnly: false, entryCount: 1));
    await _push(codec, first, {
      't': 'snapshot-chunk',
      'entries': [_entry('old', 'old')],
      'final': true,
    });
    await connecting;

    await first.hostClose(1006);
    await _settleAsync();
    expect(client.snapshot.phase, ConnectionPhase.reconnecting);
    expect(second.sent, hasLength(1));
    await _push(codec, second, {
      ..._welcome(readOnly: false, entryCount: 1),
      'header': {..._header, 'id': 'new-session'},
    });
    await _push(codec, second, {
      't': 'snapshot-chunk',
      'entries': [_entry('new', 'new')],
      'final': true,
    });
    expect(client.snapshot.messages.single.text, 'new');
    expect(client.snapshot.sessionId, 'new-session');
    await client.dispose();
  });

  test(
    'disconnect settles an in-flight connect and prevents later frames',
    () async {
      final channel = _FakeChannel();
      final client = _clientWith([channel]);
      final connecting = client.connect(fullLink);
      final expectation = expectLater(
        connecting,
        throwsA(isA<HarnessException>()),
      );
      await _settleAsync();
      await client.disconnect();
      await expectation;
      expect(client.snapshot.phase, ConnectionPhase.disconnected);
      await client.dispose();
    },
  );

  test('superseded slow disconnect cannot clear a newer connection', () async {
    final closeGate = Completer<void>();
    final firstChannel = _FakeChannel(closeGate: closeGate.future);
    final secondChannel = _FakeChannel();
    final client = _clientWith([firstChannel, secondChannel]);
    final firstConnect = client.connect(fullLink);
    await _settleAsync();
    await _push(codec, firstChannel, _welcome(readOnly: false, entryCount: 0));
    await firstConnect;

    final disconnecting = client.disconnect();
    final secondConnect = client.connect(fullLink);
    await _settleAsync();
    await _push(codec, secondChannel, _welcome(readOnly: false, entryCount: 0));
    await secondConnect;
    closeGate.complete();
    await disconnecting;

    expect(client.snapshot.phase, ConnectionPhase.live);
    expect(client.snapshot.canSend, isTrue);
    await client.dispose();
  });

  test(
    'dispose racing initial cleanup settles connect without opening a socket',
    () async {
      final channel = _FakeChannel();
      final client = _clientWith([channel]);
      final connecting = client.connect(fullLink);
      final expectation = expectLater(
        connecting,
        throwsA(isA<HarnessException>()),
      );
      await client.dispose();
      await expectation;
      expect(channel.sent, isEmpty);
    },
  );

  test(
    'concurrent connect replaces and settles the earlier operation',
    () async {
      final channel = _FakeChannel();
      final client = _clientWith([channel]);
      final first = client.connect(fullLink);
      final firstExpectation = expectLater(
        first,
        throwsA(isA<HarnessException>()),
      );
      final second = client.connect(fullLink);
      await firstExpectation;
      await _settleAsync();
      expect(channel.sent, hasLength(1));
      await _push(codec, channel, _welcome(readOnly: false, entryCount: 0));
      await expectLater(second, completes);
      await client.dispose();
    },
  );
  test('welcome timeout is terminal', () async {
    final channel = _FakeChannel();
    final client = _clientWith([
      channel,
    ], welcomeTimeout: const Duration(milliseconds: 1));
    await expectLater(
      client.connect(fullLink),
      throwsA(isA<HarnessException>()),
    );
    expect(client.snapshot.phase, ConnectionPhase.error);
    await client.dispose();
  });

  test('transport setup that never becomes ready still times out', () async {
    final neverReady = Completer<void>();
    final channel = _FakeChannel(ready: neverReady.future);
    final client = _clientWith([
      channel,
    ], welcomeTimeout: const Duration(milliseconds: 1));
    await expectLater(
      client.connect(fullLink),
      throwsA(isA<HarnessException>()),
    );
    expect(client.snapshot.phase, ConnectionPhase.error);
    await client.dispose();
  });

  test('snapshot progress timeout settles connect', () async {
    final channel = _FakeChannel();
    final client = _clientWith([
      channel,
    ], snapshotTimeout: const Duration(milliseconds: 1));
    final connecting = client.connect(fullLink);
    final expectation = expectLater(
      connecting,
      throwsA(isA<HarnessException>()),
    );
    await _settleAsync();
    await _push(codec, channel, _welcome(readOnly: false, entryCount: 1));
    await expectation;
    expect(client.snapshot.error, contains('loading'));
    await client.dispose();
  });

  test('host closure text is sanitized before publication', () async {
    final channel = _FakeChannel();
    final client = _clientWith([channel]);
    final connecting = client.connect(fullLink);
    await _settleAsync();
    await _push(codec, channel, _welcome(readOnly: false, entryCount: 0));
    await connecting;
    final combinedSecret = encodeBase64Url([...key, ...token]);
    await _push(codec, channel, {
      't': 'bye',
      'reason': 'leaked $combinedSecret',
    });
    expect(client.snapshot.phase, ConnectionPhase.ended);
    expect(client.snapshot.error, isNot(contains(combinedSecret)));
    expect(client.snapshot.error, contains('[redacted]'));
    await client.dispose();
  });
  test(
    'wrong key failure and host errors never expose bearer material',
    () async {
      final channel = _FakeChannel();
      final client = _clientWith([channel]);
      final connecting = client.connect(fullLink);
      final expectation = expectLater(
        connecting,
        throwsA(isA<HarnessException>()),
      );
      await _settleAsync();
      final wrongCodec = CollabCodec(List<int>.filled(32, 9));
      await _push(
        wrongCodec,
        channel,
        _welcome(readOnly: false, entryCount: 0),
      );
      await expectation;
      expect(client.snapshot.error, isNot(contains(encodeBase64Url(key))));
      expect(client.toString(), isNot(contains(encodeBase64Url(token))));
      await client.dispose();
    },
  );

  test('initial missing room is terminal rather than retried', () async {
    final channel = _FakeChannel();
    final client = _clientWith([channel]);
    final connecting = client.connect(fullLink);
    final expectation = expectLater(
      connecting,
      throwsA(isA<HarnessException>()),
    );
    await _settleAsync();
    await channel.hostClose(4004);
    await expectation;
    expect(client.snapshot.error, contains('does not exist'));
    await client.dispose();
  });

  test(
    'repeated unauthenticated open-close cycles exhaust retry budget',
    () async {
      final channels = [_FakeChannel(), _FakeChannel(), _FakeChannel()];
      final client = _clientWith(channels);
      final connecting = client.connect(fullLink);
      final expectation = expectLater(
        connecting,
        throwsA(isA<HarnessException>()),
      );
      for (final channel in channels) {
        await _settleAsync();
        await channel.hostClose(1006);
      }
      await expectation;
      expect(client.snapshot.error, contains('2 attempts'));
      await client.dispose();
    },
  );
}

OmpCollabClient _clientWith(
  List<_FakeChannel> channels, {
  Duration welcomeTimeout = const Duration(seconds: 1),
  Duration snapshotTimeout = const Duration(seconds: 1),
}) {
  var index = 0;
  return OmpCollabClient.withOptions(
    OmpCollabClientOptions(
      welcomeTimeout: welcomeTimeout,
      snapshotProgressTimeout: snapshotTimeout,
      socketOptions: CollabSocketOptions(
        channelFactory: (_) => channels[index++],
        delay: (_) async {},
        randomDouble: () => .5,
        maxReconnectAttempts: 2,
      ),
    ),
  );
}

Future<void> _push(
  CollabCodec codec,
  _FakeChannel channel,
  Map<String, Object?> frame,
) async {
  channel.push(packCollabEnvelope(0, await codec.seal(frame)));
  await _settleAsync();
}

Future<Map<String, Object?>> _decodeSent(
  CollabCodec codec,
  List<int> bytes,
) async {
  return codec.open(unpackCollabEnvelope(bytes)!.payload);
}

Future<void> _settleAsync() => pumpEventQueue(times: 20);

const Map<String, Object?> _header = {
  'type': 'session',
  'id': 'session',
  'title': 'Test',
  'timestamp': '2026-01-01T00:00:00Z',
  'cwd': '/host/path',
};

Map<String, Object?> _welcome({
  required bool readOnly,
  required int entryCount,
}) => {
  't': 'welcome',
  'proto': 3,
  'header': _header,
  'state': {
    'isStreaming': false,
    'queuedMessageCount': 0,
    'cwd': '/host/path',
    'participants': const [],
  },
  'agents': const [],
  'entryCount': entryCount,
  'readOnly': readOnly,
};

Map<String, Object?> _entry(String id, String text) => {
  'type': 'message',
  'id': id,
  'parentId': null,
  'timestamp': '2026-01-01T00:00:00Z',
  'message': {'role': 'user', 'content': text, 'timestamp': 1767225600000},
};

final class _FakeChannel implements CollabChannel {
  _FakeChannel({Future<void>? ready, Future<void>? closeGate})
    : _ready = ready ?? Future<void>.value(),
      _closeGate = closeGate ?? Future<void>.value();

  final Future<void> _ready;
  final Future<void> _closeGate;
  final StreamController<Object?> _controller = StreamController<Object?>();
  final List<List<int>> sent = [];
  int? _closeCode;
  String? _closeReason;

  @override
  Future<void> get ready => _ready;
  @override
  Stream<Object?> get stream => _controller.stream;
  @override
  int? get closeCode => _closeCode;
  @override
  String? get closeReason => _closeReason;
  @override
  void add(List<int> data) => sent.add(Uint8List.fromList(data));
  void push(List<int> data) => _controller.add(Uint8List.fromList(data));

  Future<void> hostClose(int code, [String reason = '']) async {
    _closeCode = code;
    _closeReason = reason;
    await _controller.close();
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    _closeCode = code;
    _closeReason = reason;
    await _closeGate;
    if (!_controller.isClosed) await _controller.close();
  }
}
