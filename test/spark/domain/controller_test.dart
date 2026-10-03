import 'dart:async';

import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/raiju/timeline_projection.dart';
import 'package:raiju_mobile/harness/voice_directive.dart';
import 'package:raiju_mobile/spark/spark.dart';
import 'package:raiju_mobile/spark/context.dart';
import 'package:raiju_mobile/storage/voice_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'start requires the intended writable chat; stop leaves remote work running',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await expectLater(controller.start(), throwsStateError);
      await controller.start(chatId: 'chat');
      expect(controller.snapshot.boundChatId, 'chat');
      expect(bridge.armed, isTrue);
      expect(bridge.sends, 0);
      session.add({'type': 'connected'});
      await _tick();
      await controller.stop();
      session.add({'type': 'connected'});
      await _tick();
      expect(controller.snapshot.phase, SparkPhase.idle);
      expect(controller.snapshot.boundChatId, isNull);
      expect(session.stops, 1);
      expect(bridge.armed, isFalse);
    },
  );

  test('saves Spark filler but selects only incremental human context', () async {
    final bridge = _Bridge();
    final session = _Session();
    final controller = _controller(session, bridge);
    await controller.start(chatId: 'chat');
    session.add({'type': 'connected'});
    session.add({
      'type': 'transcript',
      'role': 'assistant',
      'id': 'a0',
      'text': 'Welcome',
      'final': true,
    });
    session.add({
      'type': 'transcript',
      'role': 'user',
      'id': 'u1',
      'text': 'Find the format',
      'final': true,
    });
    session.add({
      'type': 'transcript',
      'role': 'assistant',
      'id': 'a1',
      'text': 'Which format?',
      'final': true,
    });
    session.add({
      'type': 'transcript',
      'role': 'user',
      'id': 'u2',
      'text': 'Markdown',
      'final': true,
    });
    session.add({
      'type': 'transcript',
      'role': 'assistant',
      'id': 'a2',
      'text': 'I will check',
      'final': true,
    });
    await _tick();
    expect(bridge.turns.map((turn) => turn.text), [
      'Welcome',
      'Find the format',
      'Which format?',
      'Markdown',
      'I will check',
    ]);
    session.add({'type': 'delegation', 'id': 'd1', 'text': ' Markdown '});
    await _tick();
    expect(
      bridge.sentBodies.single,
      'User: Find the format\nVoice Assistant Spark: Which format?\nUser: Markdown',
    );
    expect(
      bridge.turns
          .where((turn) => turn.routingPurpose == VoiceTurnPurpose.request)
          .single
          .text,
      '',
    );
    expect(
      bridge.turns
          .where(
            (turn) =>
                turn.routingPurpose == VoiceTurnPurpose.dialogue &&
                turn.origin == VoiceTurnOrigin.spark,
          )
          .map((turn) => turn.delivery),
      [VoiceDelivery.pending, VoiceDelivery.uncertain, VoiceDelivery.pending],
    );
    session.add({'type': 'delegation', 'id': 'd1', 'text': ''});
    await _tick();
    expect(bridge.sends, 1);
    await controller.stop();
  });

  test(
    'omitted Spark ack stays local and ordered after confirmed voice user',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'spoken',
        'text': 'Inspect model',
        'final': true,
      });
      session.add({
        'type': 'transcript',
        'role': 'assistant',
        'id': 'ack',
        'text': 'I will look',
        'final': true,
      });
      await _tick();
      session.add({
        'type': 'delegation',
        'id': 'divergent',
        'text': 'Inspect model syntax',
      });
      await _tick();
      final body = bridge.sentBodies.single;
      expect(body, 'User: Inspect model\nInspect model syntax');
      bridge.addEntry('echo', body);
      bridge.emitEvents([
        {
          'type': 'message_start',
          'message': {
            'role': 'custom',
            'customType': 'collab-prompt',
            'content': body,
          },
        },
      ]);
      await _tick();
      final user = bridge.turns
          .where((turn) => turn.origin == VoiceTurnOrigin.user)
          .single;
      final ack = bridge.turns
          .where((turn) => turn.origin == VoiceTurnOrigin.spark)
          .single;
      expect(user.delivery, VoiceDelivery.delivered);
      expect(user.hostEntryId, 'echo');
      expect(ack.delivery, VoiceDelivery.pending);
      expect(ack.hostEntryId, isNull);
      final projected = projectTimelineMessages([
        ChatMessage(
          id: 'echo',
          role: MessageRole.user,
          text: body,
          source: {'customType': 'collab-prompt', 'content': body},
        ),
        const ChatMessage(
          id: 'answer',
          role: MessageRole.assistant,
          text: 'Inspection done',
        ),
      ], voiceTurns: bridge.turns);
      expect(projected.map((item) => item.content), [
        'Inspect model',
        'I will look',
        'Inspect model syntax',
        'Inspection done',
      ]);
      await controller.stop();
    },
  );
  test(
    'local send is not delivery; only matching consumed collab event and echo deliver',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({'type': 'connected'});
      await _tick();
      await controller.sendText('voice words');
      session.add({'type': 'delegation', 'id': 'd2', 'text': 'Please inspect'});
      await _tick();
      expect(
        bridge.turns
            .where((turn) => turn.routingPurpose != VoiceTurnPurpose.request)
            .single
            .delivery,
        VoiceDelivery.uncertain,
      );
      bridge.emitEvents([
        {'type': 'agent_start'},
        {
          'type': 'message_start',
          'message': {'role': 'user', 'content': bridge.sentBodies.single},
        },
      ]);
      await _tick();
      expect(
        bridge.turns
            .where((turn) => turn.routingPurpose != VoiceTurnPurpose.request)
            .single
            .delivery,
        VoiceDelivery.uncertain,
      );
      bridge.addEntry('echo', bridge.sentBodies.single);
      bridge.emitEvents([
        {
          'type': 'message_start',
          'message': {
            'role': 'custom',
            'customType': 'collab-prompt',
            'content': bridge.sentBodies.single,
          },
        },
      ]);
      await _tick();
      expect(
        bridge.turns
            .where((turn) => turn.routingPurpose != VoiceTurnPurpose.request)
            .single
            .delivery,
        VoiceDelivery.delivered,
      );
      expect(
        bridge.turns
            .where((turn) => turn.routingPurpose != VoiceTurnPurpose.request)
            .single
            .hostEntryId,
        'echo',
      );
    },
  );

  test(
    'RPC echoes deliver two delegations without duplicate final speech',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({'type': 'connected'});
      await _tick();
      await controller.sendText('first words');
      final actualFirst = VoiceDirective.decorate(
        'User: first words',
        'synthetic two-model instructions',
      );
      bridge.nextResult = SparkChatSendResult(
        SparkSendOutcome.uncertain,
        sentText: actualFirst,
      );
      session.add({'type': 'delegation', 'id': 'rpc-first', 'text': ''});
      await _tick();
      final first = bridge.sentBodies.single;
      session.add({
        'type': 'delegation',
        'id': 'rpc-second',
        'text': 'second task',
      });
      await _tick();
      expect(bridge.sends, 1);
      bridge.addRpcEntry('rpc-first-echo', actualFirst);
      bridge.emitEvents([
        {'type': 'message_start', 'message': _rpcUser(actualFirst)},
        _rpcTerminal(actualFirst, 'first answer'),
      ]);
      await _tick();
      expect(bridge.sentBodies, [first, 'second task']);
      expect(
        bridge.turns
            .where((turn) => turn.routingRequestId == 'rpc-first')
            .every((turn) => turn.delivery == VoiceDelivery.delivered),
        isTrue,
      );
      final second = bridge.sentBodies.last;
      bridge.addRpcEntry('rpc-second-echo', second);
      bridge.emitEvents([
        {'type': 'message_end', 'message': _rpcUser(second)},
        _rpcTerminal(second, 'second answer'),
      ]);
      await _tick();
      expect(
        bridge.turns.every((turn) => turn.delivery == VoiceDelivery.delivered),
        isTrue,
      );
      expect(session.delegationIds, [null, 'rpc-first', 'rpc-second']);
      expect(session.sent, [
        'first words',
        '"Agent Final Message":\n\nfirst answer',
        '"Agent Final Message":\n\nsecond answer',
      ]);
      await controller.stop();
    },
  );

  test(
    'RPC delivery survives controller recreation and cached echo collapse',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({
        'type': 'delegation',
        'id': 'rpc-saved',
        'text': 'saved task',
      });
      await _tick();
      bridge.addRpcEntry('saved-echo', 'saved task');
      bridge.emitEvents([_rpcTerminal('saved task', 'saved answer')]);
      await _tick();
      await controller.stop();
      final restored = _Bridge()
        ..turns.addAll(
          bridge.turns.map((turn) => VoiceTurn.fromJson(turn.toJson())),
        )
        ..entries.addAll(bridge.entries)
        ..events.addAll(bridge.events);
      expect(restored.turns.single.delivery, VoiceDelivery.delivered);
      expect(restored.turns.single.hostEntryId, 'saved-echo');
      for (final source in [_rpcUser('saved task'), null]) {
        final messages = [
          ChatMessage(
            id: 'saved-echo',
            role: MessageRole.user,
            text: 'saved task',
            prose: 'saved task',
            source: source,
            origin: ChatMessageOrigin.remoteUser,
          ),
        ];
        expect(
          projectTimelineMessages(
            messages,
            voiceTurns: restored.turns,
          ).map((item) => item.content),
          ['saved task'],
        );
        expect(
          sparkConversationContext(
            messages,
            restored.turns,
            characterBudget: 1000,
          ),
          'User request to main: saved task',
        );
      }
      final restartedSession = _Session();
      final restarted = _controller(restartedSession, restored);
      await restarted.start(chatId: 'chat');
      restored.emit();
      await _tick();
      expect(restartedSession.sent, isEmpty);
      restartedSession.add({
        'type': 'delegation',
        'id': 'rpc-next',
        'text': 'next task',
      });
      await _tick();
      expect(restored.sentBodies, ['next task']);
      restored.addRpcEntry('next-echo', 'next task');
      restored.emitEvents([_rpcTerminal('next task', 'next answer')]);
      await _tick();
      expect(restartedSession.delegationIds, ['rpc-next']);
      await restarted.stop();
    },
  );

  test(
    'RPC delivery requires new unique exact echo, not unrelated input',
    () async {
      final bridge = _Bridge()..addRpcEntry('prior-echo', 'same task');
      bridge.emitEvents([_rpcTerminal('same task', 'old answer')]);
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({
        'type': 'delegation',
        'id': 'rpc-exact',
        'text': 'same task',
      });
      await _tick();
      bridge.addRpcEntry('unrelated-echo', 'same task again');
      bridge.emitEvents([
        {'type': 'message_start', 'message': _rpcUser('same task again')},
      ]);
      await _tick();
      expect(bridge.turns.single.delivery, VoiceDelivery.uncertain);
      bridge.addRpcEntry('new-echo', 'same task');
      await _tick();
      expect(bridge.turns.single.delivery, VoiceDelivery.uncertain);
      bridge.emitEvents([_rpcTerminal('same task', 'new answer')]);
      await _tick();
      expect(bridge.turns.single.delivery, VoiceDelivery.delivered);
      expect(bridge.turns.single.hostEntryId, 'new-echo');
      expect(session.delegationIds, ['rpc-exact']);
      await controller.stop();
    },
  );

  test(
    'RPC repeated exact echoes remain uncertain without unique provenance',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({
        'type': 'delegation',
        'id': 'rpc-ambiguous',
        'text': 'repeat',
      });
      await _tick();
      bridge.addRpcEntry('repeat-one', 'repeat');
      bridge.addRpcEntry('repeat-two', 'repeat');
      bridge.emitEvents([_rpcTerminal('repeat', 'unproven answer')]);
      await _tick();
      expect(bridge.turns.single.delivery, VoiceDelivery.uncertain);
      expect(session.sent, isEmpty);
      session.add({'type': 'delegation', 'id': 'rpc-blocked', 'text': 'next'});
      await _tick();
      expect(bridge.sends, 1);
      await controller.stop();
    },
  );

  test(
    'RPC uncertain reservation stays fenced after controller recreation',
    () async {
      final bridge = _Bridge();
      final firstSession = _Session();
      final first = _controller(firstSession, bridge);
      await first.start(chatId: 'chat');
      firstSession.add({
        'type': 'delegation',
        'id': 'rpc-unknown',
        'text': 'pending task',
      });
      await _tick();
      await first.stop();
      final restored = _Bridge()
        ..turns.addAll(
          bridge.turns.map((turn) => VoiceTurn.fromJson(turn.toJson())),
        );
      final secondSession = _Session();
      final second = _controller(secondSession, restored);
      await second.start(chatId: 'chat');
      restored.addRpcEntry('old-pending-echo', 'pending task');
      restored.emitEvents([_rpcTerminal('pending task', 'unowned answer')]);
      await _tick();
      expect(restored.turns.single.delivery, VoiceDelivery.uncertain);
      expect(secondSession.sent, isEmpty);
      secondSession.add({
        'type': 'delegation',
        'id': 'rpc-new',
        'text': 'new task',
      });
      await _tick();
      expect(restored.sends, 0);
      await second.stop();
    },
  );

  test('later RPC user input cannot own the delegated final', () async {
    final bridge = _Bridge();
    final session = _Session();
    final controller = _controller(session, bridge);
    await controller.start(chatId: 'chat');
    session.add({
      'type': 'delegation',
      'id': 'rpc-interrupted',
      'text': 'my task',
    });
    await _tick();
    bridge.addRpcEntry('my-echo', 'my task');
    bridge.emitEvents([
      {
        'type': 'agent_end',
        'isTerminal': true,
        'messages': [
          _rpcUser('my task'),
          _rpcUser('other task'),
          {
            'role': 'assistant',
            'stopReason': 'stop',
            'content': 'other answer',
          },
        ],
      },
    ]);
    await _tick();
    expect(bridge.turns.single.delivery, VoiceDelivery.delivered);
    expect(session.delegationIds, [null]);
    expect(session.sent.single, contains('other answer'));
    await controller.stop();
  });

  test('RPC typed echo releases queued delegation', () async {
    final bridge = _Bridge();
    final session = _Session();
    final controller = _controller(session, bridge);
    await controller.start(chatId: 'chat');
    session.add({'type': 'connected'});
    await _tick();
    await controller.sendText('spoken');
    final prepared = await bridge.preparer!('typed task');
    session.add({
      'type': 'delegation',
      'id': 'rpc-after-typed',
      'text': 'next',
    });
    await _tick();
    expect(bridge.sends, 0);
    bridge.addRpcEntry('typed-rpc-echo', prepared);
    bridge.emitEvents([
      {'type': 'message_end', 'message': _rpcUser(prepared)},
    ]);
    await _tick();
    expect(bridge.turns.first.delivery, VoiceDelivery.delivered);
    expect(bridge.turns.first.typedEcho, isTrue);
    expect(bridge.sentBodies, ['next']);
    await controller.stop();
  });

  test(
    'only matching terminal run with toolUse commentary speaks final wrapper',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({'type': 'connected'});
      session.add({'type': 'delegation', 'id': 'd3', 'text': 'Do work'});
      await _tick();
      final prompt = bridge.sentBodies.single;
      bridge.addEntry('echo', prompt);
      bridge.emitEvents([
        {
          'type': 'message_start',
          'message': {
            'role': 'custom',
            'customType': 'collab-prompt',
            'content': prompt,
          },
        },
        {
          'type': 'message_end',
          'message': {
            'role': 'assistant',
            'stopReason': 'toolUse',
            'content': [
              {
                'type': 'text',
                'text': VoiceDirective.decorate(
                  'working',
                  'internal instructions',
                ),
              },
            ],
          },
        },
        {
          'type': 'agent_end',
          'isTerminal': false,
          'messages': [
            {'role': 'assistant', 'stopReason': 'stop', 'content': 'early'},
          ],
        },
      ]);
      await _tick();
      expect(session.sent, ['working']);
      bridge.emitEvents([
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {
              'role': 'custom',
              'customType': 'collab-prompt',
              'content': prompt,
            },
            {
              'role': 'assistant',
              'stopReason': 'toolUse',
              'content': 'working',
            },
            {
              'role': 'assistant',
              'stopReason': 'stop',
              'content': VoiceDirective.decorate(
                'done',
                'internal instructions',
              ),
            },
          ],
        },
      ]);
      await _tick();
      expect(session.sent.last, '"Agent Final Message":\n\ndone');
      expect(session.delegationIds, ['d3', 'd3']);
      await controller.stop();
    },
  );

  test(
    'no-tool final in same run as later manual steering is speakable',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({'type': 'connected'});
      session.add({'type': 'delegation', 'id': 'n1', 'text': 'Find result'});
      await _tick();
      final prompt = bridge.sentBodies.single;
      bridge.addEntry('echo', prompt);
      bridge.emitEvents([
        {
          'type': 'message_start',
          'message': {
            'role': 'custom',
            'customType': 'collab-prompt',
            'content': prompt,
          },
        },
        {
          'type': 'message_start',
          'message': {
            'role': 'custom',
            'customType': 'collab-prompt',
            'content': 'manual steering',
          },
        },
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {
              'role': 'custom',
              'customType': 'collab-prompt',
              'content': prompt,
            },
            {
              'role': 'custom',
              'customType': 'collab-prompt',
              'content': 'manual steering',
            },
            {'role': 'assistant', 'stopReason': 'stop', 'content': 'found it'},
          ],
        },
      ]);
      await _tick();
      expect(session.sent.single, contains('found it'));
      expect(session.delegationIds.single, 'n1');
      await controller.stop();
    },
  );

  test(
    'durable uncertain barrier prevents replay after stopping before echo',
    () async {
      final bridge = _Bridge();
      final firstSession = _Session();
      final first = _controller(firstSession, bridge);
      await first.start(chatId: 'chat');
      firstSession.add({'type': 'connected'});
      firstSession.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'spoken',
        'text': 'spoken',
        'final': true,
      });
      await _tick();
      firstSession.add({'type': 'delegation', 'id': 'first', 'text': ''});
      await _tick();
      expect(
        bridge.turns
            .where((turn) => turn.routingPurpose != VoiceTurnPurpose.request)
            .single
            .delivery,
        VoiceDelivery.uncertain,
      );
      expect(bridge.sends, 1);
      await first.stop();
      final secondSession = _Session();
      final second = _controller(secondSession, bridge);
      await second.start(chatId: 'chat');
      secondSession.add({'type': 'connected'});
      secondSession.add({'type': 'delegation', 'id': 'later', 'text': 'new'});
      await _tick();
      expect(bridge.sends, 1);
      expect(
        bridge.turns
            .where((turn) => turn.routingPurpose != VoiceTurnPurpose.request)
            .single
            .text,
        'spoken',
      );
      await second.stop();
    },
  );
  test(
    'failed native startup disarms first-send two-model directive',
    () async {
      final bridge = _Bridge();
      final session = _Session()..failStart = true;
      final controller = _controller(session, bridge);
      await expectLater(controller.start(chatId: 'chat'), throwsStateError);
      expect(bridge.armed, isFalse);
      expect(bridge.preparer, isNull);
      expect(session.stops, 1);
    },
  );

  test(
    'failed durable flush reuses one final turn ID and later recovers',
    () async {
      final bridge = _Bridge()..failNextSave = true;
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({'type': 'connected'});
      session.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'same',
        'text': 'spoken',
        'final': true,
      });
      await _tick();
      final id = bridge.turns.single.id;
      session.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'same',
        'text': 'spoken',
        'final': true,
      });
      await _tick();
      expect(
        bridge.turns
            .where((turn) => turn.routingPurpose != VoiceTurnPurpose.request)
            .map((turn) => turn.id),
        [id],
      );
      session.add({'type': 'delegation', 'id': 'recover', 'text': ''});
      await _tick();
      expect(
        bridge.turns
            .where((turn) => turn.routingPurpose != VoiceTurnPurpose.request)
            .map((turn) => turn.id),
        [id],
      );
      expect(bridge.sends, 1);
      await controller.stop();
    },
  );

  test(
    'terminal run payload plus echo proves input even without input events',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({'type': 'connected'});
      session.add({
        'type': 'delegation',
        'id': 'terminal-only',
        'text': 'Please check',
      });
      await _tick();
      final prompt = bridge.sentBodies.single;
      bridge.addEntry('echo-terminal', prompt);
      bridge.emitEvents([
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {
              'role': 'custom',
              'customType': 'collab-prompt',
              'content': prompt,
            },
            {'role': 'assistant', 'stopReason': 'stop', 'content': 'answer'},
          ],
        },
      ]);
      await _tick();
      expect(session.sent.single, contains('answer'));
      expect(session.delegationIds.single, 'terminal-only');
      await controller.stop();
    },
  );
  test(
    'Spark sheet typing retains typed human origin and User label',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({'type': 'connected'});
      await _tick();
      await controller.sendText('typed in Spark');
      await _tick();
      expect(
        bridge.turns
            .where((turn) => turn.routingPurpose != VoiceTurnPurpose.request)
            .single
            .origin,
        VoiceTurnOrigin.typedUser,
      );
      session.add({'type': 'delegation', 'id': 'typed-origin', 'text': ''});
      await _tick();
      expect(bridge.sentBodies.single, 'User: typed in Spark');
      await controller.stop();
    },
  );
  test('retains a second realtime intent until the first exact echo', () async {
    final bridge = _Bridge();
    final session = _Session();
    final controller = _controller(session, bridge);
    await controller.start(chatId: 'chat');
    session.add({'type': 'connected'});
    session.add({
      'type': 'transcript',
      'role': 'user',
      'id': 'u',
      'text': 'spoken',
      'final': true,
    });
    await _tick();
    session.add({'type': 'delegation', 'id': 'first', 'text': ''});
    await _tick();
    expect(bridge.sends, 1);
    session.add({'type': 'delegation', 'id': 'second', 'text': 'new request'});
    session.add({'type': 'delegation', 'id': 'second', 'text': 'new request'});
    await _tick();
    expect(bridge.sends, 1);
    final firstBody = bridge.sentBodies.single;
    bridge.addEntry('first-echo', firstBody);
    bridge.emitEvents([
      {
        'type': 'message_start',
        'message': {
          'role': 'custom',
          'customType': 'collab-prompt',
          'content': firstBody,
        },
      },
    ]);
    await _tick();
    expect(bridge.sends, 2);
    expect(bridge.sentBodies.last, 'new request');
    await controller.stop();
  });

  test(
    'composer equal to an old delegation still exposes new voice context',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({
        'type': 'delegation',
        'id': 'old',
        'text': 'Inspect assets',
      });
      await _tick();
      expect(bridge.sentBodies.single, 'Inspect assets');
      bridge.addEntry('old-echo', 'Inspect assets');
      bridge.emitEvents([
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {
              'role': 'custom',
              'customType': 'collab-prompt',
              'content': 'Inspect assets',
            },
            {'role': 'assistant', 'stopReason': 'stop', 'content': 'Done'},
          ],
        },
      ]);
      await _tick();
      expect(bridge.turns.single.delivery, VoiceDelivery.delivered);
      session.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'fresh-voice',
        'text': 'Also check README',
        'final': true,
      });
      await _tick();
      final prepared = await bridge.preparer!('Inspect assets');
      expect(prepared, 'User: Also check README\nInspect assets');
      expect(bridge.sentBodies, ['Inspect assets']);
      expect(
        bridge.turns
            .where((turn) => turn.origin == VoiceTurnOrigin.user)
            .single
            .delivery,
        VoiceDelivery.uncertain,
      );
      expect(
        bridge.turns
            .where((turn) => turn.routingPurpose == VoiceTurnPurpose.request)
            .single
            .delivery,
        VoiceDelivery.delivered,
      );
      await controller.stop();
    },
  );

  test(
    'failed initial save cannot regress typed quarantine to pending',
    () async {
      final bridge = _Bridge()..failNextSave = true;
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({'type': 'connected'});
      session.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'u',
        'text': 'spoken',
        'final': true,
      });
      await _tick();
      expect(bridge.turns.single.delivery, VoiceDelivery.pending);
      expect(
        await bridge.preparer!('typed command'),
        'User: spoken\ntyped command',
      );
      expect(bridge.turns.single.delivery, VoiceDelivery.uncertain);
      session.add({
        'type': 'delegation',
        'id': 'blocked',
        'text': 'other work',
      });
      await _tick();
      expect(bridge.turns.single.delivery, VoiceDelivery.uncertain);
      expect(bridge.sends, 0);
      await controller.stop();
      expect(bridge.turns.single.delivery, VoiceDelivery.uncertain);
    },
  );

  test('queued intent drains when a typed echo resolves uncertainty', () async {
    final bridge = _Bridge();
    final session = _Session();
    final controller = _controller(session, bridge);
    await controller.start(chatId: 'chat');
    session.add({'type': 'connected'});
    session.add({
      'type': 'transcript',
      'role': 'user',
      'id': 'u',
      'text': 'spoken',
      'final': true,
    });
    await _tick();
    final prepared = await bridge.preparer!('typed command');
    session.add({'type': 'delegation', 'id': 'after-typed', 'text': 'next'});
    await _tick();
    expect(bridge.sends, 0);
    bridge.addEntry('typed-echo', prepared);
    bridge.emitEvents([
      {
        'type': 'message_start',
        'message': {
          'role': 'custom',
          'customType': 'collab-prompt',
          'content': prepared,
        },
      },
    ]);
    await _tick();
    expect(
      bridge.turns
          .where((turn) => turn.routingPurpose != VoiceTurnPurpose.request)
          .single
          .delivery,
      VoiceDelivery.delivered,
    );
    expect(bridge.sends, 1);
    expect(bridge.sentBodies.single, 'next');
    await controller.stop();
  });

  test(
    'stop releases voice promptly but joins finalized writes before returning',
    () async {
      final bridge = _Bridge()..saveGate = Completer<void>();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({'type': 'connected'});
      session.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'u',
        'text': 'undelegated',
        'final': true,
      });
      await _tick();
      var stopped = false;
      final stopping = controller.stop().then((_) => stopped = true);
      await _tick();
      expect(session.stops, 1);
      expect(stopped, isFalse);
      bridge.saveGate!.complete();
      await stopping;
      expect(bridge.turns.single.text, 'undelegated');
      expect(stopped, isTrue);
    },
  );
  test(
    'voice stream failure flushes finalized turns without hiding voice error',
    () async {
      final bridge = _Bridge()..failNextSave = true;
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({'type': 'connected'});
      session.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'u',
        'text': 'undelegated',
        'final': true,
      });
      await _tick();
      expect(bridge.saveCalls, 1);
      session.fail();
      await _tick();
      expect(bridge.saveCalls, 2);
      expect(bridge.turns.single.text, 'undelegated');
      expect(controller.snapshot.phase, SparkPhase.error);
      expect(controller.snapshot.error, 'Spark voice connection failed.');
      expect(session.stops, 1);
    },
  );
  test(
    'partial-before-delegation seals only after its aliased final',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'partial',
        'text': 'first ',
        'final': false,
      });
      session.add({
        'type': 'delegation',
        'id': 'd-partial',
        'text': 'first task',
      });
      await _tick();
      expect(bridge.sends, 0);
      session.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'final-alias',
        'text': 'first task',
        'final': true,
      });
      await _tick();
      expect(bridge.sentBodies, ['User: first task']);
      expect(
        bridge.turns
            .where((turn) => turn.routingPurpose == VoiceTurnPurpose.request)
            .single
            .routingSourceTurnId,
        bridge.turns.first.id,
      );
      await controller.stop();
    },
  );

  test(
    'late exact final aliases reservation; repeated human turn stays distinct',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({
        'type': 'delegation',
        'id': 'late',
        'text': 'Inspect config',
      });
      await _tick();
      expect(bridge.sentBodies.single, 'Inspect config');
      session.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'late-final',
        'text': 'Inspect config',
        'final': true,
      });
      await _tick();
      expect(
        bridge.turns
            .where((turn) => turn.routingPurpose == VoiceTurnPurpose.request)
            .single
            .text,
        '',
      );
      expect(
        bridge.turns
            .where((turn) => turn.origin == VoiceTurnOrigin.user)
            .single
            .delivery,
        VoiceDelivery.uncertain,
      );
      final body = bridge.sentBodies.single;
      bridge.addEntry('late-echo', body);
      bridge.emitEvents([
        {
          'type': 'message_start',
          'message': {
            'role': 'custom',
            'customType': 'collab-prompt',
            'content': body,
          },
        },
      ]);
      await _tick();
      expect(
        bridge.turns
            .where((turn) => turn.origin == VoiceTurnOrigin.user)
            .single
            .delivery,
        VoiceDelivery.delivered,
      );
      session.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'repeated-new',
        'text': 'Inspect config',
        'final': true,
      });
      await _tick();
      session.add({'type': 'delegation', 'id': 'again', 'text': ''});
      await _tick();
      expect(bridge.sentBodies, ['Inspect config', 'User: Inspect config']);
      await controller.stop();
    },
  );

  test(
    'divergent late final remains historical context without automatic execution',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({'type': 'delegation', 'id': 'old', 'text': 'Find version'});
      await _tick();
      session.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'divergent',
        'text': 'Check platform instead',
        'final': true,
      });
      await _tick();
      expect(bridge.sends, 1);
      expect(
        bridge.turns
            .where((turn) => turn.origin == VoiceTurnOrigin.user)
            .single
            .routingPurpose,
        VoiceTurnPurpose.lateContext,
      );
      bridge.addEntry('old-echo', 'Find version');
      bridge.emitEvents([
        {
          'type': 'message_start',
          'message': {
            'role': 'custom',
            'customType': 'collab-prompt',
            'content': 'Find version',
          },
        },
      ]);
      await _tick();
      session.add({
        'type': 'delegation',
        'id': 'new',
        'text': 'Next explicit work',
      });
      await _tick();
      expect(
        bridge.sentBodies.last,
        'User (historical late context; not a new request): Check platform instead\nNext explicit work',
      );
      await controller.stop();
    },
  );

  test(
    'partial result retelling remains excluded after a newer user final',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      bridge.emitEvents([
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {'role': 'user', 'content': 'external task'},
            {
              'role': 'assistant',
              'stopReason': 'stop',
              'content': 'external result',
            },
          ],
        },
      ]);
      await _tick();
      expect(session.delegationIds, [null]);
      session.add({
        'type': 'transcript',
        'role': 'assistant',
        'id': 'retell-part',
        'text': 'The main result',
        'final': false,
      });
      session.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'new-user',
        'text': 'Fresh request',
        'final': true,
      });
      session.add({
        'type': 'transcript',
        'role': 'assistant',
        'id': 'retell-final',
        'text': 'The main result was ready',
        'final': true,
      });
      await _tick();
      expect(
        bridge.turns
            .where((turn) => turn.origin == VoiceTurnOrigin.spark)
            .single
            .routingPurpose,
        VoiceTurnPurpose.resultFeedback,
      );
      session.add({
        'type': 'delegation',
        'id': 'fresh',
        'text': 'Fresh request',
      });
      await _tick();
      expect(bridge.sentBodies.single, 'User: Fresh request');
      await controller.stop();
    },
  );

  test(
    'external terminal preference is live, skips history and duplicates',
    () async {
      final bridge = _Bridge();
      bridge.emitEvents([
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {'role': 'user', 'content': 'history'},
            {'role': 'assistant', 'stopReason': 'stop', 'content': 'old'},
          ],
        },
      ]);
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      await _tick();
      expect(session.sent, isEmpty);
      final terminal = <String, Object?>{
        'type': 'agent_end',
        'isTerminal': true,
        'messages': [
          {'role': 'user', 'content': 'new external work'},
          {
            'role': 'assistant',
            'stopReason': 'stop',
            'content': 'fresh result',
          },
        ],
      };
      bridge.emitEvents([terminal]);
      await _tick();
      expect(session.sent.single, contains('fresh result'));
      expect(session.delegationIds.single, isNull);
      bridge.emitEvents([
        terminal,
      ]); // Same terminal replay with a new sequence.
      await _tick();
      expect(session.sent, hasLength(1));
      bridge.emitEvents([
        {'type': 'agent_start'},
        terminal,
      ]);
      await _tick();
      expect(session.sent, hasLength(2));
      expect(session.delegationIds, [null, null]);
      await controller.saveSettings(
        controller.settings.copyWith(announceTerminalReplies: false),
      );
      bridge.emitEvents([
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {'role': 'user', 'content': 'muted input'},
            {
              'role': 'assistant',
              'stopReason': 'stop',
              'content': 'muted result',
            },
          ],
        },
      ]);
      await _tick();
      await controller.saveSettings(
        controller.settings.copyWith(announceTerminalReplies: true),
      );
      bridge.emit();
      await _tick();
      expect(session.sent, hasLength(2));
      bridge.emitEvents([
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {'role': 'user', 'content': 'ongoing'},
            {
              'role': 'assistant',
              'stopReason': 'toolUse',
              'content': 'not final',
            },
          ],
        },
      ]);
      await _tick();
      expect(session.sent, hasLength(2));
      await controller.stop();
    },
  );
  test(
    'external run interleaved with delegation never borrows its ID',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({'type': 'delegation', 'id': 'owned', 'text': 'Local work'});
      await _tick();
      final prompt = bridge.sentBodies.single;
      bridge.addEntry('owned-echo', prompt);
      bridge.emitEvents([
        {
          'type': 'message_start',
          'message': {
            'role': 'custom',
            'customType': 'collab-prompt',
            'content': prompt,
          },
        },
      ]);
      await _tick();
      bridge.emitEvents([
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {
              'role': 'custom',
              'customType': 'collab-prompt',
              'content': prompt,
            },
            {
              'role': 'assistant',
              'stopReason': 'stop',
              'content': 'owned result',
            },
          ],
        },
      ]);
      await _tick();
      expect(session.delegationIds, ['owned']);
      bridge.emitEvents([
        {'type': 'agent_start'},
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {
              'role': 'custom',
              'customType': 'collab-prompt',
              'content': prompt,
            },
            {
              'role': 'assistant',
              'stopReason': 'stop',
              'content': 'owned result',
            },
            {'role': 'user', 'content': 'separate terminal request'},
            {
              'role': 'assistant',
              'stopReason': 'stop',
              'content': 'external answer',
            },
          ],
        },
      ]);
      await _tick();
      expect(session.delegationIds, ['owned', null]);
      expect(session.sent.last, contains('external answer'));
      await controller.stop();
    },
  );
  test(
    'request-only uncertain reservation survives codec/restart without replay',
    () async {
      final bridge = _Bridge();
      final firstSession = _Session();
      final first = _controller(firstSession, bridge);
      await first.start(chatId: 'chat');
      firstSession.add({
        'type': 'delegation',
        'id': 'first',
        'text': 'One task',
      });
      await _tick();
      expect(bridge.turns.single.routingPurpose, VoiceTurnPurpose.request);
      expect(bridge.turns.single.delivery, VoiceDelivery.uncertain);
      final durable = bridge.turns.single.toJson();
      bridge.turns
        ..clear()
        ..add(VoiceTurn.fromJson(durable));
      await first.stop();
      final resumedSession = _Session();
      final resumed = _controller(resumedSession, bridge);
      await resumed.start(chatId: 'chat');
      resumedSession.add({
        'type': 'delegation',
        'id': 'next',
        'text': 'Another task',
      });
      await _tick();
      expect(bridge.sentBodies, ['One task']);
      expect(bridge.turns.single.routingAwaitingSource, isFalse);
      await resumed.stop();
    },
  );
  test(
    'late partial after dispatch aliases final without replaying it',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({
        'type': 'delegation',
        'id': 'before-partial',
        'text': 'Summarize flags',
      });
      await _tick();
      session.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'partial-late',
        'text': 'Summarize ',
        'final': false,
      });
      session.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'final-late',
        'text': 'Summarize flags',
        'final': true,
      });
      await _tick();
      expect(bridge.sentBodies, ['Summarize flags']);
      expect(
        bridge.turns
            .where((turn) => turn.origin == VoiceTurnOrigin.user)
            .single
            .delivery,
        VoiceDelivery.uncertain,
      );
      expect(
        bridge.turns
            .where((turn) => turn.routingPurpose == VoiceTurnPurpose.request)
            .single
            .routingSourceTurnId,
        bridge.turns
            .where((turn) => turn.origin == VoiceTurnOrigin.user)
            .single
            .id,
      );
      await controller.stop();
    },
  );
  test(
    'positively observed external prompt can finish beside unresolved delegation',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({
        'type': 'delegation',
        'id': 'pending',
        'text': 'Local task',
      });
      await _tick();
      bridge.addEntry('external-input', 'Other terminal task');
      bridge.emitEvents([
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {
              'role': 'custom',
              'customType': 'collab-prompt',
              'content': 'Other terminal task',
            },
            {
              'role': 'assistant',
              'stopReason': 'stop',
              'content': 'Other task result',
            },
          ],
        },
      ]);
      await _tick();
      expect(session.sent.single, contains('Other task result'));
      expect(session.delegationIds.single, isNull);
      expect(
        bridge.turns
            .where((turn) => turn.routingPurpose == VoiceTurnPurpose.request)
            .single
            .delivery,
        VoiceDelivery.uncertain,
      );
      bridge.emitEvents([
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {
              'role': 'assistant',
              'stopReason': 'stop',
              'content': 'No input source',
            },
          ],
        },
      ]);
      await _tick();
      expect(session.sent, hasLength(1));
      await controller.stop();
    },
  );
  test(
    'late final after echoed prompt persists alias; new-session repeat is distinct',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final first = _controller(session, bridge);
      await first.start(chatId: 'chat');
      session.add({
        'type': 'delegation',
        'id': 'slow-final',
        'text': 'Explain state',
      });
      await _tick();
      bridge.addEntry('echo', 'Explain state');
      bridge.emitEvents([
        {
          'type': 'message_start',
          'message': {
            'role': 'custom',
            'customType': 'collab-prompt',
            'content': 'Explain state',
          },
        },
      ]);
      await _tick();
      expect(bridge.turns.single.delivery, VoiceDelivery.delivered);
      expect(bridge.turns.single.routingAwaitingSource, isTrue);
      session.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'late-authoritative',
        'text': 'Explain state',
        'final': true,
      });
      await _tick();
      expect(
        bridge.turns
            .where((turn) => turn.origin == VoiceTurnOrigin.user)
            .single
            .delivery,
        VoiceDelivery.delivered,
      );
      expect(
        bridge.turns
            .where((turn) => turn.routingPurpose == VoiceTurnPurpose.request)
            .single
            .text,
        '',
      );
      expect(
        bridge.turns
            .where((turn) => turn.routingPurpose == VoiceTurnPurpose.request)
            .single
            .routingAwaitingSource,
        isFalse,
      );
      bridge.emitEvents([
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {
              'role': 'custom',
              'customType': 'collab-prompt',
              'content': 'Explain state',
            },
            {
              'role': 'assistant',
              'stopReason': 'stop',
              'content': 'The state is ready',
            },
          ],
        },
      ]);
      await _tick();
      await first.stop();
      final restored = bridge.turns
          .map((turn) => VoiceTurn.fromJson(turn.toJson()))
          .toList();
      bridge.turns
        ..clear()
        ..addAll(restored);
      final secondSession = _Session();
      final second = _controller(secondSession, bridge);
      await second.start(chatId: 'chat');
      secondSession.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'independent-repeat',
        'text': 'Explain state',
        'final': true,
      });
      await _tick();
      expect(
        bridge.turns
            .where((turn) => turn.origin == VoiceTurnOrigin.user)
            .map((turn) => turn.delivery),
        [VoiceDelivery.delivered, VoiceDelivery.pending],
      );
      secondSession.add({
        'type': 'delegation',
        'id': 'repeat-request',
        'text': '',
      });
      await _tick();
      expect(bridge.sentBodies, ['Explain state', 'User: Explain state']);
      await second.stop();
    },
  );
  test(
    'completed request cannot swallow independent same-text speech',
    () async {
      final bridge = _Bridge();
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({
        'type': 'delegation',
        'id': 'first',
        'text': 'Explain state',
      });
      await _tick();
      bridge.addEntry('first-echo', 'Explain state');
      bridge.emitEvents([
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {
              'role': 'custom',
              'customType': 'collab-prompt',
              'content': 'Explain state',
            },
            {'role': 'assistant', 'stopReason': 'stop', 'content': 'Done'},
          ],
        },
      ]);
      await _tick();
      expect(bridge.turns.single.routingAwaitingSource, isFalse);
      session.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'repeat',
        'text': 'Explain state',
        'final': true,
      });
      await _tick();
      expect(
        bridge.turns
            .where((turn) => turn.origin == VoiceTurnOrigin.user)
            .single
            .delivery,
        VoiceDelivery.pending,
      );
      session.add({
        'type': 'delegation',
        'id': 'second',
        'text': 'Explain state',
      });
      await _tick();
      expect(bridge.sentBodies, ['Explain state', 'User: Explain state']);
      await controller.stop();
    },
  );
  test(
    'definitely rejected prompt releases selected source without retry',
    () async {
      final bridge = _Bridge()
        ..nextResult = const SparkChatSendResult(
          SparkSendOutcome.rejected,
          message: 'busy before socket',
        );
      final session = _Session();
      final controller = _controller(session, bridge);
      await controller.start(chatId: 'chat');
      session.add({
        'type': 'transcript',
        'role': 'user',
        'id': 'source',
        'text': 'Inspect assets',
        'final': true,
      });
      await _tick();
      session.add({
        'type': 'delegation',
        'id': 'busy',
        'text': 'Inspect assets',
      });
      await _tick();
      expect(bridge.sends, 1);
      expect(
        bridge.turns
            .where((turn) => turn.origin == VoiceTurnOrigin.user)
            .single
            .delivery,
        VoiceDelivery.pending,
      );
      expect(
        bridge.turns
            .where((turn) => turn.routingPurpose == VoiceTurnPurpose.request)
            .single
            .text,
        '',
      );
      session.add({
        'type': 'delegation',
        'id': 'next',
        'text': 'Another explicit task',
      });
      await _tick();
      expect(
        bridge.sentBodies.last,
        'User: Inspect assets\nAnother explicit task',
      );
      expect(bridge.sends, 2);
      await controller.stop();
    },
  );
  test(
    'unknown socket delivery stays quarantined across terminal and restart',
    () async {
      final bridge = _Bridge()
        ..nextResult = const SparkChatSendResult(SparkSendOutcome.uncertain);
      final firstVoice = _Session();
      final first = _controller(firstVoice, bridge);
      await first.start(chatId: 'chat');
      firstVoice.add({
        'type': 'delegation',
        'id': 'uncertain',
        'text': 'Inspect settings',
      });
      await _tick();
      expect(bridge.sentBodies.single, 'Inspect settings');
      const ownTerminal = <String, Object?>{
        'type': 'agent_end',
        'isTerminal': true,
        'messages': [
          {
            'role': 'custom',
            'customType': 'collab-prompt',
            'content': 'Inspect settings',
          },
          {
            'role': 'assistant',
            'stopReason': 'stop',
            'content': 'Original answer',
          },
        ],
      };
      bridge.addEntry('uncertain-echo', 'Inspect settings');
      bridge.emitEvents([ownTerminal]);
      await _tick();
      expect(firstVoice.sent, isEmpty);
      expect(bridge.turns.single.delivery, VoiceDelivery.uncertain);
      await first.stop();
      final secondVoice = _Session();
      final second = _controller(secondVoice, bridge);
      await second.start(chatId: 'chat');
      bridge.emitEvents([
        {'type': 'agent_start'},
        ownTerminal,
      ]);
      await _tick();
      expect(secondVoice.sent, isEmpty);
      expect(bridge.turns.single.delivery, VoiceDelivery.uncertain);
      // The newest input, not an older uncertain prompt, determines ownership.
      bridge.emitEvents([
        {'type': 'agent_start'},
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {
              'role': 'custom',
              'customType': 'collab-prompt',
              'content': 'Inspect settings',
            },
            {'role': 'user', 'content': 'Independent terminal work'},
            {
              'role': 'assistant',
              'stopReason': 'stop',
              'content': 'Independent answer',
            },
          ],
        },
      ]);
      await _tick();
      expect(secondVoice.sent.single, contains('Independent answer'));
      expect(secondVoice.delegationIds.single, isNull);
      bridge.emitEvents([
        {'type': 'agent_start'},
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {'role': 'user', 'content': 'Independent terminal work'},
            {
              'role': 'custom',
              'customType': 'collab-prompt',
              'content': 'Inspect settings',
            },
            {
              'role': 'assistant',
              'stopReason': 'stop',
              'content': 'Unattributed old work',
            },
          ],
        },
      ]);
      await _tick();
      expect(secondVoice.sent, hasLength(1));
      await second.stop();
    },
  );

  test(
    'later ordinary user and distinct same-text composer echo stay external',
    () async {
      final bridge = _Bridge();
      final voice = _Session();
      final controller = _controller(voice, bridge);
      await controller.start(chatId: 'chat');
      voice.add({'type': 'delegation', 'id': 'owned', 'text': 'Same text'});
      await _tick();
      bridge.emitEvents([
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {'role': 'user', 'content': 'Unrelated user input'},
            {
              'role': 'assistant',
              'stopReason': 'stop',
              'content': 'Unrelated answer',
            },
          ],
        },
      ]);
      await _tick();
      expect(voice.delegationIds, [null]);
      expect(bridge.turns.single.delivery, VoiceDelivery.uncertain);
      bridge.addEntry('owned-echo', 'Same text');
      bridge.emitEvents([
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {
              'role': 'custom',
              'customType': 'collab-prompt',
              'content': 'Same text',
            },
            {
              'role': 'assistant',
              'stopReason': 'stop',
              'content': 'Owned answer',
            },
          ],
        },
      ]);
      await _tick();
      expect(voice.delegationIds, [null, 'owned']);
      bridge.emitEvents([
        {'type': 'agent_start'},
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {
              'role': 'custom',
              'customType': 'collab-prompt',
              'content': 'Same text',
            },
            {
              'role': 'assistant',
              'stopReason': 'stop',
              'content': 'Owned answer',
            },
          ],
        },
      ]);
      await _tick();
      expect(
        voice.sent,
        hasLength(2),
      ); // No new raw input: repeated old result.
      bridge.addEntry('fresh-composer-echo', 'Same text');
      bridge.emitEvents([
        {'type': 'agent_start'},
        {
          'type': 'agent_end',
          'isTerminal': true,
          'messages': [
            {
              'role': 'custom',
              'customType': 'collab-prompt',
              'content': 'Same text',
            },
            {
              'role': 'assistant',
              'stopReason': 'stop',
              'content': 'New answer',
            },
          ],
        },
      ]);
      await _tick();
      expect(voice.delegationIds, [null, 'owned', null]);
      expect(voice.sent.last, contains('New answer'));
      await controller.stop();
    },
  );
}

Map<String, Object?> _rpcUser(String text) => {
  'role': 'user',
  'content': [
    {'type': 'text', 'text': text},
  ],
};

Map<String, Object?> _rpcTerminal(String prompt, String answer) => {
  'type': 'agent_end',
  'isTerminal': true,
  'messages': [
    _rpcUser(prompt),
    {
      'role': 'assistant',
      'stopReason': 'stop',
      'content': [
        {'type': 'text', 'text': answer},
      ],
    },
  ],
};

Future<void> _tick() async {
  await Future<void>.delayed(const Duration(milliseconds: 10));
}

SparkController _controller(_Session session, _Bridge bridge) =>
    SparkController(
      session: session,
      credentials: _Credentials(),
      store: _Store(),
      chatBridge: bridge,
    );

class _Session implements VoiceSession {
  final _events = StreamController<Map<String, Object?>>.broadcast();
  final sent = <String>[];
  final delegationIds = <String?>[];
  int stops = 0;
  bool failStart = false;
  void add(Map<String, Object?> event) => _events.add(event);
  void fail() => _events.addError(StateError('Synthetic voice stream failure'));
  @override
  Stream<Map<String, Object?>> get events => _events.stream;
  @override
  Future<void> start({
    required String accessToken,
    String? accountId,
    required String instructions,
    required String voice,
  }) async {
    if (failStart) throw StateError('Synthetic microphone denial');
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> sendText(
    String text, {
    String? delegationId,
    String channel = 'speakable',
  }) async {
    sent.add(text);
    delegationIds.add(delegationId);
  }

  @override
  Future<void> dispose() => _events.close();
}

class _Credentials implements SparkCredentialSource {
  @override
  Future<SparkCredentialResult> acquire(
    SparkSettings settings,
    String brokerToken,
  ) async => const SparkCredentialResult(
    choices: [SparkCredentialChoice(id: 'one', label: 'One')],
    credential: SparkCredential(
      id: 'one',
      accessToken: 'synthetic-access',
      expiresAtMs: 9999999999999,
    ),
  );
}

class _Store implements SparkSettingsStore {
  @override
  Future<StoredSparkSettings> load() async => const StoredSparkSettings(
    settings: SparkSettings(),
    hasBrokerToken: true,
  );
  @override
  Future<String?> readBrokerToken() async => 'synthetic-broker-token';
  @override
  Future<void> save(SparkSettings settings, {String? brokerToken}) async {}
}

class _Bridge implements SparkChatBridge {
  final stream = StreamController<SparkChatObservation>.broadcast();
  final turns = <VoiceTurn>[];
  final entries = <Map<String, Object?>>[];
  final events = <AgentEvent>[];
  final sentBodies = <String>[];
  int sends = 0;
  bool armed = false;
  Future<String> Function(String)? preparer;
  bool failNextSave = false;
  int saveCalls = 0;
  SparkChatSendResult? nextResult;
  Completer<void>? saveGate;
  SparkChatObservation get observation => SparkChatObservation(
    voiceTurns: List.of(turns),
    snapshot: HarnessSnapshot(
      phase: ConnectionPhase.live,
      readOnly: false,
      rawEntries: List.of(entries),
      agentEvents: List.of(events),
    ),
  );
  void emit() => stream.add(observation);
  void emitEvents(List<Map<String, Object?>> changes) {
    for (final item in changes) {
      events.add(AgentEvent(sequence: events.length + 1, event: item));
    }
    emit();
  }

  void addEntry(String id, String content) {
    entries.add({
      'type': 'custom_message',
      'customType': 'collab-prompt',
      'id': id,
      'content': content,
    });
    emit();
  }

  void addRpcEntry(String id, String content) {
    entries.add({'type': 'message', 'id': id, 'message': _rpcUser(content)});
    emit();
  }

  @override
  SparkChatObservation? current(String chatId) =>
      chatId == 'chat' ? observation : null;
  @override
  Stream<SparkChatObservation> observe(String chatId) => stream.stream;
  @override
  Future<List<SparkChatChoice>> listChats() async => const [
    SparkChatChoice(id: 'chat', label: 'Chat', canSend: true, isLive: true),
  ];
  @override
  Future<void> saveTurn(String chatId, VoiceTurn turn) async {
    saveCalls++;
    final i = turns.indexWhere((existing) => existing.id == turn.id);
    if (i >= 0) {
      turns[i] = turn;
    } else {
      turns.add(turn);
    }
    emit();
    if (failNextSave) {
      failNextSave = false;
      throw StateError('Synthetic encrypted write failure');
    }
    await saveGate?.future;
  }

  @override
  Future<void> flush(String chatId) async {}
  @override
  void activateDirective(String chatId, String directive) {
    armed = directive.trim().isNotEmpty;
  }

  @override
  void setPromptPreparer(
    String chatId,
    Future<String> Function(String)? prepare,
  ) {
    preparer = prepare;
  }

  @override
  void setPromptDeliveryObserver(
    String chatId,
    void Function(String, bool)? observer,
  ) {}
  @override
  Future<SparkChatSendResult> sendOnce(
    String chatId,
    String text, {
    required String requestId,
  }) async {
    sends++;
    sentBodies.add(text);
    final result = nextResult;
    nextResult = null;
    return result ??
        SparkChatSendResult(SparkSendOutcome.uncertain, sentText: text);
  }
}
