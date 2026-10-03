import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Synthetic ompd control + OMP RPC peer, not a HarnessClient replacement.
/// Wire reference: ompd daemon.rs AttachInfo/Request, OMP rpc-types.ts.
final class OmpdFixture {
  OmpdFixture._(this._server) {
    _instances[existingName] = _Instance(
      existingName,
      existingSessionId,
      'Synthetic relay conversation',
      messages: [_message('assistant', 'synthetic history', 1700000000000)],
    );
    _listener = _server.listen((socket) {
      final peer = _Peer(socket, this);
      _peers.add(peer);
    });
  }

  static const existingName = 'synthetic-existing';
  static const existingSessionId = 'synthetic-session-existing';
  static const newName = 'synthetic-new';
  static const newSessionId = 'synthetic-session-new';
  static const partialReply = 'synthetic streamed';
  static const finalReply = 'synthetic streamed reply';

  final ServerSocket _server;
  late final StreamSubscription<Socket> _listener;
  final Set<_Peer> _peers = {};
  final Map<String, _Instance> _instances = {};
  final List<Map<String, Object?>> controlRequests = [];
  final List<Map<String, Object?>> rpcRequests = [];
  final List<Map<String, Object?>> starts = [];
  final List<String> attachments = [];
  final List<String> prompts = [];
  final List<Object> errors = [];
  _PendingPrompt? _pending;
  int _nextClient = 0;
  bool _closed = false;

  String get endpoint => '127.0.0.1:${_server.port}';
  bool get hasPendingPrompt => _pending != null;

  static Future<OmpdFixture> start() async =>
      OmpdFixture._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  void _control(_Peer peer, Map<String, Object?> request) {
    controlRequests.add(request);
    switch (request['method']) {
      case 'status':
        final name = request['name'];
        peer.send({
          'result': name == null
              ? [for (final instance in _instances.values) instance.status()]
              : _instances[name]!.status(),
        });
        return;
      case 'start':
        starts.add(request);
        final name = request['name'];
        if (name != newName || _instances.containsKey(name)) {
          throw StateError('Unexpected synthetic start request');
        }
        final instance = _Instance(
          newName,
          newSessionId,
          'Synthetic new session',
          profile: request['profile'] as String?,
        );
        _instances[newName] = instance;
        // The start ACK is not readiness. Subsequent status supplies readiness.
        peer.send({
          'result': {
            ...instance.status(),
            'ready': false,
            'session': {'id': null, 'name': null, 'file': null},
          },
        });
        return;
      case 'attach':
        final instance = _instances[request['name']];
        if (instance == null || request['mode'] != 'control') {
          throw StateError('Unexpected synthetic attach request');
        }
        peer.instance = instance;
        peer.clientId = 'c${++_nextClient}';
        attachments.add(instance.name);
        peer.send({
          'result': {
            'name': instance.name,
            'client_id': peer.clientId,
            'mode': 'control',
            'generation': 1,
            'ready': true,
          },
        });
        return;
      default:
        // Acceptance forbids stop/shutdown/send or real process management.
        throw StateError(
          'Unsupported fixture control method ${request['method']}',
        );
    }
  }

  void _rpc(_Peer peer, Map<String, Object?> request) {
    rpcRequests.add(request);
    final instance = peer.instance!;
    final id = request['id'];
    if (id is! String || id.isEmpty) {
      throw StateError('Fixture RPC requires a correlation id');
    }
    switch (request['type']) {
      case 'set_event_filter':
        if (request['events'] != null || request['messageUpdates'] != 'full') {
          throw StateError('Fixture requires full message event projection');
        }
        peer.response(request, {'events': null, 'messageUpdates': 'full'});
        return;
      case 'get_state':
        peer.response(request, {
          'sessionId': instance.sessionId,
          'sessionName': instance.title,
          'sessionFile': '/synthetic/${instance.name}.jsonl',
          'model': {'id': 'synthetic-model', 'provider': 'fixture'},
          'thinkingLevel': 'off',
          'isStreaming': _pending?.instance == instance,
          'isCompacting': false,
          'steeringMode': 'all',
          'followUpMode': 'one-at-a-time',
          'interruptMode': 'immediate',
          'autoCompactionEnabled': true,
          'fastModeEnabled': false,
          'fastModeActive': false,
          'tokensPerSecond': null,
          'messageCount': instance.messages.length,
          'queuedMessageCount': 0,
          'hasPendingAsyncWork': false,
          'isSettled': _pending?.instance != instance,
          'queuedMessages': {'steering': <String>[], 'followUp': <String>[]},
          'todoPhases': <Object>[],
          'goal': null,
        });
        return;
      case 'get_messages':
        peer.response(request, {'messages': instance.messages});
        return;
      case 'get_messages_page':
        peer.response(request, {
          'messages': instance.messages,
          'totalMessages': instance.messages.length,
        });
        return;
      case 'prompt':
        final text = request['message'];
        if (_pending != null || text is! String || text.isEmpty) {
          throw StateError('Unexpected synthetic prompt request');
        }
        prompts.add(text);
        peer.response(request, null);
        final user = _message('user', text, 1700000001000);
        instance.messages.add(user);
        peer.event('message_start', 'synthetic-user-1', user);
        peer.event('message_end', 'synthetic-user-1', user);
        peer.send({'type': 'agent_start'});
        peer.event(
          'message_start',
          'synthetic-assistant-1',
          _message('assistant', '', 1700000002000),
        );
        final partial = _message('assistant', partialReply, 1700000002000);
        peer.send({
          'type': 'message_update',
          'messageId': 'synthetic-assistant-1',
          'message': partial,
          'assistantMessageEvent': {
            'type': 'text_delta',
            'contentIndex': 0,
            'delta': partialReply,
            'partial': partial,
          },
        });
        _pending = _PendingPrompt(peer, instance, '${peer.clientId}:$id');
        return;
      default:
        throw StateError('Unsupported fixture RPC ${request['type']}');
    }
  }

  /// Release completion only after UI visibly rendered the partial reply.
  void finishPrompt() {
    final pending = _pending;
    if (pending == null) throw StateError('No synthetic prompt is streaming');
    final message = _message('assistant', finalReply, 1700000002000);
    pending.instance.messages.add(message);
    pending.peer.event('message_end', 'synthetic-assistant-1', message);
    pending.peer.send({
      'type': 'agent_end',
      'messages': [message],
      'isTerminal': true,
    });
    pending.peer.send({
      'type': 'prompt_result',
      'id': pending.id,
      'status': 'completed',
      'agentInvoked': true,
      'sessionSettled': true,
    });
    pending.peer.send({'type': 'session_settled'});
    _pending = null;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final peer in List<_Peer>.of(_peers)) {
      peer.socket.destroy();
      await peer.subscription.cancel();
    }
    _peers.clear();
    await _listener.cancel();
    await _server.close();
  }
}

Map<String, Object?> _message(String role, String text, int timestamp) => {
  'role': role,
  'content': [
    {'type': 'text', 'text': text},
  ],
  'timestamp': timestamp,
  if (role == 'assistant') ...{
    'api': 'synthetic-api',
    'provider': 'fixture',
    'model': 'synthetic-model',
    'stopReason': 'stop',
    'usage': {
      'input': 0,
      'output': 0,
      'cacheRead': 0,
      'cacheWrite': 0,
      'totalTokens': 0,
      'cost': {
        'input': 0,
        'output': 0,
        'cacheRead': 0,
        'cacheWrite': 0,
        'total': 0,
      },
    },
  },
};

final class _Instance {
  _Instance(
    this.name,
    this.sessionId,
    this.title, {
    this.profile,
    List<Map<String, Object?>>? messages,
  }) : messages = messages ?? [];

  final String name;
  final String sessionId;
  final String title;
  final String? profile;
  final List<Map<String, Object?>> messages;

  Map<String, Object?> status() => {
    'name': name,
    'profile': profile,
    'state': 'running',
    'pid': 123,
    'last_pid': 123,
    'ready': true,
    'started_at': 1700000000000,
    'exited_at': null,
    'exit_code': null,
    'exit_signal': null,
    'restart_count': 0,
    'error': null,
    'generation': 1,
    'clients': {'controller': null, 'viewers': <String>[]},
    'rpc': true,
    'session': {
      'id': sessionId,
      'name': title,
      'file': '/synthetic/$name.jsonl',
    },
    'stderr_log': '/synthetic/$name.stderr.log',
  };
}

final class _Peer {
  _Peer(this.socket, this.fixture) {
    subscription = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _line,
          onError: (Object error) {
            if (!fixture._closed) fixture.errors.add(error);
          },
          onDone: () {
            fixture._peers.remove(this);
            socket.destroy();
          },
        );
  }

  final Socket socket;
  final OmpdFixture fixture;
  late final StreamSubscription<String> subscription;
  _Instance? instance;
  String? clientId;

  void _line(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) {
        throw StateError('Expected a JSON object');
      }
      final frame = Map<String, Object?>.from(decoded);
      if (instance == null) {
        fixture._control(this, frame);
      } else {
        fixture._rpc(this, frame);
      }
    } catch (error) {
      fixture.errors.add(error);
      send({'error': 'Synthetic fixture rejected a frame'});
      socket.destroy();
    }
  }

  void send(Map<String, Object?> frame) => socket.writeln(jsonEncode(frame));

  void response(Map<String, Object?> request, Map<String, Object?>? data) =>
      send({
        'type': 'response',
        // ompd namespaces RPC correlation ids by the attached client.
        'id': '$clientId:${request['id']}',
        'command': request['type'],
        'success': true,
        'data': ?data,
      });

  void event(String type, String id, Map<String, Object?> message) =>
      send({'type': type, 'messageId': id, 'message': message});
}

final class _PendingPrompt {
  const _PendingPrompt(this.peer, this.instance, this.id);
  final _Peer peer;
  final _Instance instance;
  final String id;
}
