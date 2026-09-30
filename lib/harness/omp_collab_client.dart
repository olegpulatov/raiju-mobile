// Raiju's native adapter for OMP collab protocol v3. This intentionally keeps
// bearer links out of snapshots, errors, logs, and object stringification.
import 'dart:async';

import 'collab_codec.dart';
import 'collab_link.dart';
import 'collab_replica.dart';
import 'collab_socket.dart';
import 'harness.dart';

final class OmpCollabClientOptions {
  const OmpCollabClientOptions({
    this.socketOptions = const CollabSocketOptions(),
    this.welcomeTimeout = const Duration(seconds: 30),
    this.snapshotProgressTimeout = const Duration(seconds: 30),
    this.defaultRelay = defaultCollabRelay,
  });

  final CollabSocketOptions socketOptions;
  final Duration welcomeTimeout;
  final Duration snapshotProgressTimeout;
  final String defaultRelay;
}

final class OmpCollabClient implements HarnessClient {
  OmpCollabClient() : this.withOptions(const OmpCollabClientOptions());

  OmpCollabClient.withOptions(this._options);

  final OmpCollabClientOptions _options;
  final StreamController<HarnessSnapshot> _changes =
      StreamController<HarnessSnapshot>.broadcast(sync: true);
  CollabReplica? _replica;
  CollabSocket? _socket;
  ParsedCollabLink? _link;
  Completer<void>? _connecting;
  Timer? _welcomeTimer;
  Timer? _snapshotTimer;
  int _generation = 0;
  int _lifecycleOperation = 0;
  bool _disposed = false;
  bool _everOpened = false;
  bool _welcomed = false;
  String _displayName = 'raiju';
  String? _rawInput;

  @override
  HarnessSnapshot get snapshot => _replica?.snapshot ?? const HarnessSnapshot();

  @override
  Stream<HarnessSnapshot> get changes => _changes.stream;

  @override
  Future<void> connect(String input, {String displayName = 'raiju'}) async {
    if (_disposed) {
      throw const HarnessException(
        'This collaboration client has been disposed.',
      );
    }
    final operation = ++_lifecycleOperation;
    await _stop(settleWith: const HarnessException('Connection replaced.'));
    if (_disposed || operation != _lifecycleOperation) {
      throw const HarnessException('Connection replaced.');
    }
    final generation = ++_generation;
    late final ParsedCollabLink parsed;
    try {
      parsed = parseCollabLink(input, defaultRelay: _options.defaultRelay);
    } on CollabLinkException catch (error) {
      throw HarnessException(error.message);
    }
    _rawInput = input;
    _link = parsed;
    _displayName = _safeName(displayName);
    _everOpened = false;
    _welcomed = false;
    final replica = CollabReplica(
      endpoint: parsed.safeEndpoint,
      onChange: _publish,
    );
    _replica = replica;
    replica.connecting();
    final completer = Completer<void>();
    _connecting = completer;
    final socket = CollabSocket(
      socketUri: parsed.socketUri,
      codec: CollabCodec(parsed.key),
      options: _options.socketOptions,
    );
    _socket = socket;
    socket.onOpen = () => _onOpen(generation, socket);
    socket.onFrame = (frame) => _onFrame(generation, socket, frame);
    socket.onClose = (reason, willReconnect) =>
        _onClose(generation, socket, reason, willReconnect);
    _armWelcome(generation, socket);
    socket.connect();
    return completer.future;
  }

  Future<void> _onOpen(int generation, CollabSocket socket) async {
    if (!_current(generation, socket)) return;
    final reconnecting = _everOpened;
    _everOpened = true;
    _welcomed = false;
    _snapshotTimer?.cancel();
    _replica?.syncing(reconnecting: reconnecting);
    if (_welcomeTimer == null) _armWelcome(generation, socket);
    final token = _link?.writeToken;
    final hello = <String, Object?>{
      't': 'hello',
      'proto': collabProtocolVersion,
      'name': _displayName,
      if (token != null) 'writeToken': encodeBase64Url(token),
    };
    await socket.send(hello);
  }

  void _onFrame(
    int generation,
    CollabSocket socket,
    Map<String, Object?> frame,
  ) {
    if (!_current(generation, socket)) return;
    final type = frame['t'];
    if (type == 'error' && _welcomed) {
      _replica?.reportError(_sanitize(frame['message']));
      return;
    }
    try {
      final becameLive = _replica?.apply(_sanitizedFrame(frame)) ?? false;
      if (type == 'welcome') {
        _welcomed = true;
        _welcomeTimer?.cancel();
        final count = frame['entryCount'];
        if (count is num && count.toInt() > 0) {
          _armSnapshot(generation, socket);
        }
      } else if (type == 'snapshot-chunk') {
        if (frame['final'] == true) {
          _snapshotTimer?.cancel();
        } else {
          _armSnapshot(generation, socket);
        }
      }
      if (becameLive) _settleSuccess();
      if (type == 'bye') {
        _cancelTimers();
        if (!(_connecting?.isCompleted ?? true)) {
          _settleFailure(const HarnessException('The host ended sharing.'));
        }
        unawaited(socket.close());
      }
    } on HarnessException catch (error) {
      final safe = HarnessException(_sanitize(error.message));
      _replica?.closed(error: safe.message);
      _settleFailure(safe);
      unawaited(socket.close());
    } catch (_) {
      const safe = HarnessException(
        'The host sent an invalid collaboration snapshot.',
      );
      _replica?.closed(error: safe.message);
      _settleFailure(safe);
      unawaited(socket.close());
    }
  }

  void _onClose(
    int generation,
    CollabSocket socket,
    String reason,
    bool willReconnect,
  ) {
    if (!_current(generation, socket)) return;
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
    if (willReconnect) {
      _welcomed = false;
      _armWelcome(generation, socket);
      _replica?.syncing(reconnecting: true);
      return;
    }
    _welcomeTimer?.cancel();
    _welcomeTimer = null;
    final safe = HarnessException(_sanitize(reason));
    _replica?.closed(error: safe.message);
    _settleFailure(safe);
  }

  void _armWelcome(int generation, CollabSocket socket) {
    _welcomeTimer?.cancel();
    _welcomeTimer = Timer(_options.welcomeTimeout, () {
      if (!_current(generation, socket) || _welcomed) return;
      const error = HarnessException(
        'Timed out waiting for the host to respond.',
      );
      _replica?.closed(error: error.message);
      _settleFailure(error);
      unawaited(socket.close());
    });
  }

  void _armSnapshot(int generation, CollabSocket socket) {
    _snapshotTimer?.cancel();
    _snapshotTimer = Timer(_options.snapshotProgressTimeout, () {
      if (!_current(generation, socket)) return;
      const error = HarnessException(
        'Timed out while loading the host conversation.',
      );
      _replica?.closed(error: error.message);
      _settleFailure(error);
      unawaited(socket.close());
    });
  }

  @override
  Future<void> sendPrompt(String text) async {
    final value = text.trim();
    if (value.isEmpty) {
      throw const HarnessException('Enter a message first.');
    }
    await _mutate(<String, Object?>{'t': 'prompt', 'text': value});
  }

  @override
  Future<void> abort() => _mutate(const <String, Object?>{'t': 'abort'});

  @override
  Future<void> respond(int requestId, String? value) async {
    if (!snapshot.questions.any((question) => question.id == requestId)) {
      throw const HarnessException('That host question is no longer active.');
    }
    await _mutate(<String, Object?>{
      't': 'ui-response',
      'reqId': requestId,
      'value': ?value,
    });
    _replica?.answered(requestId);
  }

  Future<void> _mutate(Map<String, Object?> frame) async {
    final socket = _socket;
    if (!snapshot.canSend || socket == null || !socket.isOpen) {
      throw const HarnessException(
        'This session is read-only or is not currently connected.',
      );
    }
    try {
      await socket.send(frame);
    } on CollabSocketException catch (error) {
      throw HarnessException(error.message);
    }
  }

  @override
  Future<void> disconnect() async {
    if (_disposed) return;
    final operation = ++_lifecycleOperation;
    await _stop(settleWith: const HarnessException('Connection cancelled.'));
    if (_disposed || operation != _lifecycleOperation) return;
    _replica?.closed();
    _rawInput = null;
    _link = null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _lifecycleOperation++;
    await _stop(
      settleWith: const HarnessException(
        'The collaboration client was disposed.',
      ),
    );
    _rawInput = null;
    _link = null;
    await _changes.close();
  }

  Future<void> _stop({HarnessException? settleWith}) async {
    _generation++;
    _cancelTimers();
    final socket = _socket;
    _socket = null;
    if (settleWith != null) _settleFailure(settleWith);
    await socket?.close();
  }

  bool _current(int generation, CollabSocket socket) =>
      !_disposed && generation == _generation && identical(socket, _socket);

  void _settleSuccess() {
    final completer = _connecting;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void _settleFailure(HarnessException error) {
    final completer = _connecting;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }

  void _cancelTimers() {
    _welcomeTimer?.cancel();
    _snapshotTimer?.cancel();
    _welcomeTimer = null;
    _snapshotTimer = null;
  }

  Map<String, Object?> _sanitizedFrame(Map<String, Object?> frame) {
    if (frame['t'] == 'bye') {
      return {...frame, 'reason': _sanitize(frame['reason'])};
    }
    if (frame['t'] == 'event' && frame['event'] is Map) {
      final event = (frame['event'] as Map).map(
        (key, value) => MapEntry(key.toString(), value),
      );
      if (event['type'] == 'notice' && event['level'] == 'error') {
        return {
          ...frame,
          'event': {...event, 'message': _sanitize(event['message'])},
        };
      }
    }
    return frame;
  }

  void _publish() {
    if (!_changes.isClosed) _changes.add(snapshot);
  }

  String _sanitize(Object? value) {
    var text = value is String && value.trim().isNotEmpty
        ? value.trim()
        : 'The collaboration session ended unexpectedly.';
    final sensitive = <String?>[
      _link?.writeToken == null
          ? null
          : encodeBase64Url([..._link!.key, ..._link!.writeToken!]),
      _rawInput,
      _link?.roomId,
      _link == null ? null : encodeBase64Url(_link!.key),
      _link?.writeToken == null ? null : encodeBase64Url(_link!.writeToken!),
    ];
    for (final secret in sensitive) {
      if (secret != null && secret.isNotEmpty) {
        text = text.replaceAll(secret, '[redacted]');
      }
    }
    return text.length > 240 ? '${text.substring(0, 237)}…' : text;
  }

  String _safeName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'raiju';
    return String.fromCharCodes(trimmed.runes.take(64));
  }

  @override
  String toString() =>
      'OmpCollabClient(endpoint: ${snapshot.endpoint}, secret: redacted)';
}
