// Native Raiju replica of OMP collab protocol v3. Frame semantics are adapted
// from @oh-my-pi/collab-web/src/lib/client.ts and @oh-my-pi/pi-wire.
import 'dart:convert';

import 'voice_directive.dart';
import 'harness.dart';

final class CollabReplica {
  CollabReplica({required this.endpoint, void Function()? onChange})
    : _onChange = onChange;

  final String endpoint;
  final void Function()? _onChange;
  final List<Map<String, Object?>> _entries = [];
  final Set<String> _entryIds = {};
  final Map<String, _ActiveTool> _tools = {};
  final List<HarnessQuestion> _questions = [];
  final List<AgentEvent> _agentEvents = [];
  int _eventSequence = 0;
  Map<String, Object?>? _stream;
  bool _streamDone = false;
  bool _hasWelcome = false;
  String _title = 'OMP chat';
  DateTime? _sessionStartedAt;
  bool _nameSeenInState = false;
  String? _sessionId;
  String _model = '';
  ConnectionPhase _phase = ConnectionPhase.disconnected;
  bool _readOnly = true;
  bool _streaming = false;
  String _activity = '';
  String? _error;
  late HarnessSnapshot _snapshot = _build();

  HarnessSnapshot get snapshot => _snapshot;

  void connecting() {
    _hasWelcome = false;
    _phase = ConnectionPhase.connecting;
    _readOnly = true;
    _error = null;
    _activity = 'Connecting securely…';
    _commit();
  }

  void syncing({required bool reconnecting}) {
    _hasWelcome = false;
    _questions.clear();
    _phase = reconnecting
        ? ConnectionPhase.reconnecting
        : ConnectionPhase.syncing;
    _readOnly = true;
    _error = null;
    _activity = reconnecting ? 'Reconnecting…' : 'Loading conversation…';
    _commit();
  }

  void closed({String? error, bool ended = false}) {
    _phase = ended
        ? ConnectionPhase.ended
        : (error == null
              ? ConnectionPhase.disconnected
              : ConnectionPhase.error);
    _readOnly = true;
    _streaming = false;
    _activity = '';
    _error = error;
    _tools.clear();
    _questions.clear();
    _commit();
  }

  /// Applies one decrypted host frame. Returns true on transition to live.
  bool apply(Map<String, Object?> frame) {
    final type = frame['t'];
    var becameLive = false;
    switch (type) {
      case 'welcome':
        final proto = _integer(frame['proto']);
        if (proto != 3) {
          throw const HarnessException(
            'This host uses an incompatible collaboration protocol.',
          );
        }
        final header = _map(frame['header']);
        final state = _map(frame['state']);
        final entryCount = _integer(frame['entryCount']);
        if (header == null ||
            _nullableString(header['id']) == null ||
            state == null ||
            entryCount == null ||
            entryCount < 0) {
          throw const HarnessException(
            'The host sent an invalid collaboration welcome.',
          );
        }
        _title = _string(header['title']).trim();
        _sessionStartedAt = DateTime.tryParse(_string(header['timestamp']));
        _nameSeenInState = false;
        _sessionId = _nullableString(header['id']);
        _entries.clear();
        _entryIds.clear();
        _stream = null;
        _agentEvents.clear();
        _streamDone = false;
        _tools.clear();
        _questions.clear();
        _hasWelcome = true;
        _readOnly = frame['readOnly'] == true;
        _applyState(state, welcome: true);
        _phase = ConnectionPhase.syncing;
        _error = null;
        _activity = 'Loading conversation…';
        if (entryCount == 0) {
          _phase = ConnectionPhase.live;
          _activity = '';
          becameLive = true;
        }
        break;
      case 'snapshot-chunk':
        if (!_hasWelcome) {
          throw const HarnessException(
            'The host sent conversation data before the welcome.',
          );
        }
        final entries = frame['entries'];
        if (entries is List) {
          for (final item in entries) {
            final entry = _map(item);
            if (entry != null) _appendEntry(entry);
          }
        }
        if (frame['final'] == true) {
          _phase = ConnectionPhase.live;
          _activity = _streaming ? 'OMP is working…' : '';
          becameLive = true;
        }
        break;
      case 'entry':
        final entry = _map(frame['entry']);
        if (entry != null) _appendEntry(entry, live: true);
        break;
      case 'event':
        final event = _map(frame['event']);
        if (event != null) {
          _agentEvents.add(
            AgentEvent(sequence: ++_eventSequence, event: event),
          );
          if (_agentEvents.length > 256) _agentEvents.removeAt(0);
          _applyEvent(event);
        }
        break;
      case 'state':
        _applyState(_map(frame['state']));
        break;
      case 'ui-request':
        final request = _question(_map(frame['request']));
        if (request != null &&
            !_questions.any((item) => item.id == request.id)) {
          _questions.add(request);
        }
        break;
      case 'ui-request-end':
        final id = _integer(frame['reqId']);
        _questions.removeWhere((item) => item.id == id);
        break;
      case 'bye':
        closed(
          error: _nullableString(frame['reason']) ?? 'The host ended sharing.',
          ended: true,
        );
        return false;
      case 'error':
        throw HarnessException(
          _nullableString(frame['message']) ?? 'The host rejected the request.',
        );
      default:
        // Forward-compatible: unknown host frames are intentionally ignored.
        return false;
    }
    _commit();
    return becameLive;
  }

  void answered(int id) {
    _questions.removeWhere((item) => item.id == id);
    _commit();
  }

  void reportError(String message) {
    _error = message;
    _commit();
  }

  void _appendEntry(Map<String, Object?> entry, {bool live = false}) {
    final id = _nullableString(entry['id']);
    if (id != null && !_entryIds.add(id)) return;
    _entries.add(entry);
    if (entry['type'] == 'title_change' && (live || !_nameSeenInState)) {
      final title = _nullableString(entry['title']);
      if (title != null) {
        _title = title.trim();
        if (live) _nameSeenInState = true;
      }
    }
    final message = _map(entry['message']);
    if (entry['type'] == 'message' &&
        message?['role'] == 'assistant' &&
        _stream != null) {
      _stream = null;
      _streamDone = false;
    }
  }

  void _applyState(Map<String, Object?>? state, {bool welcome = false}) {
    if (state == null) return;
    // A welcome may use header.title when older hosts omit sessionName.
    // Subsequent full states omit sessionName after a live title clear.
    if (state.containsKey('sessionName')) {
      _nameSeenInState = true;
      _title = _string(state['sessionName']).trim();
    } else if (!welcome) {
      _nameSeenInState = true;
      _title = '';
    }
    _streaming = state['isStreaming'] == true;
    final model = _map(state['model']);
    _model =
        _nullableString(model?['name']) ??
        _nullableString(model?['id']) ??
        _model;
    if (!_streaming) {
      _tools.clear();
      if (_stream != null) {
        _stream = null;
        _streamDone = false;
      }
      _activity = '';
    } else {
      _activity = _tools.isEmpty ? 'OMP is working…' : _toolActivity;
    }
  }

  void _applyEvent(Map<String, Object?> event) {
    switch (event['type']) {
      case 'message_start':
      case 'message_update':
        final message = _map(event['message']);
        if (message?['role'] == 'assistant') {
          _stream = message;
          _streamDone = false;
          _streaming = true;
          _activity = 'OMP is responding…';
        }
        break;
      case 'message_end':
        final message = _map(event['message']);
        if (message?['role'] == 'assistant') {
          _stream = message;
          _streamDone = true;
        }
        break;
      case 'tool_execution_start':
      case 'tool_execution_update':
        final id = _nullableString(event['toolCallId']);
        if (id != null) {
          _tools[id] = _ActiveTool(
            id: id,
            name: _nullableString(event['toolName']) ?? 'tool',
            text: _toolText(event),
            isError: false,
          );
          _streaming = true;
          _activity = _toolActivity;
        }
        break;
      case 'tool_execution_end':
        final id = _nullableString(event['toolCallId']);
        if (id != null) _tools.remove(id);
        _activity = _tools.isEmpty && _streaming
            ? 'OMP is working…'
            : _toolActivity;
        break;
      case 'agent_start':
        _streaming = true;
        _activity = 'OMP is working…';
        break;
      case 'agent_end':
        _streaming = false;
        _tools.clear();
        _activity = '';
        break;
      case 'notice':
        if (event['level'] == 'error') {
          _error = _nullableString(event['message']);
        }
        break;
      case 'auto_compaction_start':
        _activity = 'Compacting context…';
        break;
      case 'auto_retry_start':
        _activity = 'Retrying response…';
        break;
      default:
        break;
    }
  }

  String get _toolActivity =>
      _tools.isEmpty ? '' : 'Using ${_tools.values.last.name}…';

  HarnessSnapshot _build() {
    final messages = <ChatMessage>[];
    for (final entry in _entries) {
      final rendered = _renderEntry(entry);
      if (rendered != null) messages.add(rendered);
    }
    if (_stream != null) {
      messages.add(
        _renderMessage(
          id: 'stream:${_stream!['timestamp'] ?? 'active'}',
          message: _stream!,
          timestamp: null,
          streaming: !_streamDone,
        ),
      );
    }
    for (final tool in _tools.values) {
      messages.add(
        ChatMessage(
          id: 'tool:${tool.id}',
          role: MessageRole.tool,
          text: tool.text.isEmpty ? 'Running ${tool.name}…' : tool.text,
          author: tool.name,
          isStreaming: true,
          isError: tool.isError,
        ),
      );
    }
    return HarnessSnapshot(
      phase: _phase,
      title: _title,
      sessionId: _sessionId,
      sessionStartedAt: _sessionStartedAt,
      endpoint: endpoint,
      model: _model,
      messages: List.unmodifiable(messages),
      readOnly: _readOnly,
      isStreaming: _streaming,
      activity: _activity,
      error: _error,
      questions: List.unmodifiable(_questions),
      rawEntries: List.unmodifiable(_entries),
      agentEvents: List.unmodifiable(_agentEvents),
    );
  }

  ChatMessage? _renderEntry(Map<String, Object?> entry) {
    final type = entry['type'];
    final id =
        _nullableString(entry['id']) ?? 'entry:${_entries.indexOf(entry)}';
    final timestamp = DateTime.tryParse(
      _nullableString(entry['timestamp']) ?? '',
    );
    if (type == 'message') {
      final message = _map(entry['message']);
      if (message == null) return null;
      return _renderMessage(id: id, message: message, timestamp: timestamp);
    }
    if (type == 'custom_message') {
      if (entry['display'] == false) return null;
      final customType = entry['customType'];
      final details = _map(entry['details']);
      final rawText = _contentText(entry['content']);
      return ChatMessage(
        id: id,
        role: customType == 'collab-prompt'
            ? MessageRole.user
            : MessageRole.system,
        text: VoiceDirective.strip(rawText),
        prose: customType == 'collab-prompt'
            ? VoiceDirective.strip(_proseText(entry['content']))
            : null,
        source: entry,
        origin: customType == 'collab-prompt'
            ? ChatMessageOrigin.collabUser
            : ChatMessageOrigin.system,
        author: customType == 'collab-prompt'
            ? _nullableString(details?['from'])
            : null,
        timestamp: timestamp,
      );
    }
    if (type == 'compaction' || type == 'branch_summary') {
      return ChatMessage(
        id: id,
        role: MessageRole.system,
        text:
            _nullableString(entry['summary']) ??
            'Conversation context updated.',
        timestamp: timestamp,
      );
    }
    return null;
  }

  ChatMessage _renderMessage({
    required String id,
    required Map<String, Object?> message,
    required DateTime? timestamp,
    bool streaming = false,
  }) {
    final roleText = message['role'];
    final role = switch (roleText) {
      'user' => MessageRole.user,
      'assistant' => MessageRole.assistant,
      'toolResult' => MessageRole.tool,
      _ => MessageRole.system,
    };
    final content = message['content'];
    return ChatMessage(
      id: id,
      role: role,
      text: VoiceDirective.strip(_contentText(content)),
      prose: role == MessageRole.user || role == MessageRole.assistant
          ? VoiceDirective.strip(_proseText(content))
          : null,
      source: message,
      origin: switch (role) {
        MessageRole.user => ChatMessageOrigin.remoteUser,
        MessageRole.assistant => ChatMessageOrigin.remoteAssistant,
        MessageRole.tool => ChatMessageOrigin.tool,
        MessageRole.system => ChatMessageOrigin.system,
      },
      author: role == MessageRole.tool
          ? _nullableString(message['toolName'])
          : null,
      timestamp: timestamp ?? _millisDate(message['timestamp']),
      isStreaming: streaming,
      thinking: _thinkingText(content),
      isError: message['isError'] == true || message['stopReason'] == 'error',
    );
  }

  void _commit() {
    _snapshot = _build();
    _onChange?.call();
  }
}

final class _ActiveTool {
  const _ActiveTool({
    required this.id,
    required this.name,
    required this.text,
    required this.isError,
  });
  final String id;
  final String name;
  final String text;
  final bool isError;
}

HarnessQuestion? _question(Map<String, Object?>? request) {
  if (request == null) return null;
  final id = _integer(request['reqId']);
  final kind = _nullableString(request['kind']);
  final title = _nullableString(request['title']);
  if (id == null || kind == null || title == null) return null;
  final options = <QuestionOption>[];
  if (request['options'] case final List values) {
    for (final value in values) {
      if (value is String) {
        options.add(QuestionOption(value));
      } else {
        final item = _map(value);
        final label = _nullableString(item?['label']);
        if (label != null) {
          options.add(
            QuestionOption(
              label,
              description: _nullableString(item?['description']),
            ),
          );
        }
      }
    }
  }
  return HarnessQuestion(
    id: id,
    title: title,
    kind: kind,
    options: List.unmodifiable(options),
    prefill: _nullableString(request['prefill']) ?? '',
    helpText: _nullableString(request['helpText']),
    selectionMarker: _nullableString(request['selectionMarker']),
    checkedIndices: request['checkedIndices'] is List
        ? List.unmodifiable(
            (request['checkedIndices'] as List).whereType<num>().map(
              (n) => n.toInt(),
            ),
          )
        : const [],
    markableCount: _integer(request['markableCount']),
  );
}

String _contentText(Object? content) {
  if (content is String) return content;
  if (content is! List) return '';
  final parts = <String>[];
  for (final value in content) {
    final block = _map(value);
    if (block?['type'] == 'text') {
      final text = _nullableString(block?['text']);
      if (text != null) parts.add(text);
    } else if (block?['type'] == 'toolCall') {
      final name = _nullableString(block?['name']);
      if (name != null) parts.add('Using $name…');
    }
  }
  return parts.join('\n');
}

String _proseText(Object? content) {
  if (content is String) return content;
  if (content is! List) return '';
  return content
      .map(_map)
      .where((block) => block?['type'] == 'text')
      .map((block) => _nullableString(block?['text']) ?? '')
      .join('\n');
}

String _thinkingText(Object? content) {
  if (content is! List) return '';
  return content
      .map(_map)
      .where((block) => block?['type'] == 'thinking')
      .map((block) => _nullableString(block?['thinking']) ?? '')
      .where((text) => text.isNotEmpty)
      .join('\n');
}

String _toolText(Map<String, Object?> event) {
  final value = event['partialResult'] ?? event['result'];
  if (value == null) return '';
  if (value is String) return value;
  try {
    return jsonEncode(value);
  } catch (_) {
    return value.toString();
  }
}

Map<String, Object?>? _map(Object? value) {
  if (value is! Map) return null;
  return value.map((key, item) => MapEntry(key.toString(), item));
}

String _string(Object? value) => value is String ? value : '';
String? _nullableString(Object? value) => value is String ? value : null;
int? _integer(Object? value) => value is num ? value.toInt() : null;
DateTime? _millisDate(Object? value) =>
    value is num ? DateTime.fromMillisecondsSinceEpoch(value.toInt()) : null;
