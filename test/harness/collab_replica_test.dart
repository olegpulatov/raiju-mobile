import 'package:raiju_mobile/harness/collab_replica.dart';
import 'package:raiju_mobile/harness/harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late CollabReplica replica;

  setUp(() {
    replica = CollabReplica(endpoint: 'wss://relay.example');
    replica.connecting();
  });

  test('welcome and chunks build an ordered deduplicated snapshot', () {
    replica.apply(_welcome(entryCount: 2, readOnly: false));
    expect(replica.snapshot.phase, ConnectionPhase.syncing);
    replica.apply({
      't': 'snapshot-chunk',
      'entries': [_userEntry('one', 'first'), _userEntry('one', 'duplicate')],
      'final': false,
    });
    replica.apply({
      't': 'snapshot-chunk',
      'entries': [_assistantEntry('two', 'second')],
      'final': true,
    });
    expect(replica.snapshot.phase, ConnectionPhase.live);
    expect(replica.snapshot.canSend, isTrue);
    expect(replica.snapshot.messages.map((message) => message.text), [
      'first',
      'second',
    ]);
  });

  test('omitted readOnly field is the host writable authorization', () {
    final welcome = _welcome(entryCount: 0)..remove('readOnly');
    replica.apply(welcome);
    expect(replica.snapshot.canSend, isTrue);
  });
  test('fresh welcome atomically discards old and partial history', () {
    replica.apply(_welcome(entryCount: 1));
    replica.apply({
      't': 'snapshot-chunk',
      'entries': [_userEntry('old', 'old')],
      'final': false,
    });
    replica.apply({..._welcome(entryCount: 1), 'header': _header('new')});
    replica.apply({
      't': 'snapshot-chunk',
      'entries': [_userEntry('new', 'new')],
      'final': true,
    });
    expect(replica.snapshot.sessionId, 'new');
    expect(replica.snapshot.messages.single.text, 'new');
  });

  test(
    'missed message start is synthesized and durable entry replaces ghost',
    () {
      replica.apply(_welcome(entryCount: 0));
      replica.apply({
        't': 'event',
        'event': {
          'type': 'message_update',
          'message': _assistantMessage('accumulated'),
        },
      });
      expect(replica.snapshot.messages.single.text, 'accumulated');
      expect(replica.snapshot.messages.single.isStreaming, isTrue);
      replica.apply({
        't': 'event',
        'event': {
          'type': 'message_end',
          'message': _assistantMessage('accumulated'),
        },
      });
      replica.apply({
        't': 'entry',
        'entry': _assistantEntry('a1', 'accumulated'),
      });
      expect(replica.snapshot.messages, hasLength(1));
      expect(replica.snapshot.messages.single.id, 'a1');
    },
  );

  test('authoritative idle repairs a stream whose end event was missed', () {
    replica.apply(_welcome(entryCount: 0));
    replica.apply({
      't': 'event',
      'event': {
        'type': 'message_update',
        'message': _assistantMessage('complete'),
      },
    });
    replica.apply({'t': 'state', 'state': _state(streaming: false)});
    expect(replica.snapshot.messages, isEmpty);
    replica.apply({'t': 'entry', 'entry': _assistantEntry('done', 'complete')});
    expect(replica.snapshot.messages.single.id, 'done');
  });
  test('tool updates render text and idle state repairs stale activity', () {
    replica.apply(_welcome(entryCount: 0));
    replica.apply({
      't': 'event',
      'event': {
        'type': 'tool_execution_update',
        'toolCallId': 'tool-1',
        'toolName': 'read',
        'args': {},
        'partialResult': 'half done',
      },
    });
    expect(replica.snapshot.messages.single.role, MessageRole.tool);
    expect(replica.snapshot.messages.single.text, 'half done');
    replica.apply({'t': 'state', 'state': _state(streaming: false)});
    expect(replica.snapshot.messages, isEmpty);
    expect(replica.snapshot.isStreaming, isFalse);
  });

  test('renders markdown, thinking, tool results, and prompt attribution', () {
    replica.apply(_welcome(entryCount: 0));
    replica.apply({
      't': 'entry',
      'entry': {
        'type': 'custom_message',
        'id': 'prompt',
        'parentId': null,
        'timestamp': '2026-01-01T00:00:00Z',
        'customType': 'collab-prompt',
        'content': '**hello**',
        'details': {'from': 'Alice'},
        'display': true,
      },
    });
    replica.apply({
      't': 'entry',
      'entry': {
        ..._assistantEntry('answer', 'visible'),
        'message': {
          ..._assistantMessage('visible'),
          'content': [
            {'type': 'thinking', 'thinking': 'private thought'},
            {'type': 'text', 'text': '**visible**'},
          ],
        },
      },
    });
    expect(replica.snapshot.messages.first.author, 'Alice');
    expect(replica.snapshot.messages.last.text, '**visible**');
    expect(replica.snapshot.messages.last.thinking, 'private thought');
  });

  test('queues explicit select/editor questions and never auto-answers', () {
    replica.apply(_welcome(entryCount: 0, readOnly: false));
    replica.apply({
      't': 'ui-request',
      'request': {
        'reqId': 7,
        'kind': 'select',
        'title': 'Choose',
        'options': [
          'A',
          {'label': 'B', 'description': 'second'},
        ],
        'checkedIndices': [1],
      },
    });
    replica.apply({
      't': 'ui-request',
      'request': {
        'reqId': 8,
        'kind': 'editor',
        'title': 'Edit',
        'prefill': 'draft',
      },
    });
    expect(replica.snapshot.questions.map((question) => question.id), [7, 8]);
    replica.apply({'t': 'ui-request-end', 'reqId': 7});
    expect(replica.snapshot.questions.single.id, 8);
  });

  test('header timestamp and initial state name override a generic header', () {
    replica.apply({
      ..._welcome(),
      'header': {..._header('session'), 'title': 'OMP chat'},
      'state': {..._state(streaming: false), 'sessionName': 'Named project'},
    });
    expect(replica.snapshot.title, 'Named project');
    expect(replica.snapshot.sessionStartedAt, DateTime.utc(2026, 1, 1));
  });

  test('header-only name survives welcome but live omitted name clears it', () {
    replica.apply(_welcome());
    expect(replica.snapshot.title, 'Test chat');
    replica.apply({'t': 'state', 'state': _state(streaming: false)});
    expect(replica.snapshot.title, isEmpty);
  });

  test(
    'state rename and clear update live title without replaying history',
    () {
      replica.apply({
        ..._welcome(),
        'state': {..._state(streaming: false), 'sessionName': 'First title'},
      });
      replica.apply({
        't': 'state',
        'state': {..._state(streaming: false), 'sessionName': 'Renamed'},
      });
      expect(replica.snapshot.title, 'Renamed');
      replica.apply({
        't': 'state',
        'state': {..._state(streaming: false), 'sessionName': null},
      });
      expect(replica.snapshot.title, isEmpty);
      replica.apply({
        't': 'state',
        'state': {..._state(streaming: false), 'sessionName': 'Again'},
      });
      replica.apply({'t': 'state', 'state': _state(streaming: false)});
      expect(replica.snapshot.title, isEmpty);
    },
  );

  // OMP v3 currently filters title_change from collab entry frames; these
  // records only exercise tolerant parsing if an older cache carries them.
  test('title_change history and optional live entries keep their order', () {
    replica.apply({
      ..._welcome(entryCount: 2),
      'header': {..._header('session')}..remove('title'),
    });
    replica.apply({
      't': 'snapshot-chunk',
      'entries': [
        {'type': 'title_change', 'id': 't1', 'title': 'Old'},
        {'type': 'title_change', 'id': 't2', 'title': ''},
      ],
      'final': true,
    });
    expect(replica.snapshot.title, isEmpty);
    replica.apply({
      't': 'entry',
      'entry': {'type': 'title_change', 'id': 't3', 'title': 'New'},
    });
    expect(replica.snapshot.title, 'New');
    replica.apply({
      't': 'entry',
      'entry': {'type': 'title_change', 'id': 't4', 'title': ''},
    });
    expect(replica.snapshot.title, isEmpty);
  });

  test('rejects incompatible protocol versions clearly', () {
    expect(
      () => replica.apply({..._welcome(), 'proto': 2}),
      throwsA(
        isA<HarnessException>().having(
          (error) => error.message,
          'message',
          contains('incompatible'),
        ),
      ),
    );
  });
  test('unknown variants are tolerated', () {
    replica.apply(_welcome(entryCount: 0));
    expect(
      () => replica.apply({'t': 'future-frame', 'value': 1}),
      returnsNormally,
    );
    expect(
      () => replica.apply({
        't': 'event',
        'event': {'type': 'future-event'},
      }),
      returnsNormally,
    );
  });
}

Map<String, Object?> _welcome({int entryCount = 0, bool readOnly = true}) => {
  't': 'welcome',
  'proto': 3,
  'header': _header('session'),
  'state': _state(streaming: false),
  'agents': const [],
  'entryCount': entryCount,
  'readOnly': readOnly,
};

Map<String, Object?> _header(String id) => {
  'type': 'session',
  'id': id,
  'title': 'Test chat',
  'timestamp': '2026-01-01T00:00:00Z',
  'cwd': '/private/host/path',
};

Map<String, Object?> _state({required bool streaming}) => {
  'isStreaming': streaming,
  'queuedMessageCount': 0,
  'cwd': '/private/host/path',
  'model': {
    'id': 'model-id',
    'name': 'Model',
    'provider': 'provider',
    'contextWindow': null,
  },
  'participants': const [],
};

Map<String, Object?> _userEntry(String id, String text) => {
  'type': 'message',
  'id': id,
  'parentId': null,
  'timestamp': '2026-01-01T00:00:00Z',
  'message': {'role': 'user', 'content': text, 'timestamp': 1767225600000},
};

Map<String, Object?> _assistantEntry(String id, String text) => {
  'type': 'message',
  'id': id,
  'parentId': null,
  'timestamp': '2026-01-01T00:00:00Z',
  'message': _assistantMessage(text),
};

Map<String, Object?> _assistantMessage(String text) => {
  'role': 'assistant',
  'content': [
    {'type': 'text', 'text': text},
  ],
  'model': 'model-id',
  'usage': {
    'input': 0,
    'output': 0,
    'cacheRead': 0,
    'cacheWrite': 0,
    'totalTokens': 0,
    'cost': {'total': 0},
  },
  'stopReason': 'stop',
  'timestamp': 1767225600000,
};
