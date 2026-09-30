import 'package:buzz/harness/harness.dart';
import 'package:buzz/spark/context.dart';
import 'package:buzz/storage/voice_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'source prose excludes rendered thinking/tools and orders anchored voice turns',
    () {
      const messages = [
        ChatMessage(
          id: 'first',
          role: MessageRole.user,
          text: 'display text',
          prose: 'typed first',
          source: {'content': 'typed first'},
        ),
        ChatMessage(
          id: 'tool',
          role: MessageRole.tool,
          text: 'dangerous tool output',
          source: {'content': 'dangerous tool output'},
        ),
        ChatMessage(
          id: 'later',
          role: MessageRole.assistant,
          text: 'thinking and rendered output',
          prose: 'actual answer',
          source: {
            'content': [
              {'type': 'thinking', 'thinking': 'private'},
              {'type': 'text', 'text': 'actual answer'},
              {'type': 'toolCall', 'name': 'exec'},
            ],
          },
        ),
      ];
      const turns = [
        VoiceTurn(
          id: 'voice1',
          sequence: 1,
          origin: VoiceTurnOrigin.user,
          text: 'spoken between',
          precedingHostEntryId: 'first',
        ),
      ];
      expect(
        sparkConversationContext(messages, turns, characterBudget: 1000),
        'User: typed first\nUser: spoken between\nAssistant: actual answer',
      );
    },
  );

  test('a known source with no prose never falls back to display text', () {
    const messages = [
      ChatMessage(
        id: 'tool-heavy',
        role: MessageRole.assistant,
        text: 'rendered generated status',
        source: {
          'content': [
            {'type': 'thinking', 'thinking': 'private'},
          ],
        },
      ),
    ];
    expect(
      sparkConversationContext(messages, const [], characterBudget: 1000),
      isEmpty,
    );
  });

  test(
    'confirmed typed echo keeps typed suffix without duplicating durable voice',
    () {
      const turns = [
        VoiceTurn(
          id: 'voice',
          sequence: 1,
          origin: VoiceTurnOrigin.user,
          text: 'spoken',
          hostEntryId: 'echo',
          typedEcho: true,
        ),
      ];
      const messages = [
        ChatMessage(
          id: 'echo',
          role: MessageRole.user,
          text: 'User: spoken\nactually type this',
          prose: 'User: spoken\nactually type this',
          source: {'content': 'User: spoken\nactually type this'},
        ),
      ];
      expect(
        sparkVoiceEchoRemainder(messages.single.prose!, turns),
        'actually type this',
      );
      expect(
        sparkConversationContext(messages, turns, characterBudget: 1000),
        'User: spoken\nUser: actually type this',
      );
    },
  );
  test(
    'evicted host anchor remains before recent history under a tight budget',
    () {
      const turns = [
        VoiceTurn(
          id: 'old',
          sequence: 1,
          origin: VoiceTurnOrigin.user,
          text: 'old voice',
          precedingHostEntryId: 'evicted',
        ),
      ];
      const recent = [
        ChatMessage(
          id: 'current',
          role: MessageRole.user,
          text: 'new',
          prose: 'new',
          source: {'content': 'new'},
        ),
      ];
      expect(
        sparkConversationContext(recent, turns, characterBudget: 10),
        'User: new',
      );
      expect(
        sparkConversationContext(recent, turns, characterBudget: 100),
        'User: old voice\nUser: new',
      );
    },
  );

  test(
    'cached source omission preserves typed suffix from durable echo metadata',
    () {
      const turns = [
        VoiceTurn(
          id: 'voice',
          sequence: 1,
          origin: VoiceTurnOrigin.typedUser,
          text: 'spoken',
          hostEntryId: 'echo',
          typedEcho: true,
          echoRemainder: 'manual suffix',
        ),
      ];
      const messages = [
        ChatMessage(
          id: 'echo',
          role: MessageRole.user,
          origin: ChatMessageOrigin.collabUser,
          text: 'source omitted',
        ),
      ];
      expect(
        sparkConversationContext(messages, turns, characterBudget: 1000),
        'User: spoken\nUser: manual suffix',
      );
    },
  );
  test(
    'incremental package retains equal human events and only intervening dialogue',
    () {
      const turns = [
        VoiceTurn(
          id: 'lead',
          sequence: 1,
          origin: VoiceTurnOrigin.spark,
          text: 'welcome',
        ),
        VoiceTurn(
          id: 'u1',
          sequence: 2,
          origin: VoiceTurnOrigin.user,
          text: 'same',
        ),
        VoiceTurn(
          id: 'clarify',
          sequence: 3,
          origin: VoiceTurnOrigin.spark,
          text: 'Which scope?',
        ),
        VoiceTurn(
          id: 'u2',
          sequence: 4,
          origin: VoiceTurnOrigin.user,
          text: 'same',
        ),
        VoiceTurn(
          id: 'filler',
          sequence: 5,
          origin: VoiceTurnOrigin.spark,
          text: 'Sending now',
          routingPurpose: VoiceTurnPurpose.acknowledgement,
        ),
        VoiceTurn(
          id: 'old',
          sequence: 6,
          origin: VoiceTurnOrigin.user,
          text: 'already sent',
          delivery: VoiceDelivery.delivered,
        ),
        VoiceTurn(
          id: 'retell',
          sequence: 7,
          origin: VoiceTurnOrigin.spark,
          text: 'Previous answer',
          routingPurpose: VoiceTurnPurpose.resultFeedback,
        ),
        VoiceTurn(
          id: 'u3',
          sequence: 8,
          origin: VoiceTurnOrigin.user,
          text: 'Next question',
        ),
      ];
      final package = sparkRoutingPackage(turns, ' same ');
      expect(
        package.body,
        'User: same\nVoice Assistant Spark: Which scope?\n'
        'User: same\nUser: Next question',
      );
      expect(package.turns.map((turn) => turn.id), [
        'u1',
        'clarify',
        'u2',
        'u3',
      ]);
      expect(package.overlapTurnId, 'u1');
      expect(
        sparkRoutingPackage(turns, 'different').body,
        '${package.body}\ndifferent',
      );
      expect(sparkRoutingPackage(turns, '').body, package.body);
      expect(sparkRoutingPackage(const [], '').body, '');
    },
  );

  test(
    'divergent generated request does not turn trailing Spark into dialogue',
    () {
      const turns = [
        VoiceTurn(
          id: 'user',
          sequence: 1,
          origin: VoiceTurnOrigin.user,
          text: 'Inspect the config',
        ),
        VoiceTurn(
          id: 'ack',
          sequence: 2,
          origin: VoiceTurnOrigin.spark,
          text: 'I will inspect it',
        ),
      ];
      final package = sparkRoutingPackage(turns, 'Inspect only the syntax');
      expect(package.body, 'User: Inspect the config\nInspect only the syntax');
      expect(package.turns.map((turn) => turn.id), ['user']);
    },
  );
  test('synthetic request aliases do not duplicate startup echo or source', () {
    const turns = [
      VoiceTurn(
        id: 'source',
        sequence: 1,
        origin: VoiceTurnOrigin.user,
        text: 'Check the file',
        hostEntryId: 'echo',
      ),
      VoiceTurn(
        id: 'request',
        sequence: 2,
        origin: VoiceTurnOrigin.typedUser,
        text: '',
        hostEntryId: 'echo',
        routingPurpose: VoiceTurnPurpose.request,
        routingPackageText: 'Check the file',
        routingRequestText: 'Check the file',
        routingSourceTurnId: 'source',
      ),
    ];
    const messages = [
      ChatMessage(
        id: 'echo',
        role: MessageRole.user,
        text: 'Check the file',
        prose: 'Check the file',
        source: {'content': 'Check the file'},
      ),
    ];
    expect(
      sparkConversationContext(messages, turns, characterBudget: 1000),
      'User: Check the file',
    );
    expect(sparkVoiceEchoRemainder('Check the file', turns), '');
  });
  test('late divergent context is not an executable overlap', () {
    const late = [
      VoiceTurn(
        id: 'late',
        sequence: 1,
        origin: VoiceTurnOrigin.user,
        text: 'repeat',
        routingPurpose: VoiceTurnPurpose.lateContext,
      ),
    ];
    expect(sparkRoutingPackage(late, '').body, '');
    expect(
      sparkRoutingPackage(late, 'repeat').body,
      'User (historical late context; not a new request): repeat\nrepeat',
    );
  });

  test(
    'VoiceTurn codec round trips provenance and rejects invalid legacy data',
    () {
      const request = VoiceTurn(
        id: 'reservation',
        sequence: 3,
        origin: VoiceTurnOrigin.typedUser,
        text: 'Do work',
        delivery: VoiceDelivery.uncertain,
        routingPurpose: VoiceTurnPurpose.request,
        routingRequestId: 'd1',
        routingRequestText: 'Do work',
        routingPackageText: 'Do work',
        routingAwaitingSource: true,
      );
      expect(VoiceTurn.fromJson(request.toJson()).toJson(), request.toJson());
      final legacy = Map<String, dynamic>.from(request.toJson())
        ..remove('routingPurpose')
        ..remove('routingRequestId')
        ..remove('routingRequestText')
        ..remove('routingPackageText')
        ..remove('routingSourceTurnId')
        ..remove('routingAwaitingSource')
        ..remove('typedEcho');
      expect(
        VoiceTurn.fromJson(legacy).routingPurpose,
        VoiceTurnPurpose.dialogue,
      );
      expect(VoiceTurn.fromJson(legacy).typedEcho, false);
      expect(
        () => VoiceTurn.fromJson({...legacy, 'sequence': -1}),
        throwsFormatException,
      );
    },
  );
}
