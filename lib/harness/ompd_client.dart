import 'dart:async';
import 'dart:convert';

import 'harness.dart';
import 'ompd_api.dart';
import 'ompd_connection.dart';
import 'ompd_wire.dart';
import 'voice_directive.dart';

/// Raw RPC v1 only: ompd does not support OMP protocol negotiation/chunking.
/// Reconnect is explicit and attach-only. A takeover never reclaims control.
final class OmpdClient implements HarnessClient, OmpdControlStatus {
  OmpdClient({this.timeout = const Duration(seconds: 10), OmpdApi? api})
    : _api = api ?? OmpdApi(timeout: timeout);

  final Duration timeout;
  final OmpdApi _api;
  final _changes = StreamController<HarnessSnapshot>.broadcast(sync: true);
  final _pending = <String, _Pending>{};
  final _rows = <_Row>[];
  final _occurrences = <String, int>{};
  int _historyBytes = 0;
  final _events = <AgentEvent>[];
  final _eventSizes = <int>[];
  int _eventBytes = 0;
  final _buffer = <Map<String, Object?>>[];
  final _questions = <int, Map<String, Object?>>{};
  OmpdWire? _wire;
  StreamSubscription<Map<String, Object?>>? _subscription;
  Completer<Map<String, Object?>>? _attach;
  Timer? _bootstrapTimer;
  OmpdConnection? _connection;
  String? _boundSession;
  String? _boundFile;
  Map<String, Object?>? _pendingCompaction;
  Map<String, Object?>? _lastCompaction;
  int _contextSequence = 0;
  String? _clientId;
  int _generation = 0;
  int _requestId = 0;
  int _eventSequence = 0;
  int _questionId = 0;
  int _historyBoundary = 0;
  int _stateBoundary = 0;
  int _bufferBytes = 0;
  bool _disposed = false;
  bool _bootstrapping = false;
  bool _projectionReady = false;
  bool _readOnly = true;
  bool _controlLost = false;
  bool _streaming = false;
  bool _sendingPrompt = false;
  String _title = 'OMP chat';
  String _model = '';
  String _activity = '';
  String? _error;
  ConnectionPhase _phase = ConnectionPhase.disconnected;
  HarnessSnapshot _snapshot = const HarnessSnapshot();

  @override
  HarnessSnapshot get snapshot => _snapshot;
  @override
  Stream<HarnessSnapshot> get changes => _changes.stream;

  @override
  bool get controlLost => _controlLost;

  @override
  Future<void> connect(String input, {String displayName = 'raiju'}) async {
    if (_disposed) {
      throw const HarnessException('This relay client has been disposed.');
    }
    final connection = OmpdConnection.parse(input);
    if (!connection.trustedNetwork) {
      throw const HarnessException(
        'Confirm this unencrypted relay is on a trusted private network before connecting.',
      );
    }
    if (connection.sessionFile == null || connection.sessionFile!.isEmpty) {
      throw const HarnessException(
        'This relay connection has no transcript identity. Pair it again before connecting.',
      );
    }
    final generation = ++_generation;
    _controlLost = false;
    await _close();
    _check(generation, allowError: true);
    final sameTarget =
        _connection?.endpoint.toString() == connection.endpoint.toString() &&
        _connection?.instance == connection.instance;
    if (!sameTarget) {
      _rows.clear();
      _occurrences.clear();
      _historyBytes = 0;
      _events.clear();
      _eventSizes.clear();
      _eventBytes = 0;
      _boundSession = null;
      _boundFile = null;
      _lastCompaction = null;
      _title = 'OMP chat';
      _model = '';
    }
    if (sameTarget &&
        ((_boundSession != null &&
                connection.sessionId != null &&
                connection.sessionId != _boundSession) ||
            (_boundFile != null && connection.sessionFile != _boundFile))) {
      const error = HarnessException(
        'This connection refers to a different session. Create a separate chat.',
      );
      _fail(error);
      throw error;
    }
    _connection = connection;
    _boundSession ??= connection.sessionId;
    _boundFile ??= connection.sessionFile;
    _pendingCompaction = null;
    _readOnly = true;
    _streaming = false;
    _error = null;
    _activity = '';
    _phase = ConnectionPhase.connecting;
    _publish();
    try {
      final instances = await _api.status(connection.endpoint);
      _check(generation);
      final matches = instances
          .where((item) => item.name == connection.instance)
          .toList();
      if (matches.length != 1) {
        throw const HarnessException(
          'This relay instance no longer exists. Choose a running instance.',
        );
      }
      final instance = matches.single;
      if (!instance.ready ||
          !instance.rpc ||
          instance.sessionConflict ||
          instance.sessionId == null ||
          instance.sessionId!.isEmpty) {
        throw const HarnessException(
          'This instance is not ready for session-safe RPC attachment.',
        );
      }
      _validateSession(instance.sessionId, instance.sessionFile);
      _boundSession ??= instance.sessionId;
      final wire = await OmpdWire.connect(
        connection.endpoint,
        timeout: timeout,
      );
      if (generation != _generation || _disposed) {
        await wire.close();
        _check(generation);
      }
      _wire = wire;
      _bootstrapping = true;
      _bootstrapTimer = Timer(timeout * 3, () {
        if (generation == _generation && _bootstrapping) {
          _fail(
            const HarnessException(
              'Relay history did not finish loading in time. Reconnect when the session is quieter.',
            ),
          );
          unawaited(_close());
        }
      });
      _buffer.clear();
      _bufferBytes = 0;
      _historyBoundary = 0;
      _projectionReady = false;
      final attach = Completer<Map<String, Object?>>();
      _attach = attach;
      _subscription = wire.frames.listen(
        (frame) {
          if (generation == _generation) _receive(frame);
        },
        onError: (Object error) {
          if (generation == _generation) _fail(_safe(error));
        },
        onDone: () {
          if (generation == _generation && _phase != ConnectionPhase.error) {
            _fail(
              const HarnessException(
                'The relay connection closed. Reconnect to refresh history.',
              ),
            );
          }
        },
      );
      final replies = await Future.wait<Object?>([
        wire.send({
          'method': 'attach',
          'name': connection.instance,
          'mode': 'control',
        }),
        attach.future.timeout(timeout),
      ]);
      _check(generation);
      final info = replies[1] as Map<String, Object?>;
      if (info['name'] != connection.instance ||
          info['ready'] != true ||
          info['mode'] != 'control' ||
          info['generation'] is! int ||
          (instance.generation != null &&
              info['generation'] != instance.generation)) {
        throw const HarnessException(
          'The relay instance changed while attaching. Refresh the instance list.',
        );
      }
      _phase = ConnectionPhase.syncing;
      _publish();
      await _rpc('set_event_filter', {
        'events': null,
        'messageUpdates': 'full',
      });
      _check(generation);
      await _bootstrapContext(generation);
    } catch (error) {
      _check(generation, allowError: true);
      final safe = _safe(error);
      _fail(safe);
      await _close();
      throw safe;
    }
  }

  Future<void> _bootstrapContext(int generation, {int attempt = 0}) async {
    final compaction = _pendingCompaction;
    _pendingCompaction = null;
    final firstState = await _rpc('get_state');
    _check(generation);
    _applyState(firstState);
    final baseline = await _loadHistory(firstState);
    _check(generation);
    final finalState = await _rpc('get_state');
    _check(generation);
    _applyState(finalState);
    if (_readOnly) {
      throw const HarnessException(
        'Another client took control before history was ready. Reconnect explicitly.',
      );
    }
    final previousRows = List<_Row>.of(_rows);
    final previousEvents = List<AgentEvent>.of(_events);
    final previousEventSizes = List<int>.of(_eventSizes);
    final previousOccurrences = Map<String, int>.of(_occurrences);
    try {
      _installHistory(baseline);
    } catch (_) {
      _rows
        ..clear()
        ..addAll(previousRows);
      _historyBytes = previousRows.fold(0, (total, row) => total + row.bytes);
      _occurrences
        ..clear()
        ..addAll(previousOccurrences);
      _events
        ..clear()
        ..addAll(previousEvents);
      _eventSizes
        ..clear()
        ..addAll(previousEventSizes);
      _eventBytes = previousEventSizes.fold(0, (total, bytes) => total + bytes);
      rethrow;
    }
    if (_pendingCompaction != null) {
      if (attempt >= 2) {
        throw const HarnessException(
          'OMP context kept changing while loading. Reconnect when it is quieter.',
        );
      }
      _buffer.clear();
      _bufferBytes = 0;
      _historyBoundary = 0;
      _stateBoundary = 0;
      return _bootstrapContext(generation, attempt: attempt + 1);
    }
    if (compaction != null) {
      _lastCompaction = {
        'type': 'compaction',
        'id': 'rpc-compaction:${++_contextSequence}',
        'source': compaction,
      };
    }
    _bootstrapTimer?.cancel();
    _bootstrapTimer = null;
    _bootstrapping = false;
    _buffer.clear();
    _bufferBytes = 0;
    _phase = ConnectionPhase.live;
    _publish();
  }

  static bool _successfulCompaction(Map<String, Object?> event) =>
      event['type'] == 'auto_compaction_end' &&
      event['aborted'] == false &&
      event['errorMessage'] == null &&
      event['skipped'] != true &&
      event['result'] is Map;

  Future<void> _refreshContext() async {
    if (_bootstrapping) return;
    if (_readOnly) {
      _error =
          'OMP context changed while viewing. Reconnect explicitly to refresh its history.';
      return;
    }
    final generation = _generation;
    _bootstrapping = true;
    _phase = ConnectionPhase.syncing;
    _buffer.clear();
    _bufferBytes = 0;
    _historyBoundary = 0;
    _stateBoundary = 0;
    _bootstrapTimer = Timer(timeout * 3, () {
      if (generation == _generation && _bootstrapping) {
        _fail(
          const HarnessException(
            'OMP context refresh did not finish in time. Reconnect when it is quieter.',
          ),
        );
        unawaited(_close());
      }
    });
    _publish();
    try {
      await _bootstrapContext(generation);
    } catch (error) {
      if (generation != _generation || _disposed) return;
      _fail(_safe(error));
      await _close();
    }
  }

  void _receive(Map<String, Object?> frame) {
    try {
      if (_attach != null) {
        final attach = _attach!;
        _attach = null;
        final info = _map(frame['result']);
        if (frame.containsKey('error') ||
            info == null ||
            info['client_id'] is! String ||
            !RegExp(r'^c[0-9]+$').hasMatch(info['client_id'] as String)) {
          attach.completeError(
            const HarnessException(
              'The relay rejected the control attachment.',
            ),
          );
        } else {
          _clientId = info['client_id'] as String;
          _readOnly = info['mode'] != 'control';
          attach.complete(info);
        }
        return;
      }
      final notice = _map(frame['ompd']);
      if (notice != null) {
        switch (notice['event']) {
          case 'controller_changed':
            _readOnly = _controlLost || notice['controller'] != _clientId;
            if (_readOnly) {
              _controlLost = true;
              _questions.clear();
              _error =
                  'Another client took control. This chat is now read-only; reconnect explicitly to take control.';
              _rejectPending(
                const HarnessException(
                  'Control changed. Delivery may be uncertain; inspect history before retrying.',
                ),
              );
            }
            _publish();
            return;
          case 'process_exited':
          case 'daemon_shutdown':
            throw const HarnessException(
              'The relay worker or daemon stopped. Reconnect explicitly when it is ready.',
            );
          case 'error':
            throw const HarnessException(
              'The relay rejected a request or lost stream data. Reconnect to refresh history; inspect it before retrying.',
            );
          default:
            return;
        }
      }
      if (frame['type'] == 'response') {
        final id = frame['id'];
        final pending = id is String ? _pending.remove(id) : null;
        if (pending != null) {
          if (frame['command'] != pending.command) {
            pending.completer.completeError(
              const HarnessException('OMP returned a mismatched RPC response.'),
            );
          } else if (frame['success'] != true) {
            pending.completer.completeError(const _RpcRejected());
          } else {
            final data = _map(frame['data']) ?? <String, Object?>{};
            if (pending.command == 'get_messages' ||
                pending.command == 'get_messages_page') {
              _historyBoundary = _buffer.length;
            }
            if (pending.command == 'get_state') _stateBoundary = _buffer.length;
            if (pending.command == 'set_event_filter') _projectionReady = true;
            pending.completer.complete(data);
          }
        } else if (frame['command'] == 'get_state' &&
            frame['success'] == true) {
          // ompd's periodic state replies are broadcast with its own IDs.
          final state = _map(frame['data']);
          if (state != null) {
            _validateSession(state['sessionId'], state['sessionFile']);
            if (!_bootstrapping) {
              _applyState(state);
              _publish();
            }
          }
        }
        return;
      }
      if (frame['type'] == 'ready') return; // Intentionally stay on v1.
      if (_successfulCompaction(frame)) _pendingCompaction = frame;
      if (_bootstrapping) {
        // A previous controller may have selected deltas. The later full
        // history snapshot covers these pre-filter partial projections.
        final projection = _map(frame['message']);
        if (!_projectionReady &&
            frame['type'] == 'message_update' &&
            (projection == null || !projection.containsKey('content'))) {
          return;
        }
        final size = utf8.encode(jsonEncode(frame)).length;
        if (_buffer.length >= 4096 || _bufferBytes + size > 8 * 1024 * 1024) {
          throw const HarnessException(
            'Too much live data arrived while loading history. Reconnect when the session is quieter.',
          );
        }
        _bufferBytes += size;
        _buffer.add(frame);
      } else {
        _applyEvent(frame);
        _publish();
      }
    } catch (error) {
      _fail(_safe(error));
      unawaited(_close());
    }
  }

  Future<List<Map<String, Object?>>> _loadHistory(
    Map<String, Object?> state,
  ) async {
    if (state['isStreaming'] != true && state['isCompacting'] != true) {
      try {
        final all = <Map<String, Object?>>[];
        final cursors = <String>{};
        String? cursor;
        int? total;
        var bytes = 0;
        var pages = 0;
        do {
          if (++pages > 128) {
            throw const HarnessException(
              'OMP returned too many history pages.',
            );
          }
          final page = await _rpc('get_messages_page', {
            'limit': 100,
            'cursor': ?cursor,
          });
          final messages = _historyMessages(page);
          if (page['totalMessages'] is! int ||
              (page['totalMessages'] as int) < 0 ||
              (total != null && total != page['totalMessages'])) {
            throw const HarnessException('OMP returned invalid paged history.');
          }
          total = page['totalMessages'] as int;
          if (total > 10000) {
            throw const HarnessException(
              'This session history exceeds the mobile relay limit. Use a smaller session.',
            );
          }
          bytes += utf8.encode(jsonEncode(messages)).length;
          all.addAll(messages);
          if (all.length > 10000 || bytes > 8 * 1024 * 1024) {
            throw const HarnessException(
              'This session history exceeds the mobile relay limit. Use a smaller session.',
            );
          }
          final next = page['nextCursor'];
          if (next != null &&
              (next is! String || next.isEmpty || !cursors.add(next))) {
            throw const HarnessException(
              'OMP returned an invalid history cursor.',
            );
          }
          cursor = next as String?;
          if (cursor != null && messages.isEmpty) {
            throw const HarnessException(
              'OMP returned an empty incomplete history page.',
            );
          }
        } while (cursor != null);
        if (all.length != total) {
          throw const HarnessException(
            'OMP returned incomplete message history.',
          );
        }
        return all;
      } on _RpcRejected {
        // Older OMP, a busy session, or a stale cursor: use the current bounded
        // in-memory snapshot. Never retain a partial page set as full history.
      }
    }
    return _historyMessages(await _rpc('get_messages'));
  }

  static List<Map<String, Object?>> _historyMessages(
    Map<String, Object?> history,
  ) {
    final messages = history['messages'];
    if (messages is! List || messages.length > 10000) {
      throw const HarnessException(
        'The relay history is invalid or too large for this client.',
      );
    }
    return messages.map((value) {
      final message = _map(value);
      if (message == null || message['role'] is! String) {
        throw const HarnessException(
          'The relay returned invalid message history.',
        );
      }
      return message;
    }).toList();
  }

  Future<Map<String, Object?>> _rpc(
    String command, [
    Map<String, Object?> fields = const {},
  ]) async {
    final wire = _wire;
    if (wire == null || _clientId == null || _readOnly) {
      throw const HarnessException(
        'This relay attachment cannot send requests.',
      );
    }
    final id = 'r${++_requestId}';
    final key = '$_clientId:$id';
    final pending = _Pending(command);
    _pending[key] = pending;
    try {
      final values = await Future.wait<Object?>([
        wire.send({'id': id, 'type': command, ...fields}),
        pending.completer.future.timeout(timeout),
      ]);
      return values[1] as Map<String, Object?>;
    } on TimeoutException {
      const safe = HarnessException(
        'OMP did not answer in time. Delivery may be uncertain; inspect history before retrying.',
      );
      _fail(safe);
      unawaited(_close());
      throw safe;
    } finally {
      _pending.remove(key);
    }
  }

  void _validateSession(Object? session, Object? file) {
    if (session is! String ||
        session.isEmpty ||
        file is! String ||
        file.isEmpty ||
        (_boundSession != null && session != _boundSession) ||
        (_boundFile != null && file != _boundFile)) {
      throw const HarnessException(
        'The relay instance now has a different session. Old history was kept; create a separate chat.',
      );
    }
  }

  void _applyState(Map<String, Object?> state) {
    _validateSession(state['sessionId'], state['sessionFile']);
    if (state['isStreaming'] is! bool) {
      throw const HarnessException('OMP returned invalid session state.');
    }
    _title =
        state['sessionName'] is String &&
            (state['sessionName'] as String).trim().isNotEmpty
        ? state['sessionName'] as String
        : 'OMP chat';
    final model = _map(state['model']);
    _model = model?['name'] is String
        ? model!['name'] as String
        : model?['id'] is String
        ? model!['id'] as String
        : '';
    _streaming = state['isStreaming'] == true;
    _activity = _streaming ? 'OMP is working…' : '';
  }

  void _installHistory(List<Map<String, Object?>> baseline) {
    final occurrences = <String, int>{};
    final restored = <_Row>[];
    for (final message in baseline) {
      restored.add(_Row(_rowId(message, occurrences), message));
    }
    _rows.clear();
    _rows.addAll(restored);
    _occurrences
      ..clear()
      ..addAll(occurrences);
    _historyBytes = restored.fold(0, (total, row) => total + row.bytes);
    if (_historyBytes > 8 * 1024 * 1024) {
      throw const HarnessException(
        'This session history exceeds the mobile relay limit. Use a smaller session.',
      );
    }
    if (_streaming &&
        _rows.isNotEmpty &&
        _rows.last.message['role'] == 'assistant') {
      _rows.last.streaming = true;
    }
    _events.clear();
    _eventSizes.clear();
    _eventBytes = 0;
    // History has no RPC messageId. Bind events received before its response to
    // distinct baseline occurrences. Never replace newer baseline text with an
    // older partial event. Ambiguous timestamps fail closed rather than merge.
    final claimed = <int>{};
    final bindings = <String, _Row>{};
    final baselineIndex = <String, List<int>>{};
    for (var row = 0; row < baseline.length; row++) {
      baselineIndex.putIfAbsent(_identityKey(baseline[row]), () => []).add(row);
    }
    for (var index = 0; index < _buffer.length; index++) {
      final event = _buffer[index];
      final message = _map(event['message']);
      final id = event['messageId'];
      if ((index < _historyBoundary || event['type'] != 'message_start') &&
          message != null &&
          id is String &&
          !bindings.containsKey(id)) {
        final matches = (baselineIndex[_identityKey(message)] ?? const <int>[])
            .where((row) => !claimed.contains(row))
            .toList();
        if (matches.length > 1) {
          final exact = matches
              .where(
                (row) => jsonEncode(_rows[row].message) == jsonEncode(message),
              )
              .toList();
          if (exact.length != 1) {
            throw const HarnessException(
              'OMP history has ambiguous live message identities. Reconnect when the session is idle.',
            );
          }
          matches.clear();
          matches.add(exact.single);
        }
        if (matches.isNotEmpty) {
          final row = matches.first;
          claimed.add(row);
          _rows[row].rpcId = id;
          bindings[id] = _rows[row];
        }
      }
      final bound = id is String ? bindings[id] : null;
      if (index < _historyBoundary && bound != null && message != null) {
        bound.streaming =
            _streaming &&
            message['role'] == 'assistant' &&
            event['type'] != 'message_end';
        _recordEvent(event);
        continue;
      }
      if (index < _stateBoundary &&
          [
            'agent_start',
            'agent_end',
            'session_settled',
            'tool_execution_start',
            'tool_execution_update',
            'auto_compaction_start',
          ].contains(event['type'])) {
        _recordEvent(event);
        continue;
      }
      final streaming = _streaming;
      final activity = _activity;
      _applyEvent(event);
      if (index < _stateBoundary) {
        _streaming = streaming;
        _activity = activity;
        if (!streaming && id is String) {
          for (final row in _rows.where((row) => row.rpcId == id)) {
            row.streaming = false;
          }
        }
      }
      if (id is String && !bindings.containsKey(id)) {
        final added = _rows.where((row) => row.rpcId == id);
        if (added.isNotEmpty) bindings[id] = added.single;
      }
    }
  }

  static bool _sameMessage(Map<String, Object?> a, Map<String, Object?> b) {
    if (a['role'] != b['role']) return false;
    if (a['timestamp'] != null && b['timestamp'] != null) {
      return a['timestamp'] == b['timestamp'] &&
          a['toolCallId'] == b['toolCallId'];
    }
    return jsonEncode(a) == jsonEncode(b);
  }

  void _recordEvent(Map<String, Object?> event) {
    final sanitized = Map<String, Object?>.from(event);
    if (sanitized.containsKey('error')) {
      sanitized['error'] = 'OMP reported an error.';
    }
    if (sanitized.containsKey('errorMessage')) {
      sanitized['errorMessage'] = 'OMP reported an error.';
    }
    if (event['type'] == 'notice' && event['level'] == 'error') {
      sanitized['message'] = 'OMP reported an error. Check the workstation.';
    }
    _events.add(AgentEvent(sequence: ++_eventSequence, event: sanitized));
    final bytes = utf8.encode(jsonEncode(sanitized)).length;
    _eventSizes.add(bytes);
    _eventBytes += bytes;
    while (_events.length > 512 || _eventBytes > 8 * 1024 * 1024) {
      _events.removeAt(0);
      _eventBytes -= _eventSizes.removeAt(0);
    }
  }

  void _applyEvent(Map<String, Object?> event) {
    _recordEvent(event);
    switch (event['type']) {
      case 'message_start':
      case 'message_update':
      case 'message_end':
        final message = _map(event['message']);
        final id = event['messageId'];
        if (message == null ||
            id is! String ||
            message['role'] is! String ||
            (message['role'] == 'assistant' &&
                message['content'] is! List &&
                message['content'] is! String)) {
          throw const HarnessException(
            'OMP sent an unsupported message projection. Reconnect with full RPC v1 events.',
          );
        }
        var matches = _rows.where((row) => row.rpcId == id).toList();
        if (matches.isEmpty && event['type'] != 'message_start') {
          // Attaching mid-stream may produce no start event. The first update
          // binds the active snapshot tail instead of appending a duplicate.
          matches = _rows
              .where(
                (row) =>
                    row.rpcId == null && _sameMessage(row.message, message),
              )
              .toList();
          if (matches.length > 1) {
            throw const HarnessException(
              'OMP history has ambiguous live message identities. Reconnect when the session is idle.',
            );
          }
        }
        final bytes = utf8.encode(jsonEncode(message)).length;
        final row = matches.isEmpty
            ? _Row(_rowId(message, _occurrences), message, size: bytes)
            : matches.single;
        final nextBytes =
            _historyBytes + bytes - (matches.isEmpty ? 0 : row.bytes);
        if (nextBytes > 8 * 1024 * 1024 ||
            (matches.isEmpty && _rows.length >= 10000)) {
          throw const HarnessException(
            'This session history exceeds the mobile relay limit. Use a smaller session.',
          );
        }
        if (matches.isEmpty) _rows.add(row);
        row.rpcId = id;
        row.message = message;
        row.bytes = bytes;
        _historyBytes = nextBytes;
        row.streaming =
            event['type'] != 'message_end' && message['role'] == 'assistant';
        if (row.streaming) {
          _streaming = true;
          _activity = 'OMP is responding…';
        }
        break;
      case 'agent_start':
        _streaming = true;
        _activity = 'OMP is working…';
        break;
      case 'agent_end':
        _streaming = false;
        _activity = '';
        break;
      case 'session_settled':
        _streaming = false;
        _activity = '';
        for (final row in _rows) {
          row.streaming = false;
        }
        break;
      case 'prompt_result':
        if (event['status'] == 'error') {
          _error = 'OMP could not complete a prompt. Check the workstation.';
        }
        if (event['sessionSettled'] == true) {
          _streaming = false;
          _activity = '';
        }
        break;
      case 'tool_execution_start':
      case 'tool_execution_update':
        _activity = 'OMP is using a tool…';
        break;
      case 'auto_compaction_start':
        _activity = 'Compacting context…';
        break;
      case 'auto_compaction_end':
        _activity = _streaming ? 'OMP is working…' : '';
        if (event['errorMessage'] != null) {
          _error = 'OMP could not update context. Check the workstation.';
        }
        if (_successfulCompaction(event) && !_bootstrapping) {
          unawaited(_refreshContext());
        }
        break;
      case 'notice':
        if (event['level'] == 'error') {
          _error = 'OMP reported an error. Check the workstation.';
        }
        break;
      case 'extension_ui_request':
        _applyQuestion(event);
        break;
      case 'host_tool_call':
      case 'host_uri_request':
        _error =
            'This host callback needs the workstation client. No action was approved.';
        break;
    }
  }

  void _applyQuestion(Map<String, Object?> event) {
    if (event['method'] == 'cancel') {
      _questions.removeWhere(
        (_, question) => question['id'] == event['targetId'],
      );
      return;
    }
    if ([
      'notify',
      'setStatus',
      'setWidget',
      'setTitle',
      'set_editor_text',
    ].contains(event['method'])) {
      return;
    }
    if (_readOnly) return;
    if (event['id'] is! String ||
        !['select', 'confirm', 'input', 'editor'].contains(event['method'])) {
      _error =
          'This host question needs the workstation client. No answer was sent.';
      return;
    }
    if (!_questions.values.any((question) => question['id'] == event['id'])) {
      _questions[++_questionId] = event;
    }
  }

  @override
  Future<void> sendPrompt(String text) async {
    if (_sendingPrompt) throw const PromptBusyException();
    _requireWritable();
    if (text.trim().isEmpty) {
      throw const HarnessException('Enter a message before sending.');
    }
    _sendingPrompt = true;
    final generation = _generation;
    try {
      await _refreshState(generation);
      await _rpc('prompt', {
        'message': text,
        if (_streaming) 'streamingBehavior': 'steer',
      }); // Admission only; never replay.
    } finally {
      if (generation == _generation) _sendingPrompt = false;
    }
  }

  @override
  Future<void> abort() async {
    _requireWritable();
    final generation = _generation;
    await _refreshState(generation);
    await _rpc('abort');
  }

  @override
  Future<void> respond(int requestId, String? value) async {
    _requireWritable();
    final question = _questions[requestId];
    if (question == null) {
      throw const HarnessException(
        'This host question is no longer available.',
      );
    }
    final generation = _generation;
    await _refreshState(generation);
    if (!identical(_questions[requestId], question)) {
      throw const HarnessException(
        'This host question is no longer available.',
      );
    }
    final method = question['method'];
    final reply = <String, Object?>{
      'type': 'extension_ui_response',
      'id': question['id'],
    };
    if (value == null) {
      if (method == 'confirm') {
        reply['confirmed'] = false;
      } else {
        reply['cancelled'] = true;
      }
    } else if (method == 'confirm') {
      if (value != 'Yes' && value != 'No') {
        throw const HarnessException('Choose Yes or No.');
      }
      reply['confirmed'] = value == 'Yes';
    } else {
      if (method == 'select' &&
          !(question['options'] is List &&
              (question['options'] as List).contains(value))) {
        throw const HarnessException('Choose an available host option.');
      }
      reply['value'] = value;
    }
    // Callback IDs are the original OMP IDs, never the daemon client prefix.
    await _wire!.send(reply);
    _questions.remove(requestId);
    _publish();
  }

  Future<void> _refreshState(int generation) async {
    final state = await _rpc('get_state');
    _check(generation);
    try {
      _applyState(state);
    } on HarnessException catch (error) {
      _fail(error);
      unawaited(_close());
      rethrow;
    }
    _requireWritable();
    _publish();
  }

  void _requireWritable() {
    if (!_snapshot.canSend || _readOnly || _wire == null) {
      throw const HarnessException(
        'Connect as controller before sending or interrupting.',
      );
    }
  }

  void _check(int generation, {bool allowError = false}) {
    if (_disposed || generation != _generation) {
      throw const HarnessException(
        'The relay connection was replaced or disconnected.',
      );
    }
    if (!allowError && _phase == ConnectionPhase.error) {
      throw HarnessException(_error ?? 'The relay connection failed.');
    }
  }

  static HarnessException _safe(Object error) => error is HarnessException
      ? error
      : error is TimeoutException
      ? const HarnessException('The relay did not answer in time.')
      : const HarnessException(
          'The relay operation failed. Check the workstation connection.',
        );

  void _rejectPending(HarnessException error) {
    final attach = _attach;
    _attach = null;
    if (attach != null && !attach.isCompleted) attach.completeError(error);
    for (final pending in _pending.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error);
      }
    }
    _pending.clear();
  }

  void _fail(HarnessException error) {
    _phase = ConnectionPhase.error;
    _readOnly = true;
    _streaming = false;
    _activity = '';
    _error = error.message;
    _questions.clear();
    for (final row in _rows) {
      row.streaming = false;
    }
    _rejectPending(error);
    _publish();
  }

  Future<void> _close() async {
    _bootstrapTimer?.cancel();
    _bootstrapTimer = null;
    _rejectPending(
      const HarnessException(
        'The relay connection was closed. Delivery may be uncertain; inspect history before retrying.',
      ),
    );
    final subscription = _subscription;
    final wire = _wire;
    _subscription = null;
    _wire = null;
    _clientId = null;
    _bootstrapping = false;
    _buffer.clear();
    _questions.clear();
    _sendingPrompt = false;
    await subscription?.cancel();
    await wire?.close();
  }

  @override
  Future<void> disconnect() async {
    ++_generation;
    await _close();
    _phase = ConnectionPhase.disconnected;
    _readOnly = true;
    _streaming = false;
    for (final row in _rows) {
      row.streaming = false;
    }
    _error = null;
    _activity = '';
    _publish();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await disconnect();
    await _changes.close();
  }

  void _publish() {
    _snapshot = HarnessSnapshot(
      phase: _phase,
      title: _title,
      sessionId: _boundSession,
      endpoint: _connection?.endpoint.toString() ?? '',
      model: _model,
      readOnly: _readOnly,
      isStreaming: _streaming,
      activity: _activity,
      error: _error,
      messages: List.unmodifiable(
        _rows
            .where(
              (row) =>
                  !(['custom', 'hookMessage'].contains(row.message['role']) &&
                      row.message['display'] == false),
            )
            .map(_render),
      ),
      rawEntries: List.unmodifiable([?_lastCompaction, ..._rows.map(_entry)]),
      agentEvents: List.unmodifiable(_events),
      questions: List.unmodifiable(
        _questions.entries.map((entry) {
          final request = entry.value;
          final confirm = request['method'] == 'confirm';
          final options = confirm
              ? ['Yes', 'No']
              : request['options'] is List
              ? (request['options'] as List).whereType<String>().toList()
              : <String>[];
          return HarnessQuestion(
            id: entry.key,
            title: request['title'] is String
                ? request['title'] as String
                : 'Host question',
            kind: request['method'] as String,
            options: List.unmodifiable(
              options.map((label) => QuestionOption(label)),
            ),
            prefill: request['prefill'] is String
                ? request['prefill'] as String
                : '',
            helpText: request['message'] is String
                ? request['message'] as String
                : null,
          );
        }),
      ),
    );
    if (!_changes.isClosed) _changes.add(_snapshot);
  }

  static String _identityKey(Map<String, Object?> message) =>
      message['timestamp'] == null
      ? jsonEncode(message)
      : jsonEncode([
          message['role'],
          message['timestamp'],
          message['toolCallId'],
        ]);

  static String _rowId(Map<String, Object?> message, Map<String, int> counts) {
    // Stable presentation/overlay anchors, not host run IDs. Real host
    // timestamps survive reconnect and process recreation; occurrences retain
    // distinct repeated messages without including transcript text in IDs.
    final key = jsonEncode([
      message['role'],
      message['timestamp'],
      message['toolCallId'],
    ]);
    final occurrence = counts[key] ?? 0;
    counts[key] = occurrence + 1;
    return 'message:$key:$occurrence';
  }

  static Map<String, Object?> _entry(_Row row) {
    final message = row.message;
    final role = message['role'];
    if (role == 'custom' || role == 'hookMessage') {
      return {...message, 'id': row.id, 'type': 'custom_message'};
    }
    if (role == 'compactionSummary' || role == 'branchSummary') {
      return {
        ...message,
        'id': row.id,
        'type': role == 'compactionSummary' ? 'compaction' : 'branch_summary',
      };
    }
    return {'type': 'message', 'id': row.id, 'message': message};
  }

  static DateTime? _date(Object? value) {
    if (value is String) return DateTime.tryParse(value);
    if (value is num && value.isFinite && value.abs() <= 8640000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }
    return null;
  }

  static ChatMessage _render(_Row row) {
    final message = row.message;
    final collab =
        message['role'] == 'custom' && message['customType'] == 'collab-prompt';
    final author = collab
        ? (_map(message['details'])?['from'])
        : message['toolName'];
    final role = collab
        ? MessageRole.user
        : switch (message['role']) {
            'user' => MessageRole.user,
            'assistant' => MessageRole.assistant,
            'toolResult' => MessageRole.tool,
            _ => MessageRole.system,
          };
    final content = message['content'] ?? message['summary'];
    final texts = <String>[];
    final thoughts = <String>[];
    if (content is String) texts.add(content);
    if (content is List) {
      for (final block in content) {
        final item = _map(block);
        if (item?['type'] == 'text' && item?['text'] is String) {
          texts.add(item!['text'] as String);
        }
        if (item?['type'] == 'thinking' && item?['thinking'] is String) {
          thoughts.add(item!['thinking'] as String);
        }
      }
    }
    final text = VoiceDirective.strip(texts.join('\n'));
    final time = message['timestamp'];
    return ChatMessage(
      id: row.id,
      role: role,
      text: text,
      thinking: thoughts.join('\n'),
      prose: role == MessageRole.user || role == MessageRole.assistant
          ? text
          : null,
      origin: switch (role) {
        MessageRole.user =>
          collab ? ChatMessageOrigin.collabUser : ChatMessageOrigin.remoteUser,
        MessageRole.assistant => ChatMessageOrigin.remoteAssistant,
        MessageRole.tool => ChatMessageOrigin.tool,
        MessageRole.system => ChatMessageOrigin.system,
      },
      source: message,
      author: author is String ? author : null,
      timestamp: _date(time),
      isStreaming: row.streaming,
      isError: message['isError'] == true || message['stopReason'] == 'error',
    );
  }
}

Map<String, Object?>? _map(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : null;

final class _Pending {
  _Pending(this.command);
  final String command;
  final completer = Completer<Map<String, Object?>>();
}

final class _Row {
  _Row(this.id, this.message, {int? size})
    : bytes = size ?? utf8.encode(jsonEncode(message)).length;
  String id;
  String? rpcId;
  Map<String, Object?> message;
  int bytes;
  bool streaming = false;
}

final class _RpcRejected extends HarnessException {
  const _RpcRejected()
    : super('OMP rejected this request. Check the session on the workstation.');
}
