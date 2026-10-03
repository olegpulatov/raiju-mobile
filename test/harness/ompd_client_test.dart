import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/harness/ompd_client.dart';
import 'package:raiju_mobile/harness/ompd_connection.dart';
import 'package:raiju_mobile/harness/voice_directive.dart';

import 'ompd_fixture.dart';

void main() {
  late OmpdFixture fixture;
  late OmpdClient client;
  setUp(() async {
    fixture = OmpdFixture();
    await fixture.open();
    client = OmpdClient(timeout: const Duration(seconds: 1));
  });
  tearDown(() async {
    await client.dispose();
    await fixture.close();
  });

  test(
    'legacy trust flag does not gate an authorized relay connection',
    () async {
      final connection = OmpdConnection(
        endpoint: fixture.endpoint,
        instance: 'phone',
        sessionId: fixture.sessionId,
        sessionFile: fixture.sessionFile,
        trustedNetwork: false,
      ).encode();
      await client.connect(connection);
      expect(client.snapshot.canSend, isTrue);
    },
  );

  test(
    'attach bootstrap loads history before live and remains raw v1',
    () async {
      fixture.split = true;
      fixture.messages = [message('user', 'old turn', 10)];
      final phases = <ConnectionPhase>[];
      final subscription = client.changes.listen(
        (snapshot) => phases.add(snapshot.phase),
      );
      await client.connect(fixture.encoded);
      expect(client.snapshot.phase, ConnectionPhase.live);
      expect(client.snapshot.canSend, isTrue);
      expect(client.snapshot.sessionId, fixture.sessionId);
      expect(client.snapshot.messages.single.text, 'old turn');
      expect(client.snapshot.rawEntries.single['type'], 'message');
      expect(
        phases,
        containsAllInOrder([
          ConnectionPhase.connecting,
          ConnectionPhase.syncing,
          ConnectionPhase.live,
        ]),
      );
      expect(
        fixture.requests
            .map((frame) => frame['method'] ?? frame['type'])
            .toList(),
        [
          'status',
          'attach',
          'set_event_filter',
          'get_state',
          'get_messages_page',
          'get_state',
          'status',
        ],
      );
      expect(
        fixture.requests.any((frame) => frame['type'] == 'negotiate_protocol'),
        isFalse,
      );
      await subscription.cancel();
    },
  );

  test(
    'canonical daemon file and raw RPC alias attach send and reconnect',
    () async {
      fixture.sessionFile = '/private/tmp/synthetic/session.jsonl';
      fixture.rpcSessionFile = '/tmp/synthetic/session.jsonl';
      fixture.messages = [message('user', 'saved history', 10)];
      final encoded = fixture.encoded;
      expect(client.savedConnection, isNull);
      await client.connect(encoded);
      final saved = client.savedConnection!;
      final binding = OmpdConnection.parse(saved);
      expect(binding.sessionFile, fixture.sessionFile);
      expect(binding.rpcSessionFile, fixture.rpcSessionFile);
      await client.sendPrompt('one alias prompt');
      await client.disconnect();
      await client.connect(encoded);
      expect(client.snapshot.canSend, isTrue);
      expect(client.snapshot.messages.single.text, 'saved history');
      expect(
        fixture.requests.where((request) => request['type'] == 'prompt').length,
        1,
      );
      expect(
        fixture.requests.where((request) => request['method'] == 'start'),
        isEmpty,
      );
      await client.dispose();
      client = OmpdClient(timeout: const Duration(seconds: 1));
      await client.connect(saved);
      expect(client.snapshot.messages.single.text, 'saved history');
    },
  );

  test(
    'arbitrary remote path aliases need no local platform knowledge',
    () async {
      fixture.sessionFile = '/srv/canonical/sessions/session.jsonl';
      fixture.rpcSessionFile = '/home/agent/session-link/session.jsonl';
      await client.connect(fixture.encoded);
      expect(client.snapshot.canSend, isTrue);
      await client.disconnect();
      await client.connect(fixture.encoded);
      expect(client.snapshot.sessionId, fixture.sessionId);
    },
  );

  test('unchanged Linux-style remote file preserves exact identity', () async {
    fixture.sessionFile = '/home/agent/.local/share/omp/session.jsonl';
    await client.connect(fixture.encoded);
    await client.disconnect();
    await client.connect(fixture.encoded);
    expect(client.snapshot.canSend, isTrue);
  });

  test(
    'raw RPC file switch remains rejected even with same session id',
    () async {
      fixture.sessionFile = '/private/tmp/synthetic/session.jsonl';
      fixture.rpcSessionFile = '/tmp/synthetic/session.jsonl';
      fixture.messages = [message('user', 'kept history', 10)];
      await client.connect(fixture.encoded);
      fixture.rpcSessionFile = '/tmp/synthetic/other.jsonl';
      await fixture.send(fixture.attachments.single, {
        'type': 'response',
        'command': 'get_state',
        'id': 'ompd:state:1:2',
        'success': true,
        'data': fixture.state,
      });
      await waitFor(() => client.snapshot.phase == ConnectionPhase.error);
      expect(client.snapshot.messages.single.text, 'kept history');
      expect(client.snapshot.canSend, isFalse);
    },
  );

  test(
    'same-id canonical file switch during attach keeps old history',
    () async {
      fixture.sessionFile = '/srv/canonical/original.jsonl';
      fixture.rpcSessionFile = '/home/agent/original-link.jsonl';
      fixture.messages = [message('user', 'kept original history', 10)];
      final encoded = fixture.encoded;
      await client.connect(encoded);
      await client.disconnect();
      fixture.onRpc = (socket, request, id) async {
        if (request['type'] == 'set_event_filter') {
          fixture.sessionFile = '/srv/canonical/replacement.jsonl';
          fixture.messages = [message('user', 'replacement history', 20)];
        }
        await fixture.rpc(socket, request, id);
      };
      await expectLater(
        client.connect(encoded),
        throwsA(isA<HarnessException>()),
      );
      expect(client.snapshot.phase, ConnectionPhase.error);
      expect(client.snapshot.messages.single.text, 'kept original history');
      expect(client.snapshot.canSend, isFalse);
    },
  );

  test(
    'same-id raw file switch reconnect rejects stale daemon metadata',
    () async {
      fixture.sessionFile = '/srv/canonical/original.jsonl';
      fixture.rpcSessionFile = '/home/agent/original-link.jsonl';
      fixture.messages = [message('user', 'kept original history', 10)];
      final encoded = fixture.encoded;
      await client.connect(encoded);
      await client.disconnect();
      // OMP changes file, but ompd's internal state poll has not caught up.
      // Both status calls would still report the original canonical identity.
      fixture.rpcSessionFile = '/home/agent/replacement-link.jsonl';
      fixture.messages = [message('user', 'replacement history', 20)];
      await expectLater(
        client.connect(encoded),
        throwsA(isA<HarnessException>()),
      );
      expect(client.snapshot.phase, ConnectionPhase.error);
      expect(client.snapshot.messages.single.text, 'kept original history');
      expect(client.snapshot.canSend, isFalse);
      expect(fixture.sessionFile, '/srv/canonical/original.jsonl');
    },
  );

  test(
    'exported raw binding rejects stale-cache file switch after recreation',
    () async {
      fixture.sessionFile = '/srv/canonical/original.jsonl';
      fixture.rpcSessionFile = '/home/agent/original-link.jsonl';
      await client.connect(fixture.encoded);
      final saved = client.savedConnection!;
      await client.dispose();
      client = OmpdClient(timeout: const Duration(seconds: 1));
      fixture.rpcSessionFile = '/home/agent/replacement-link.jsonl';
      fixture.messages = [message('user', 'replacement history', 20)];
      await expectLater(
        client.connect(saved),
        throwsA(isA<HarnessException>()),
      );
      expect(client.snapshot.phase, ConnectionPhase.error);
      expect(client.snapshot.messages, isEmpty);
      expect(client.snapshot.canSend, isFalse);
      expect(client.savedConnection, isNull);
      expect(fixture.sessionFile, '/srv/canonical/original.jsonl');
    },
  );

  test(
    'coalesced history race keeps newest text and one row per event identity',
    () async {
      final partial = message('assistant', 'par', 20);
      final baseline = message('assistant', 'partial', 20);
      final complete = message('assistant', 'completed', 20);
      fixture.onRpc = (socket, request, id) async {
        if (request['type'] == 'get_messages_page') {
          await fixture.coalesce(socket, [
            {'type': 'message_start', 'messageId': 'm1', 'message': partial},
            fixture.response(
              request,
              id,
              data: {
                'messages': [baseline],
                'totalMessages': 1,
              },
            ),
            {'type': 'message_update', 'messageId': 'm1', 'message': complete},
            {'type': 'message_end', 'messageId': 'm1', 'message': complete},
            {'type': 'session_settled'},
          ]);
        } else {
          await fixture.rpc(socket, request, id);
        }
      };
      await client.connect(fixture.encoded);
      expect(client.snapshot.messages.single.text, 'completed');
      expect(client.snapshot.messages.single.isStreaming, isFalse);
      expect(client.snapshot.agentEvents.map((event) => event.type), [
        'message_start',
        'message_update',
        'message_end',
        'session_settled',
      ]);
    },
  );

  test(
    'old partial events do not replace the newer complete baseline',
    () async {
      fixture.onRpc = (socket, request, id) async {
        if (request['type'] == 'get_messages_page') {
          await fixture.coalesce(socket, [
            {
              'type': 'message_update',
              'messageId': 'm1',
              'message': message('assistant', 'old partial', 20),
            },
            fixture.response(
              request,
              id,
              data: {
                'messages': [message('assistant', 'completed', 20)],
                'totalMessages': 1,
              },
            ),
          ]);
        } else {
          await fixture.rpc(socket, request, id);
        }
      };
      await client.connect(fixture.encoded);
      expect(client.snapshot.messages.single.text, 'completed');
      expect(client.snapshot.isStreaming, isFalse);
    },
  );

  test(
    'idle paged history exceeds one physical frame without truncation',
    () async {
      final large = List<String>.filled(300000, 'x').join();
      fixture.onRpc = (socket, request, id) async {
        if (request['type'] == 'get_messages_page') {
          final page = request['cursor'] == null
              ? 0
              : int.parse(request['cursor'] as String);
          final data = <String, Object?>{
            'messages': [
              message('user', large, page * 2),
              message('assistant', large, page * 2 + 1),
            ],
            'totalMessages': 8,
            if (page < 3) 'nextCursor': '${page + 1}',
          };
          await fixture.send(socket, fixture.response(request, id, data: data));
        } else {
          await fixture.rpc(socket, request, id);
        }
      };
      await client.connect(fixture.encoded);
      expect(client.snapshot.messages.length, 8);
      expect(
        client.snapshot.messages.every(
          (row) => row.text.length == large.length,
        ),
        isTrue,
      );
      expect(
        fixture.requests
            .where((frame) => frame['type'] == 'get_messages_page')
            .length,
        4,
      );
    },
  );

  test(
    'unsupported paging discards pages and falls back to get_messages',
    () async {
      fixture.paged = false;
      fixture.messages = [message('user', 'fallback', 1)];
      await client.connect(fixture.encoded);
      expect(client.snapshot.messages.single.text, 'fallback');
      expect(
        fixture.requests.any((frame) => frame['type'] == 'get_messages'),
        isTrue,
      );
    },
  );

  test(
    'prompt sends once with admission and streamed message replacement',
    () async {
      await client.connect(fixture.encoded);
      await client.sendPrompt('one prompt');
      final socket = fixture.attachments.single;
      await fixture.coalesce(socket, [
        {'type': 'agent_start'},
        {
          'type': 'message_start',
          'messageId': 'm2',
          'message': message('assistant', 'par', 30),
        },
        {
          'type': 'message_update',
          'messageId': 'm2',
          'message': message('assistant', 'partial', 30),
        },
      ]);
      await waitFor(
        () =>
            client.snapshot.messages.isNotEmpty &&
            client.snapshot.messages.single.text == 'partial',
      );
      expect(client.snapshot.isStreaming, isTrue);
      await fixture.coalesce(socket, [
        {
          'type': 'message_end',
          'messageId': 'm2',
          'message': message('assistant', 'final', 30),
        },
        {
          'type': 'prompt_result',
          'id': 'c1:r5',
          'status': 'completed',
          'agentInvoked': true,
          'sessionSettled': true,
        },
        {'type': 'session_settled'},
      ]);
      await waitFor(() => !client.snapshot.isStreaming);
      expect(client.snapshot.messages.single.text, 'final');
      expect(
        fixture.requests.where((request) => request['type'] == 'prompt').length,
        1,
      );
      expect(
        fixture.requests
            .where((request) => request['type'] == 'prompt')
            .single['message'],
        'one prompt',
      );
    },
  );

  test(
    'takeover stays viewing and never reattaches or writes implicitly',
    () async {
      await client.connect(fixture.encoded);
      final before = fixture.requests.length;
      await fixture.send(fixture.attachments.single, {
        'ompd': {
          'event': 'controller_changed',
          'controller': 'c2',
          'previous_controller': 'c1',
        },
      });
      await waitFor(() => client.snapshot.readOnly);
      expect(client.snapshot.phase, ConnectionPhase.live);
      await expectLater(
        client.sendPrompt('blocked'),
        throwsA(isA<HarnessException>()),
      );
      await expectLater(client.abort(), throwsA(isA<HarnessException>()));
      expect(fixture.requests.length, before);
      await fixture.send(fixture.attachments.single, {
        'type': 'message_end',
        'messageId': 'viewer-message',
        'message': message('assistant', 'still viewing', 40),
      });
      await waitFor(() => client.snapshot.messages.isNotEmpty);
      expect(client.snapshot.messages.single.text, 'still viewing');
    },
  );

  test(
    'explicit abort only, disconnect never stops host and reconnect never replays',
    () async {
      fixture.messages = [message('user', 'saved', 1)];
      final encoded = fixture.encoded;
      await client.connect(encoded);
      final rowId = client.snapshot.messages.single.id;
      await client.sendPrompt('one prompt');
      await client.abort();
      await client.disconnect();
      expect(client.snapshot.phase, ConnectionPhase.disconnected);
      expect(client.snapshot.messages.single.text, 'saved');
      await client.connect(encoded);
      expect(client.snapshot.messages.single.id, rowId);
      expect(
        fixture.requests.where((request) => request['type'] == 'prompt').length,
        1,
      );
      expect(
        fixture.requests.where((request) => request['type'] == 'abort').length,
        1,
      );
      expect(
        fixture.requests
            .where((request) => request['method'] == 'attach')
            .length,
        2,
      );
      expect(
        fixture.requests.any(
          (request) =>
              ['start', 'stop', 'stop-all', 'send'].contains(request['method']),
        ),
        isFalse,
      );
    },
  );

  test(
    'changed session is rejected on reconnect and cached transcript stays',
    () async {
      fixture.messages = [message('user', 'saved', 1)];
      final encoded = fixture.encoded;
      await client.connect(encoded);
      await client.disconnect();
      fixture.sessionId = 'different-session';
      await expectLater(
        client.connect(encoded),
        throwsA(isA<HarnessException>()),
      );
      expect(client.snapshot.sessionId, 'fixture-session');
      expect(client.snapshot.messages.single.text, 'saved');
      expect(client.snapshot.canSend, isFalse);
      expect(
        fixture.requests
            .where((request) => request['method'] == 'attach')
            .length,
        1,
      );
    },
  );

  test(
    'periodic daemon state detects host session switch without raw error leaks',
    () async {
      await client.connect(fixture.encoded);
      final state = Map<String, Object?>.from(fixture.state)
        ..['sessionId'] = 'different-session';
      await fixture.send(fixture.attachments.single, {
        'type': 'response',
        'command': 'get_state',
        'success': true,
        'id': 'ompd:state:1:2',
        'data': state,
      });
      await waitFor(() => client.snapshot.phase == ConnectionPhase.error);
      expect(client.snapshot.sessionId, 'fixture-session');
      expect(client.snapshot.canSend, isFalse);
    },
  );

  test(
    'permission callbacks keep exact OMP id and require explicit answer',
    () async {
      await client.connect(fixture.encoded);
      await fixture.send(fixture.attachments.single, {
        'type': 'extension_ui_request',
        'id': 'ui_42',
        'method': 'confirm',
        'title': 'Allow operation?',
        'message': 'Synthetic operation',
      });
      await waitFor(() => client.snapshot.questions.isNotEmpty);
      expect(
        fixture.requests.any(
          (request) => request['type'] == 'extension_ui_response',
        ),
        isFalse,
      );
      await client.respond(client.snapshot.questions.single.id, 'No');
      await waitFor(
        () => fixture.requests.any(
          (request) => request['type'] == 'extension_ui_response',
        ),
      );
      expect(fixture.requests.last, {
        'type': 'extension_ui_response',
        'id': 'ui_42',
        'confirmed': false,
      });
      expect(client.snapshot.questions, isEmpty);
      await fixture.send(fixture.attachments.single, {
        'type': 'extension_ui_request',
        'id': 'ask_nested',
        'method': 'ask',
        'questions': [],
      });
      await waitFor(() => client.snapshot.error != null);
      expect(client.snapshot.questions, isEmpty);
      expect(
        fixture.requests
            .where((request) => request['type'] == 'extension_ui_response')
            .length,
        1,
      );
    },
  );

  test('server errors are sanitized and never imply ready history', () async {
    fixture.rejectRpc = true;
    await expectLater(
      client.connect(fixture.encoded),
      throwsA(isA<HarnessException>()),
    );
    expect(client.snapshot.phase, ConnectionPhase.error);
    expect(client.snapshot.canSend, isFalse);
    expect(client.snapshot.error, isNot(contains('PRIVATE-ERROR-TOKEN')));
  });

  test(
    'RPC timeout and close fail promptly without automatic reconnect',
    () async {
      await client.dispose();
      client = OmpdClient(timeout: const Duration(milliseconds: 100));
      fixture.ignoreRpc = true;
      await expectLater(
        client.connect(fixture.encoded),
        throwsA(isA<HarnessException>()),
      );
      expect(client.snapshot.phase, ConnectionPhase.error);
      fixture.ignoreRpc = false;
      fixture.closeOnRpc = true;
      await expectLater(
        client.connect(fixture.encoded),
        throwsA(isA<HarnessException>()),
      );
      expect(client.snapshot.phase, ConnectionPhase.error);
      expect(
        fixture.requests
            .where((request) => request['method'] == 'attach')
            .length,
        2,
      );
    },
  );

  test('foreign prefixed responses cannot satisfy our request', () async {
    fixture.onRpc = (socket, request, id) async {
      if (request['type'] == 'get_state') {
        await fixture.send(
          socket,
          fixture.response(request, 'c999', data: fixture.state),
        );
      } else {
        await fixture.rpc(socket, request, id);
      }
    };
    await client.dispose();
    client = OmpdClient(timeout: const Duration(milliseconds: 100));
    await expectLater(
      client.connect(fixture.encoded),
      throwsA(isA<HarnessException>()),
    );
    expect(client.snapshot.phase, ConnectionPhase.error);
  });

  test('disconnect fences stale in-flight connect generations', () async {
    final gate = Completer<void>();
    fixture.onControl = (socket, request) async {
      if (request['method'] == 'status') {
        await gate.future;
        await fixture.send(socket, {
          'result': [fixture.instance],
        });
      }
    };
    final pending = client.connect(fixture.encoded);
    final assertion = expectLater(pending, throwsA(isA<HarnessException>()));
    await waitFor(() => fixture.requests.isNotEmpty);
    await client.disconnect();
    gate.complete();
    await assertion;
    expect(client.snapshot.phase, ConnectionPhase.disconnected);
    expect(
      fixture.requests.any((request) => request['method'] == 'attach'),
      isFalse,
    );
  });

  test(
    'physical over-limit history fails rather than truncates or becomes live',
    () async {
      fixture.streaming = true;
      fixture.onRpc = (socket, request, id) async {
        if (request['type'] == 'get_messages') {
          final huge = List<String>.filled(1024 * 1024, 'x').join();
          socket.add(
            utf8.encode(
              '${jsonEncode(fixture.response(request, id, data: {
                'messages': [message('user', huge, 1)],
              }))}\n',
            ),
          );
          await socket.flush();
        } else {
          await fixture.rpc(socket, request, id);
        }
      };
      await expectLater(
        client.connect(fixture.encoded),
        throwsA(isA<HarnessException>()),
      );
      expect(client.snapshot.phase, ConnectionPhase.error);
      expect(client.snapshot.canSend, isFalse);
    },
  );

  test(
    'takeover during bootstrap exposes typed loss without claiming live history',
    () async {
      fixture.onRpc = (socket, request, id) async {
        if (request['type'] == 'get_messages_page') {
          await fixture.send(socket, {
            'ompd': {
              'event': 'controller_changed',
              'controller': 'c2',
              'previous_controller': id,
            },
          });
        } else {
          await fixture.rpc(socket, request, id);
        }
      };
      await expectLater(
        client.connect(fixture.encoded),
        throwsA(isA<HarnessException>()),
      );
      expect(client.controlLost, isTrue);
      expect(client.snapshot.phase, ConnectionPhase.error);
      expect(client.snapshot.canSend, isFalse);
      await client.disconnect();
      expect(client.controlLost, isTrue);
    },
  );

  test(
    'first live update after midstream attachment binds the history tail',
    () async {
      fixture.streaming = true;
      fixture.messages = [message('assistant', 'partial', 21)];
      await client.connect(fixture.encoded);
      final rowId = client.snapshot.messages.single.id;
      await fixture.send(fixture.attachments.single, {
        'type': 'message_update',
        'messageId': 'active',
        'message': message('assistant', 'more text', 21),
      });
      await waitFor(() => client.snapshot.messages.last.text == 'more text');
      expect(client.snapshot.messages.length, 1);
      expect(client.snapshot.messages.single.id, rowId);
      await client.sendPrompt('steering');
      final prompt = fixture.requests
          .where((request) => request['type'] == 'prompt')
          .single;
      expect(prompt['streamingBehavior'], 'steer');
    },
  );

  test(
    'ambiguous history event timestamps fail safely instead of merging turns',
    () async {
      fixture.onRpc = (socket, request, id) async {
        if (request['type'] == 'get_messages_page') {
          await fixture.coalesce(socket, [
            {
              'type': 'message_update',
              'messageId': 'ambiguous',
              'message': message('assistant', 'partial', 21),
            },
            fixture.response(
              request,
              id,
              data: {
                'messages': [
                  message('assistant', 'first', 21),
                  message('assistant', 'second', 21),
                ],
                'totalMessages': 2,
              },
            ),
          ]);
        } else {
          await fixture.rpc(socket, request, id);
        }
      };
      await expectLater(
        client.connect(fixture.encoded),
        throwsA(isA<HarnessException>()),
      );
      expect(client.snapshot.phase, ConnectionPhase.error);
      expect(client.snapshot.canSend, isFalse);
    },
  );

  test('lost prompt admission is not retried on explicit reconnect', () async {
    final encoded = fixture.encoded;
    await client.connect(encoded);
    fixture.onRpc = (socket, request, id) async {
      if (request['type'] == 'prompt') {
        socket.destroy();
      } else {
        await fixture.rpc(socket, request, id);
      }
    };
    await expectLater(
      client.sendPrompt('uncertain'),
      throwsA(isA<HarnessException>()),
    );
    fixture.onRpc = null;
    await client.connect(encoded);
    expect(
      fixture.requests.where((request) => request['type'] == 'prompt').length,
      1,
    );
    expect(client.snapshot.phase, ConnectionPhase.live);
  });

  test(
    'live message presentation id survives client recreation from host history',
    () async {
      await client.connect(fixture.encoded);
      final completed = message('assistant', 'saved response', 55);
      await fixture.send(fixture.attachments.single, {
        'type': 'message_end',
        'messageId': 'runtime-only-id',
        'message': completed,
      });
      await waitFor(() => client.snapshot.messages.isNotEmpty);
      final rowId = client.snapshot.messages.single.id;
      await client.dispose();
      fixture.messages = [completed];
      client = OmpdClient();
      await client.connect(fixture.encoded);
      expect(client.snapshot.messages.single.id, rowId);
    },
  );

  test(
    'custom visibility and actual summary roles map into truthful raw entries',
    () async {
      fixture.messages = [
        {
          'role': 'custom',
          'customType': 'internal',
          'content': 'hidden instructions',
          'display': false,
          'timestamp': 1,
        },
        {
          'role': 'compactionSummary',
          'summary': 'compact context',
          'timestamp': 2,
        },
        {
          'role': 'custom',
          'customType': 'collab-prompt',
          'content': 'collab user',
          'display': true,
          'timestamp': 3,
        },
      ];
      await client.connect(fixture.encoded);
      expect(client.snapshot.messages.map((row) => row.text), [
        'compact context',
        'collab user',
      ]);
      expect(
        client.snapshot.messages.last.origin,
        ChatMessageOrigin.collabUser,
      );
      expect(client.snapshot.rawEntries.map((entry) => entry['type']), [
        'custom_message',
        'compaction',
        'custom_message',
      ]);
      expect(client.snapshot.rawEntries.first['display'], isFalse);
    },
  );

  test(
    'aggregate paged history is capped without exposing a partial live transcript',
    () async {
      await client.dispose();
      client = OmpdClient(timeout: const Duration(seconds: 5));
      final large = List<String>.filled(900000, 'x').join();
      fixture.onRpc = (socket, request, id) async {
        if (request['type'] == 'get_messages_page') {
          final page = request['cursor'] == null
              ? 0
              : int.parse(request['cursor'] as String);
          await fixture.send(
            socket,
            fixture.response(
              request,
              id,
              data: {
                'messages': [message('user', large, page)],
                'totalMessages': 10,
                if (page < 9) 'nextCursor': '${page + 1}',
              },
            ),
          );
        } else {
          await fixture.rpc(socket, request, id);
        }
      };
      await expectLater(
        client.connect(fixture.encoded),
        throwsA(isA<HarnessException>()),
      );
      expect(client.snapshot.phase, ConnectionPhase.error);
      expect(client.snapshot.canSend, isFalse);
      expect(client.snapshot.messages, isEmpty);
    },
  );

  test('saved transcript file is required before networking', () async {
    final encoded = OmpdConnection(
      endpoint: fixture.endpoint,
      instance: 'phone',
      sessionId: fixture.sessionId,
      trustedNetwork: true,
    ).encode();
    await expectLater(
      client.connect(encoded),
      throwsA(isA<HarnessException>()),
    );
    expect(fixture.requests, isEmpty);
  });

  test(
    'same provider session id with another transcript file is rejected',
    () async {
      fixture.messages = [message('user', 'original history', 1)];
      final encoded = fixture.encoded;
      await client.connect(encoded);
      await client.disconnect();
      fixture.sessionFile = '/synthetic/other-session.jsonl';
      await expectLater(
        client.connect(encoded),
        throwsA(isA<HarnessException>()),
      );
      expect(client.snapshot.messages.single.text, 'original history');
      expect(
        fixture.requests
            .where((request) => request['method'] == 'attach')
            .length,
        1,
      );
    },
  );

  test(
    'role-only pre-filter deltas never create an empty duplicate row',
    () async {
      fixture.messages = [message('assistant', 'complete response', 20)];
      fixture.onRpc = (socket, request, id) async {
        if (request['type'] == 'set_event_filter') {
          await fixture.coalesce(socket, [
            {
              'type': 'message_update',
              'messageId': 'm1',
              'message': {'role': 'assistant'},
            },
            fixture.response(request, id),
            {
              'type': 'message_end',
              'messageId': 'm1',
              'message': fixture.messages.single,
            },
          ]);
        } else {
          await fixture.rpc(socket, request, id);
        }
      };
      await client.connect(fixture.encoded);
      expect(client.snapshot.messages.single.text, 'complete response');
    },
  );

  test('message replay cannot override a newer idle final state', () async {
    fixture.onRpc = (socket, request, id) async {
      if (request['type'] == 'get_messages_page') {
        await fixture.coalesce(socket, [
          fixture.response(
            request,
            id,
            data: {'messages': [], 'totalMessages': 0},
          ),
          {
            'type': 'message_start',
            'messageId': 'm1',
            'message': message('assistant', 'partial', 20),
          },
          {
            'type': 'message_update',
            'messageId': 'm1',
            'message': message('assistant', 'updated', 20),
          },
          {
            'type': 'message_end',
            'messageId': 'm1',
            'message': message('assistant', 'complete', 20),
          },
          {'type': 'agent_end', 'messages': []},
          {'type': 'session_settled'},
        ]);
      } else {
        await fixture.rpc(socket, request, id);
      }
    };
    await client.connect(fixture.encoded);
    expect(client.snapshot.messages.single.text, 'complete');
    expect(client.snapshot.messages.single.isStreaming, isFalse);
    expect(client.snapshot.isStreaming, isFalse);
    expect(client.snapshot.activity, isEmpty);
  });

  test(
    'successful compaction refreshes context and actual boundary, failures do not',
    () async {
      fixture.messages = [
        message(
          'user',
          VoiceDirective.decorate('request', 'fixture instructions'),
          1,
        ),
      ];
      await client.connect(fixture.encoded);
      expect(VoiceDirective.isPresent(client.snapshot.rawEntries), isTrue);
      final count = fixture.requests.length;
      final socket = fixture.attachments.single;
      await fixture.coalesce(socket, [
        {
          'type': 'auto_compaction_start',
          'reason': 'threshold',
          'action': 'context-full',
        },
        {
          'type': 'auto_compaction_end',
          'action': 'context-full',
          'aborted': true,
          'willRetry': false,
          'errorMessage': 'PRIVATE-ERROR-TOKEN',
        },
      ]);
      await waitFor(
        () =>
            client.snapshot.agentEvents.isNotEmpty &&
            client.snapshot.agentEvents.last.type == 'auto_compaction_end',
      );
      expect(fixture.requests.length, count);
      expect(VoiceDirective.isPresent(client.snapshot.rawEntries), isTrue);
      expect(
        jsonEncode(client.snapshot.agentEvents.last.event),
        isNot(contains('PRIVATE-ERROR-TOKEN')),
      );
      fixture.messages = [message('user', 'retained context', 2)];
      await fixture.send(socket, {
        'type': 'auto_compaction_end',
        'action': 'context-full',
        'aborted': false,
        'willRetry': false,
        'result': {'summary': 'compacted fixture'},
      });
      await waitFor(
        () =>
            client.snapshot.phase == ConnectionPhase.live &&
            client.snapshot.messages.length == 1 &&
            client.snapshot.messages.single.text == 'retained context',
      );
      expect(VoiceDirective.isPresent(client.snapshot.rawEntries), isFalse);
      expect(client.snapshot.rawEntries.first['type'], 'compaction');
      expect(
        fixture.requests
            .where((request) => request['method'] == 'attach')
            .length,
        1,
      );
      expect(
        fixture.requests
            .where((request) => request['type'] == 'get_state')
            .length,
        4,
      );
    },
  );
}

Map<String, Object?> message(String role, String text, int timestamp) => {
  'role': role,
  'timestamp': timestamp,
  'content': [
    {'type': 'text', 'text': text},
  ],
};
