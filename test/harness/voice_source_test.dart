import 'package:raiju_mobile/harness/collab_replica.dart';
import 'package:raiju_mobile/harness/voice_directive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('raw mixed source and sequenced agent events survive presentation', () {
    final replica = CollabReplica(endpoint: 'wss://relay.example');
    replica.apply({
      't': 'welcome',
      'proto': 3,
      'header': {'id': 'chat', 'title': 'Chat'},
      'state': {'isStreaming': false},
      'entryCount': 0,
    });
    final entry = {
      'type': 'message',
      'id': 'assistant-1',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'thinking', 'thinking': 'private'},
          {'type': 'text', 'text': 'Public answer'},
          {'type': 'toolCall', 'name': 'read', 'id': 'tool-1'},
        ],
      },
    };
    replica.apply({'t': 'entry', 'entry': entry});
    final message = replica.snapshot.messages.single;
    expect(message.prose, 'Public answer');
    expect(message.text, contains('Using read'));
    expect(message.source, entry['message']);
    expect(replica.snapshot.rawEntries.single, entry);
    replica.apply({
      't': 'event',
      'event': {
        'type': 'message_end',
        'message': {
          'role': 'assistant',
          'stopReason': 'toolUse',
          'content': [
            {'type': 'text', 'text': 'Checking'},
          ],
        },
      },
    });
    replica.apply({
      't': 'event',
      'event': {
        'type': 'agent_end',
        'isTerminal': false,
        'messages': [
          {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'Result'},
            ],
          },
        ],
      },
    });
    final events = replica.snapshot.agentEvents;
    expect(events.map((event) => event.sequence), [1, 2]);
    expect((events.first.event['message'] as Map)['stopReason'], 'toolUse');
    expect(events.last.event['isTerminal'], false);
    expect(events.last.event['messages'], isA<List>());
  });

  test(
    'marker is hidden only in mobile prose and rechecked after compaction',
    () {
      final prompt = VoiceDirective.decorate('User text', 'two models');
      final replica = CollabReplica(endpoint: 'wss://relay.example');
      replica.apply({
        't': 'welcome',
        'proto': 3,
        'header': {'id': 'chat', 'title': 'Chat'},
        'state': {'isStreaming': false},
        'entryCount': 0,
      });
      final entry = {
        'type': 'custom_message',
        'id': 'prompt-1',
        'customType': 'collab-prompt',
        'content': prompt,
        'details': {'from': 'phone'},
        'display': true,
      };
      replica.apply({'t': 'entry', 'entry': entry});
      expect(replica.snapshot.messages.single.text, 'User text');
      expect(replica.snapshot.rawEntries.single['content'], prompt);
      expect(VoiceDirective.isPresent(replica.snapshot.rawEntries), true);
      replica.apply({
        't': 'event',
        'event': {'type': 'auto_compaction_start'},
      });
      expect(VoiceDirective.isPresent(replica.snapshot.rawEntries), true);
      replica.apply({
        't': 'entry',
        'entry': {'type': 'compaction', 'id': 'compact-1'},
      });
      expect(VoiceDirective.isPresent(replica.snapshot.rawEntries), false);
      replica.apply({
        't': 'entry',
        'entry': {
          'type': 'message',
          'id': 'quoted',
          'message': {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': prompt},
            ],
          },
        },
      });
      expect(VoiceDirective.isPresent(replica.snapshot.rawEntries), false);
    },
  );

  test(
    'RPC user history deduplicates directive without trusting other roles',
    () {
      final prompt = VoiceDirective.decorate('User text', 'two models');
      Map<String, Object?> entry(String role, Object content) => {
        'type': 'message',
        'message': {'role': role, 'content': content},
      };
      expect(VoiceDirective.isPresent([entry('user', prompt)]), isTrue);
      expect(
        VoiceDirective.isPresent([
          entry('user', [
            {'type': 'text', 'text': prompt},
          ]),
        ]),
        isTrue,
      );
      for (final role in ['assistant', 'toolResult', 'system']) {
        expect(VoiceDirective.isPresent([entry(role, prompt)]), isFalse);
      }
      expect(
        VoiceDirective.isPresent([
          entry('user', prompt),
          {'type': 'compaction'},
          entry('user', 'New request'),
        ]),
        isFalse,
      );
    },
  );
}
