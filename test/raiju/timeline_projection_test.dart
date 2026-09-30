import 'package:buzz/features/channels/timeline_message.dart';
import 'package:buzz/features/channels/date_formatters.dart';
import 'package:buzz/harness/harness.dart';
import 'package:buzz/raiju/timeline_projection.dart';
import 'package:buzz/spark/models.dart';
import 'package:buzz/spark/context.dart';
import 'package:buzz/storage/voice_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const turns = [
    VoiceTurn(
      id: 'v1',
      sequence: 1,
      origin: VoiceTurnOrigin.user,
      text: 'spoken',
      precedingRenderedEntryId: 'remote',
    ),
    VoiceTurn(
      id: 'v2',
      sequence: 2,
      origin: VoiceTurnOrigin.spark,
      text: 'Spark reply',
      precedingRenderedEntryId: 'remote',
    ),
  ];

  test(
    'projects four distinct origins while preserving ordinary typed prompts',
    () {
      final messages = projectTimelineMessages(const [
        ChatMessage(id: 'typed', role: MessageRole.user, text: 'typed'),
        ChatMessage(id: 'remote', role: MessageRole.assistant, text: 'remote'),
      ], voiceTurns: turns);
      expect(messages.map((message) => message.content), [
        'typed',
        'remote',
        'spoken',
        'Spark reply',
      ]);
      expect(messages.map((message) => message.presentationRole), [
        TimelinePresentationRole.local,
        TimelinePresentationRole.assistant,
        TimelinePresentationRole.recognizedSpeech,
        TimelinePresentationRole.spark,
      ]);
    },
  );

  test(
    'typed Spark input uses local user visual origin, not microphone speech',
    () {
      final messages = projectTimelineMessages(
        const [],
        voiceTurns: const [
          VoiceTurn(
            id: 'typed',
            sequence: 1,
            origin: VoiceTurnOrigin.typedUser,
            text: 'Typed to Spark',
          ),
          VoiceTurn(
            id: 'spoken',
            sequence: 2,
            origin: VoiceTurnOrigin.user,
            text: 'Spoken to Spark',
          ),
        ],
      );
      expect(messages.map((message) => message.presentationRole), [
        TimelinePresentationRole.local,
        TimelinePresentationRole.recognizedSpeech,
      ]);
      expect(messages.map((message) => message.presentationAuthor), [
        'You',
        'You · voice',
      ]);
    },
  );

  test('collapses only serialized dialogue within a delegated batch echo', () {
    final messages = projectTimelineMessages(
      const [
        ChatMessage(
          id: 'typed',
          role: MessageRole.user,
          text: 'ordinary prompt',
          source: {'type': 'custom_message', 'customType': 'collab-prompt'},
        ),
        ChatMessage(
          id: 'batch',
          role: MessageRole.user,
          text:
              'User: spoken\nVoice Assistant Spark: Spark reply\nextra request',
          source: {
            'type': 'custom_message',
            'customType': 'collab-prompt',
            'content':
                'User: spoken\nVoice Assistant Spark: Spark reply\nextra request',
          },
        ),
        ChatMessage(id: 'answer', role: MessageRole.assistant, text: 'remote'),
      ],
      voiceTurns: const [
        VoiceTurn(
          id: 'v1',
          sequence: 1,
          origin: VoiceTurnOrigin.user,
          text: 'spoken',
          delivery: VoiceDelivery.delivered,
          hostEntryId: 'batch',
        ),
        VoiceTurn(
          id: 'v2',
          sequence: 2,
          origin: VoiceTurnOrigin.spark,
          text: 'Spark reply',
          delivery: VoiceDelivery.delivered,
          hostEntryId: 'batch',
        ),
      ],
    );
    expect(messages.map((message) => message.content), [
      'ordinary prompt',
      'spoken',
      'Spark reply',
      'extra request',
      'remote',
    ]);
    expect(messages.map((message) => message.id), [
      'typed',
      'spark:v1',
      'spark:v2',
      'batch',
      'answer',
    ]);
    expect(messages[3].presentationRole, TimelinePresentationRole.spark);
  });

  test(
    'typed composer echo keeps typed suffix and hides only matching voice prefix',
    () {
      final projected = projectTimelineMessages(
        const [
          ChatMessage(
            id: 'typed',
            role: MessageRole.user,
            text:
                'User: spoken\nVoice Assistant Spark: Spark reply\nTyped suffix',
            source: {
              'type': 'custom_message',
              'customType': 'collab-prompt',
              'content':
                  'User: spoken\nVoice Assistant Spark: Spark reply\nTyped suffix',
            },
          ),
        ],
        voiceTurns: const [
          VoiceTurn(
            id: 'v1',
            sequence: 1,
            origin: VoiceTurnOrigin.user,
            text: 'spoken',
            delivery: VoiceDelivery.delivered,
            hostEntryId: 'typed',
            typedEcho: true,
          ),
          VoiceTurn(
            id: 'v2',
            sequence: 2,
            origin: VoiceTurnOrigin.spark,
            text: 'Spark reply',
            delivery: VoiceDelivery.delivered,
            hostEntryId: 'typed',
            typedEcho: true,
          ),
        ],
      );
      expect(projected.map((message) => message.content), [
        'spoken',
        'Spark reply',
        'Typed suffix',
      ]);
      expect(projected.last.presentationRole, TimelinePresentationRole.local);
    },
  );
  test(
    'exact echoed dialogue without suffix collapses the whole host bubble',
    () {
      final projected = projectTimelineMessages(
        const [
          ChatMessage(
            id: 'echo',
            role: MessageRole.user,
            text: 'User: spoken',
            source: {
              'type': 'custom_message',
              'customType': 'collab-prompt',
              'content': 'User: spoken',
            },
          ),
        ],
        voiceTurns: const [
          VoiceTurn(
            id: 'v',
            sequence: 1,
            origin: VoiceTurnOrigin.user,
            text: 'spoken',
            delivery: VoiceDelivery.delivered,
            hostEntryId: 'echo',
          ),
        ],
      );
      expect(projected.map((message) => message.content), ['spoken']);
    },
  );

  test(
    'mismatched anchored echo stays visible rather than collapsing an ordinary prompt',
    () {
      final projected = projectTimelineMessages(
        const [
          ChatMessage(
            id: 'echo',
            role: MessageRole.user,
            text: 'Unrelated prompt',
            source: {
              'type': 'custom_message',
              'customType': 'collab-prompt',
              'content': 'Unrelated prompt',
            },
          ),
        ],
        voiceTurns: const [
          VoiceTurn(
            id: 'v',
            sequence: 1,
            origin: VoiceTurnOrigin.user,
            text: 'spoken',
            hostEntryId: 'echo',
          ),
        ],
      );
      expect(projected.map((message) => message.content), [
        'spoken',
        'Unrelated prompt',
      ]);
    },
  );

  test('source-omitted cached collab echo retains typed suffix once', () {
    final projected = projectTimelineMessages(
      const [
        ChatMessage(
          id: 'cached',
          role: MessageRole.user,
          origin: ChatMessageOrigin.collabUser,
          text: 'User: spoken\nTyped after voice',
          prose: 'User: spoken\nTyped after voice',
        ),
      ],
      voiceTurns: const [
        VoiceTurn(
          id: 'v',
          sequence: 1,
          origin: VoiceTurnOrigin.user,
          text: 'spoken',
          hostEntryId: 'cached',
          typedEcho: true,
        ),
      ],
    );
    expect(projected.map((message) => message.content), [
      'spoken',
      'Typed after voice',
    ]);
  });

  test(
    'durable echo remainder survives omitted source and truncated prefix',
    () {
      final spoken = 'x' * 21000;
      final projected = projectTimelineMessages(
        [
          ChatMessage(
            id: 'cached',
            role: MessageRole.user,
            origin: ChatMessageOrigin.collabUser,
            text: 'User: $spoken'.substring(0, 20000),
          ),
        ],
        voiceTurns: [
          VoiceTurn(
            id: 'v',
            sequence: 1,
            origin: VoiceTurnOrigin.user,
            text: spoken,
            delivery: VoiceDelivery.delivered,
            hostEntryId: 'cached',
            typedEcho: true,
            echoRemainder: 'Typed suffix survives',
          ),
        ],
      );
      expect(projected.map((message) => message.content), [
        spoken,
        'Typed suffix survives',
      ]);
    },
  );

  test('clipped cached echo without exact remainder remains visible', () {
    final spoken = 'x' * 21000;
    final snippet = 'User: $spoken'.substring(0, 20000);
    final projected = projectTimelineMessages(
      [
        ChatMessage(
          id: 'cached',
          role: MessageRole.user,
          origin: ChatMessageOrigin.collabUser,
          text: snippet,
        ),
      ],
      voiceTurns: [
        VoiceTurn(
          id: 'v',
          sequence: 1,
          origin: VoiceTurnOrigin.user,
          text: spoken,
          delivery: VoiceDelivery.delivered,
          hostEntryId: 'cached',
        ),
      ],
    );
    expect(projected.map((message) => message.content), [spoken, snippet]);
  });

  test(
    'persisted preceding host anchor retains order after later host arrivals',
    () {
      final projected = projectTimelineMessages(
        const [
          ChatMessage(id: 'earlier', role: MessageRole.user, text: 'typed'),
          ChatMessage(id: 'later', role: MessageRole.assistant, text: 'remote'),
        ],
        voiceTurns: const [
          VoiceTurn(
            id: 'spoken',
            sequence: 3,
            origin: VoiceTurnOrigin.user,
            text: 'spoken',
            precedingHostEntryId: 'earlier',
          ),
        ],
      );
      expect(projected.map((message) => message.content), [
        'typed',
        'spoken',
        'remote',
      ]);
    },
  );
  test('evicted host predecessor places old voice before cached window', () {
    final projected = projectTimelineMessages(
      [
        ChatMessage(
          id: 'h201',
          role: MessageRole.user,
          text: 'cached oldest',
          timestamp: DateTime.utc(2024),
        ),
        ChatMessage(
          id: 'h400',
          role: MessageRole.user,
          text: 'User: old voice',
          source: {
            'type': 'custom_message',
            'customType': 'collab-prompt',
            'content': 'User: old voice',
          },
        ),
      ],
      voiceTurns: const [
        VoiceTurn(
          id: 'old',
          sequence: 1,
          origin: VoiceTurnOrigin.user,
          text: 'old voice',
          precedingHostEntryId: 'h1',
          precedingRenderedEntryId: 'h1',
          hostEntryId: 'h400',
        ),
      ],
    );
    expect(projected.map((message) => message.content), [
      'old voice',
      'cached oldest',
    ]);
    expect(projected.first.createdAt, lessThan(projected.last.createdAt));
  });

  test(
    'rendered predecessor orders voice when raw host anchor is not rendered',
    () {
      final projected = projectTimelineMessages(
        const [
          ChatMessage(
            id: 'h201',
            role: MessageRole.user,
            text: 'cached oldest',
          ),
          ChatMessage(
            id: 'h400',
            role: MessageRole.assistant,
            text: 'cached newest',
          ),
        ],
        voiceTurns: const [
          VoiceTurn(
            id: 'new',
            sequence: 10,
            origin: VoiceTurnOrigin.spark,
            text: 'new voice',
            precedingHostEntryId: 'raw-tool-id',
            precedingRenderedEntryId: 'h400',
          ),
        ],
      );
      expect(projected.map((message) => message.content), [
        'cached oldest',
        'cached newest',
        'new voice',
      ]);
    },
  );

  test('internal empty delegation boundary does not produce a chat bubble', () {
    final projected = projectTimelineMessages(
      const [],
      voiceTurns: const [
        VoiceTurn(
          id: 'delegation:chat:event',
          sequence: 4,
          origin: VoiceTurnOrigin.spark,
          text: '',
        ),
      ],
    );
    expect(projected, isEmpty);
  });

  test(
    'generated request has user-derived attribution and exact echo collapse',
    () {
      const echo = ChatMessage(
        id: 'echo',
        role: MessageRole.user,
        text: 'User: first\nNext work',
        prose: 'User: first\nNext work',
        source: {
          'customType': 'collab-prompt',
          'content': 'User: first\nNext work',
        },
      );
      const source = VoiceTurn(
        id: 'voice',
        sequence: 1,
        origin: VoiceTurnOrigin.user,
        text: 'first',
        hostEntryId: 'echo',
        delivery: VoiceDelivery.delivered,
      );
      const request = VoiceTurn(
        id: 'request',
        sequence: 2,
        origin: VoiceTurnOrigin.typedUser,
        text: 'Next work',
        routingPurpose: VoiceTurnPurpose.request,
        routingRequestId: 'd',
        routingPackageText: 'User: first\nNext work',
        hostEntryId: 'echo',
        delivery: VoiceDelivery.delivered,
      );
      final projected = projectTimelineMessages(
        const [echo],
        voiceTurns: const [source, request],
      );
      expect(projected.map((item) => item.content), ['first', 'Next work']);
      expect(projected.last.presentationRole, TimelinePresentationRole.local);
      expect(projected.last.presentationAuthor, 'You · Spark request');
      final aliased = projectTimelineMessages(
        const [echo],
        voiceTurns: const [
          source,
          VoiceTurn(
            id: 'request',
            sequence: 2,
            origin: VoiceTurnOrigin.typedUser,
            text: '',
            routingPurpose: VoiceTurnPurpose.request,
            routingRequestId: 'd',
            routingSourceTurnId: 'voice',
            routingPackageText: 'User: first\nNext work',
            hostEntryId: 'echo',
            delivery: VoiceDelivery.delivered,
          ),
        ],
      );
      expect(aliased.map((item) => item.content), ['first']);
      expect(
        projectTimelineMessages(
          const [
            ChatMessage(
              id: 'echo',
              role: MessageRole.user,
              text: 'Unrelated',
              source: {'customType': 'collab-prompt', 'content': 'Unrelated'},
            ),
          ],
          voiceTurns: const [source, request],
        ).map((item) => item.content),
        ['first', 'Next work', 'Unrelated'],
      );
    },
  );
  test(
    'omitted acknowledgement stays after echoed user despite older anchor',
    () {
      final projected = projectTimelineMessages(
        const [
          ChatMessage(id: 'older', role: MessageRole.assistant, text: 'older'),
          ChatMessage(id: 'newer', role: MessageRole.assistant, text: 'newer'),
          ChatMessage(
            id: 'echo',
            role: MessageRole.user,
            text: 'User: Find settings',
            prose: 'User: Find settings',
            source: {
              'customType': 'collab-prompt',
              'content': 'User: Find settings',
            },
          ),
          ChatMessage(
            id: 'answer',
            role: MessageRole.assistant,
            text: 'Found it',
          ),
        ],
        voiceTurns: const [
          VoiceTurn(
            id: 'user',
            sequence: 1,
            origin: VoiceTurnOrigin.user,
            text: 'Find settings',
            delivery: VoiceDelivery.delivered,
            hostEntryId: 'echo',
            precedingHostEntryId: 'newer',
          ),
          VoiceTurn(
            id: 'ack',
            sequence: 2,
            origin: VoiceTurnOrigin.spark,
            text: 'I will search',
            precedingHostEntryId: 'older',
            routingPurpose: VoiceTurnPurpose.acknowledgement,
          ),
          VoiceTurn(
            id: 'retell',
            sequence: 3,
            origin: VoiceTurnOrigin.spark,
            text: 'I found it',
            precedingHostEntryId: 'answer',
            routingPurpose: VoiceTurnPurpose.resultFeedback,
          ),
          VoiceTurn(
            id: 'next',
            sequence: 4,
            origin: VoiceTurnOrigin.user,
            text: 'Now check types',
            precedingHostEntryId: 'answer',
          ),
        ],
      );
      expect(projected.map((message) => message.content), [
        'older',
        'newer',
        'Find settings',
        'I will search',
        'Found it',
        'I found it',
        'Now check types',
      ]);
      expect(
        sparkRoutingPackage(const [
          VoiceTurn(
            id: 'user',
            sequence: 1,
            origin: VoiceTurnOrigin.user,
            text: 'Find settings',
            delivery: VoiceDelivery.delivered,
          ),
          VoiceTurn(
            id: 'ack',
            sequence: 2,
            origin: VoiceTurnOrigin.spark,
            text: 'I will search',
            routingPurpose: VoiceTurnPurpose.acknowledgement,
          ),
          VoiceTurn(
            id: 'retell',
            sequence: 3,
            origin: VoiceTurnOrigin.spark,
            text: 'I found it',
            routingPurpose: VoiceTurnPurpose.resultFeedback,
          ),
          VoiceTurn(
            id: 'next',
            sequence: 4,
            origin: VoiceTurnOrigin.user,
            text: 'Now check types',
          ),
        ], '').body,
        'User: Now check types',
      );
    },
  );
  test(
    'tool preference covers standalone and mixed inline tools only in bound voice chat',
    () {
      const remote = [
        ChatMessage(
          id: 'assistant',
          role: MessageRole.assistant,
          text: 'Result\nUsing read…',
          prose: 'Result',
          thinking: 'private',
          source: {'role': 'assistant'},
        ),
        ChatMessage(
          id: 'cached-assistant',
          role: MessageRole.assistant,
          origin: ChatMessageOrigin.remoteAssistant,
          text: 'Cached answer\nUsing huge_tool…',
          prose: 'Cached answer',
        ),
        ChatMessage(id: 'tool', role: MessageRole.tool, text: 'read output'),
      ];
      final otherChat = projectTimelineMessages(
        remote,
        toolVisibility: SparkToolVisibility.hideInVoice,
      );
      expect(otherChat, hasLength(3));
      expect(otherChat.first.content, 'Result\nUsing read…');
      final boundChat = projectTimelineMessages(
        remote,
        toolVisibility: SparkToolVisibility.hideInVoice,
        isVoiceBoundAndActive: true,
      );
      expect(boundChat, hasLength(2));
      expect(boundChat.first.content, 'Result');
      expect(boundChat.first.thinking, '');
      expect(
        projectTimelineMessages(
          remote,
          hideThinking: false,
          toolVisibility: SparkToolVisibility.hideInVoice,
          isVoiceBoundAndActive: true,
        ).first.thinking,
        'private',
      );
      expect(boundChat.last.content, 'Cached answer');
      final hiddenEverywhere = projectTimelineMessages(
        remote,
        toolVisibility: SparkToolVisibility.hide,
      );
      expect(hiddenEverywhere, hasLength(2));
      final shownInVoice = projectTimelineMessages(
        remote,
        toolVisibility: SparkToolVisibility.show,
        isVoiceBoundAndActive: true,
      );
      expect(shownInVoice, hasLength(3));
    },
  );
  test(
    'new voice event keeps its own persisted clock beside old host history',
    () {
      final captured = DateTime.utc(2026, 9, 29, 18, 42, 31);
      final turn = VoiceTurn.fromJson(
        VoiceTurn(
          id: 'fresh',
          sequence: 1,
          origin: VoiceTurnOrigin.user,
          text: 'spoken now',
          createdAt: captured,
          precedingHostEntryId: 'old',
        ).toJson(),
      );
      final projected = projectTimelineMessages(
        [
          ChatMessage(
            id: 'old',
            role: MessageRole.assistant,
            text: 'old answer',
            timestamp: DateTime.utc(2021),
          ),
        ],
        voiceTurns: [turn],
      );
      expect(projected.map((message) => message.content), [
        'old answer',
        'spoken now',
      ]);
      expect(projected.last.createdAt, projected.first.createdAt);
      expect(
        projected.last.visibleCreatedAt,
        captured.millisecondsSinceEpoch ~/ 1000,
      );
      expect(
        projectTimelineMessages(
          [
            ChatMessage(
              id: 'old',
              role: MessageRole.assistant,
              text: 'old answer',
              timestamp: DateTime.utc(2021),
            ),
          ],
          voiceTurns: [turn],
        ).last.visibleCreatedAt,
        projected.last.visibleCreatedAt,
      );
    },
  );
  test(
    'evicted anchor retains timeline order while voice shows capture time',
    () {
      final captured = DateTime.utc(2026, 9, 29, 12);
      final messages = projectTimelineMessages(
        [
          ChatMessage(
            id: 'retained',
            role: MessageRole.assistant,
            text: 'retained',
            timestamp: DateTime.utc(2021),
          ),
        ],
        voiceTurns: [
          VoiceTurn(
            id: 'evicted',
            sequence: 1,
            origin: VoiceTurnOrigin.user,
            text: 'evicted anchor',
            precedingHostEntryId: 'no longer cached',
            createdAt: captured,
          ),
        ],
      );
      expect(messages.map((message) => message.content), [
        'evicted anchor',
        'retained',
      ]);
      expect(messages.first.createdAt, lessThan(messages.last.createdAt));
      expect(
        messages.first.visibleCreatedAt,
        captured.millisecondsSinceEpoch ~/ 1000,
      );
      expect(
        isSameDay(
          messages.first.visibleCreatedAt,
          messages.last.visibleCreatedAt,
        ),
        isFalse,
      );
      expect(
        formatDayHeading(
          messages.first.visibleCreatedAt,
          now: captured.toLocal(),
        ),
        'Today',
      );
      expect(
        formatDayHeading(
          messages.last.visibleCreatedAt,
          now: captured.toLocal(),
        ),
        isNot('Today'),
      );
    },
  );
}
