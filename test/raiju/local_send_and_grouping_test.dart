import 'dart:async';

import 'package:raiju_mobile/companion_controller.dart';
import 'package:raiju_mobile/features/channels/channel.dart';
import 'package:raiju_mobile/features/channels/channel_detail_page.dart';
import 'package:raiju_mobile/features/channels/local_message_send_animation_provider.dart';
import 'package:raiju_mobile/features/channels/local_message_send_transition.dart';
import 'package:raiju_mobile/features/channels/send_message_provider.dart';
import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/raiju/companion_provider.dart';
import 'package:raiju_mobile/shared/theme/theme.dart';
import 'package:raiju_mobile/storage/chat_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    // Timeline providers create Spark state, but this fixture has no native engine.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('raiju/spark/methods'),
      (call) async {
        expect(call.method, 'stop');
        return null;
      },
    );
  });

  testWidgets(
    'confirmed local row keeps its send marker without moving detached reader',
    (tester) async {
      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final initialMessages = [
        for (var index = 0; index < 39; index++)
          ChatMessage(
            id: 'answer-$index',
            role: MessageRole.assistant,
            text: 'Existing answer $index',
          ),
        ChatMessage(
          id: 'answer-final',
          role: MessageRole.assistant,
          text: List.filled(20, 'Tall final answer').join('\n'),
        ),
      ];
      final fixture = await _Fixture.live(messages: initialMessages);
      addTearDown(fixture.dispose);
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();

      final messageList = find.byKey(const ValueKey('channel-message-list'));
      // The newest row is deliberately taller than the first drag. Move past
      // it completely so this exercises a genuinely detached reader.
      await tester.drag(messageList, const Offset(0, 300));
      await tester.pumpAndSettle();
      await tester.drag(messageList, const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('channel-jump-to-latest')),
        findsOneWidget,
      );
      final reference = find
          .byWidgetPredicate((widget) {
            final key = widget.key;
            return key is ValueKey<String> &&
                key.value.startsWith('message-row-answer-');
          })
          .evaluate()
          .map((element) => find.byKey(element.widget.key!))
          .firstWhere(
            (finder) =>
                tester.getTopLeft(finder).dy > 150 &&
                tester.getBottomLeft(finder).dy < 450,
          );
      final referenceY = tester.getTopLeft(reference).dy;

      await fixture.container.read(sendMessageProvider)(
        channelId: fixture.id,
        content: 'new prompt',
      );
      fixture.client.emit(
        HarnessSnapshot(
          phase: ConnectionPhase.live,
          title: 'Test chat',
          readOnly: false,
          messages: [
            ...initialMessages,
            ChatMessage(
              id: 'remote-prompt-42',
              role: MessageRole.user,
              text: 'new prompt',
              author: 'raiju',
              timestamp: DateTime.now(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        fixture.container.read(localMessageSendAnimationProvider(fixture.id)),
        contains('remote-prompt-42'),
      );
      expect(tester.getTopLeft(reference).dy, closeTo(referenceY, 1));
      expect(
        find.byKey(const ValueKey('channel-jump-to-latest')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('channel-jump-to-latest')));
      await tester.pumpAndSettle();
      final transition = tester.widget<LocalMessageSendTransition>(
        find.byKey(const ValueKey('channel-message-send-remote-prompt-42')),
      );
      expect(transition.animate, isTrue);
      expect(
        find.byKey(const ValueKey('message-row-remote-prompt-42')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('channel-jump-to-latest')),
        findsNothing,
      );
    },
  );

  test(
    'restored, other-author, failed, and disconnected sends are never marked',
    () async {
      final oldTimestamp = DateTime.utc(2020);
      final fixture = await _Fixture.live(
        messages: [
          ChatMessage(
            id: 'restored-old',
            role: MessageRole.user,
            text: 'same prompt',
            timestamp: oldTimestamp,
          ),
        ],
      );
      addTearDown(fixture.dispose);

      await fixture.container.read(sendMessageProvider)(
        channelId: fixture.id,
        content: 'same prompt',
      );
      fixture.client.emit(
        HarnessSnapshot(
          phase: ConnectionPhase.live,
          title: 'Test chat',
          readOnly: false,
          messages: [
            ChatMessage(
              id: 'restored-old',
              role: MessageRole.user,
              text: 'same prompt',
              timestamp: oldTimestamp,
            ),
            ChatMessage(
              id: 'other-guest',
              role: MessageRole.user,
              text: 'same prompt',
              author: 'Alice',
              timestamp: DateTime.now(),
            ),
            ChatMessage(
              id: 'unknown-author',
              role: MessageRole.user,
              text: 'same prompt',
              timestamp: DateTime.now(),
            ),
          ],
        ),
      );
      expect(
        fixture.container.read(localMessageSendAnimationProvider(fixture.id)),
        isEmpty,
      );

      fixture.client.failSend = true;
      await expectLater(
        fixture.container.read(sendMessageProvider)(
          channelId: fixture.id,
          content: 'failed prompt',
        ),
        throwsA(isA<HarnessException>()),
      );
      fixture.client.failSend = false;
      fixture.client.emit(
        HarnessSnapshot(
          phase: ConnectionPhase.live,
          title: 'Test chat',
          readOnly: false,
          messages: [
            ChatMessage(
              id: 'arrived-after-failure',
              role: MessageRole.user,
              text: 'failed prompt',
              author: 'raiju',
              timestamp: DateTime.now(),
            ),
          ],
        ),
      );
      expect(
        fixture.container.read(localMessageSendAnimationProvider(fixture.id)),
        isEmpty,
      );

      await fixture.container.read(sendMessageProvider)(
        channelId: fixture.id,
        content: 'disconnect prompt',
      );
      await fixture.controller.disconnect(fixture.id);
      fixture.client.emit(
        HarnessSnapshot(
          phase: ConnectionPhase.live,
          title: 'Test chat',
          readOnly: false,
          messages: [
            ChatMessage(
              id: 'arrived-after-disconnect',
              role: MessageRole.user,
              text: 'disconnect prompt',
              author: 'raiju',
              timestamp: DateTime.now(),
            ),
          ],
        ),
      );
      expect(
        fixture.container.read(localMessageSendAnimationProvider(fixture.id)),
        isEmpty,
      );
    },
  );

  testWidgets('adjacent role peers with distinct authors retain both headers', (
    tester,
  ) async {
    final fixture = await _Fixture.live(
      messages: const [
        ChatMessage(
          id: 'tool-a',
          role: MessageRole.tool,
          text: 'first result',
          author: 'Search',
        ),
        ChatMessage(
          id: 'tool-b',
          role: MessageRole.tool,
          text: 'second result',
          author: 'Compiler',
        ),
      ],
    );
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.app());
    await tester.pump();

    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Compiler'), findsOneWidget);
  });
}

class _Fixture {
  _Fixture(this.controller, this.client, this.id, this.container);

  final CompanionController controller;
  final _Client client;
  final String id;
  final ProviderContainer container;

  static Future<_Fixture> live({required List<ChatMessage> messages}) async {
    final client = _Client(messages);
    final controller = CompanionController(
      clientFactory: () => client,
      store: _Store(),
      writeDebounce: Duration.zero,
    );
    final thread = await controller.join('synthetic-send-capability');
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        savedPrefsProvider.overrideWithValue(prefs),
        companionControllerProvider.overrideWith((ref) => controller),
      ],
    );
    return _Fixture(controller, client, thread.id, container);
  }

  Widget app() => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: AppTheme.light(),
      home: ChannelDetailPage(
        channel: Channel(
          id: id,
          name: 'Test chat',
          channelType: 'dm',
          visibility: 'private',
          description: '',
          createdBy: 'local',
          createdAt: DateTime.utc(2026),
          memberCount: 2,
          isMember: true,
        ),
      ),
    ),
  );

  Future<void> dispose() async {
    container.dispose();
    controller.dispose();
  }
}

class _Client implements HarnessClient {
  _Client(List<ChatMessage> messages)
    : _snapshot = HarnessSnapshot(
        phase: ConnectionPhase.live,
        title: 'Test chat',
        readOnly: false,
        messages: messages,
      );

  HarnessSnapshot _snapshot;
  final _changes = StreamController<HarnessSnapshot>.broadcast(sync: true);
  bool failSend = false;

  void emit(HarnessSnapshot snapshot) {
    _snapshot = snapshot;
    _changes.add(snapshot);
  }

  @override
  HarnessSnapshot get snapshot => _snapshot;

  @override
  Stream<HarnessSnapshot> get changes => _changes.stream;

  @override
  Future<void> connect(String input, {String displayName = 'raiju'}) async {}

  @override
  Future<void> sendPrompt(String text) async {
    if (failSend) throw const HarnessException('synthetic send failure');
  }

  @override
  Future<void> abort() async {}

  @override
  Future<void> respond(int requestId, String? value) async {}

  @override
  Future<void> disconnect() async {
    emit(const HarnessSnapshot(phase: ConnectionPhase.disconnected));
  }

  @override
  Future<void> dispose() async => _changes.close();
}

class _Store implements ChatStore {
  @override
  Future<List<StoredChat>> load() async => const [];

  @override
  Future<void> save(List<StoredChat> chats) async {}
}
