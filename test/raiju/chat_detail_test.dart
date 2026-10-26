import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:raiju_mobile/companion_controller.dart';
import 'package:raiju_mobile/features/channels/channel.dart';
import 'package:raiju_mobile/features/channels/channel_detail_page.dart';
import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/raiju/timeline_projection.dart';
import 'package:raiju_mobile/raiju/companion_provider.dart';
import 'package:raiju_mobile/storage/chat_store.dart';
import 'package:raiju_mobile/shared/theme/theme.dart';
import 'package:raiju_mobile/spark/spark.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('projects roles, streaming metadata, and one row per message id', () {
    final messages = projectTimelineMessages([
      ChatMessage(
        id: 'local-1',
        role: MessageRole.user,
        text: 'Hello',
        timestamp: DateTime.utc(2026, 1, 1),
      ),
      const ChatMessage(
        id: 'assistant-1',
        role: MessageRole.assistant,
        text: 'partial',
        isStreaming: true,
        thinking: 'Considering the request',
      ),
      const ChatMessage(
        id: 'assistant-1',
        role: MessageRole.assistant,
        text: 'complete',
      ),
      const ChatMessage(
        id: 'tool-1',
        role: MessageRole.tool,
        text: 'Tool result',
        isError: true,
      ),
    ]);

    expect(messages, hasLength(3));
    expect(messages[0].pubkey, 'local');
    expect(messages[0].presentationAuthor, 'You');
    expect(messages[1].content, 'complete');
    expect(messages[1].isStreaming, isFalse);
    expect(messages[2].pubkey, 'tool');
    expect(messages[2].isError, isTrue);
  });
  testWidgets(
    'detail message selects text before opening secondary actions',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final client = _FakeClient(
        const HarnessSnapshot(
          phase: ConnectionPhase.live,
          title: 'Selection chat',
          messages: [
            ChatMessage(
              id: 'select-1',
              role: MessageRole.assistant,
              text: 'select this answer',
            ),
          ],
        ),
      );
      final controller = CompanionController(
        clientFactory: () => client,
        store: _MemoryStore(),
      );
      final thread = await controller.join('synthetic-selection-capability');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            savedPrefsProvider.overrideWithValue(prefs),
            companionControllerProvider.overrideWith((ref) => controller),
            sparkVoiceSessionProvider.overrideWithValue(_FakeVoiceSession()),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: ChannelDetailPage(
              channel: Channel(
                id: thread.id,
                name: thread.title,
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
        ),
      );
      await tester.pumpAndSettle();
      final text = find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText() == 'select this answer',
      );
      final paragraph = tester.renderObject<RenderParagraph>(text);
      final box = paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 6),
          )
          .first;
      final word = paragraph.localToGlobal(box.toRect().center);
      await tester.tapAt(word);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('message-action-surface')),
        findsNothing,
      );
      await tester.longPressAt(word);
      await tester.pumpAndSettle();
      expect(
        paragraph.selections.single.textInside(paragraph.text.toPlainText()),
        'select',
      );
      expect(
        find.byKey(const ValueKey('message-action-surface')),
        findsNothing,
      );
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('message-action-surface')),
        findsOneWidget,
      );
      Navigator.of(
        tester.element(find.byKey(const ValueKey('message-action-surface'))),
      ).pop();
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'real detail renders one streamed row and exposes send, stop, read-only, and questions',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final client = _FakeClient(
        const HarnessSnapshot(
          phase: ConnectionPhase.live,
          title: 'Widget OMP chat',
          model: 'test-model',
          readOnly: false,
          isStreaming: true,
          messages: [
            ChatMessage(
              id: 'stream-1',
              role: MessageRole.assistant,
              text: 'partial',
              isStreaming: true,
            ),
            ChatMessage(
              id: 'stream-1',
              role: MessageRole.assistant,
              text: 'latest partial',
              isStreaming: true,
            ),
          ],
          questions: [
            HarnessQuestion(
              id: 9,
              title: 'Select a host',
              kind: 'select',
              options: [QuestionOption('host A')],
            ),
          ],
        ),
      );
      final controller = CompanionController(
        clientFactory: () => client,
        store: _MemoryStore(),
      );
      final thread = await controller.join('synthetic-widget-capability');
      final channel = Channel(
        id: thread.id,
        name: thread.title,
        channelType: 'dm',
        visibility: 'private',
        description: '',
        createdBy: 'local',
        createdAt: DateTime.utc(2026),
        memberCount: 2,
        isMember: true,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            companionControllerProvider.overrideWith((ref) => controller),
            sparkVoiceSessionProvider.overrideWithValue(_FakeVoiceSession()),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: ChannelDetailPage(channel: channel),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('channel-message-list')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('message-row-stream-1')),
        findsOneWidget,
      );
      expect(find.text('latest partial'), findsOneWidget);
      expect(find.text('partial'), findsNothing);
      expect(find.byKey(const ValueKey('companion-stop')), findsOneWidget);
      expect(find.text('Select a host'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('companion-stop')));
      await tester.tap(
        find.byKey(const ValueKey('companion-question-9-host A')),
      );
      await tester.pump();
      expect(client.abortCalls, 1);
      expect(client.responses, [(9, 'host A')]);
      client.emit(
        const HarnessSnapshot(
          phase: ConnectionPhase.live,
          title: 'Widget OMP chat',
          model: 'test-model',
          readOnly: false,
          messages: [
            ChatMessage(
              id: 'stream-1',
              role: MessageRole.assistant,
              text: 'latest partial',
            ),
          ],
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Message…'));
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.enterText(
        find.byKey(const ValueKey('raiju-composer-input')),
        'mobile prompt',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('raiju-send')));
      await tester.pump();
      expect(client.sent, ['mobile prompt']);

      client.emit(
        const HarnessSnapshot(
          phase: ConnectionPhase.live,
          title: 'Widget OMP chat',
          readOnly: false,
          messages: [
            ChatMessage(
              id: 'stream-1',
              role: MessageRole.assistant,
              text: 'durable answer',
            ),
          ],
          questions: [
            HarnessQuestion(
              id: 11,
              title: 'Edit the command',
              kind: 'editor',
              prefill: 'draft',
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('companion-question-open-editor')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(
        find.byKey(const ValueKey('companion-question-editor')),
        'edited answer',
      );
      await tester.tap(find.text('Send answer'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(client.responses, [(9, 'host A'), (11, 'edited answer')]);

      client.emit(
        const HarnessSnapshot(
          phase: ConnectionPhase.live,
          title: 'Widget OMP chat',
          readOnly: true,
          messages: [
            ChatMessage(
              id: 'stream-1',
              role: MessageRole.assistant,
              text: 'durable answer',
            ),
          ],
          questions: [
            HarnessQuestion(
              id: 10,
              title: 'Read-only question',
              kind: 'select',
              options: [QuestionOption('must stay disabled')],
            ),
          ],
        ),
      );
      await tester.pump();
      expect(find.text('durable answer'), findsOneWidget);
      expect(find.textContaining('read only'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('message-row-stream-1')),
        findsOneWidget,
      );
      final disabledOption = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('companion-question-10-must stay disabled')),
      );
      expect(disabledOption.onPressed, isNull);
      expect(client.responses, [(9, 'host A'), (11, 'edited answer')]);
      client.emit(
        const HarnessSnapshot(
          phase: ConnectionPhase.error,
          title: 'Widget OMP chat',
          readOnly: true,
          error: 'Safe host failure.',
          messages: [
            ChatMessage(
              id: 'stream-1',
              role: MessageRole.assistant,
              text: 'durable answer',
            ),
          ],
        ),
      );
      await tester.pump();
      expect(find.text('durable answer'), findsOneWidget);
      expect(find.text('Safe host failure.'), findsOneWidget);
    },
  );

  testWidgets('thinking preference updates detail without losing source data', (
    tester,
  ) async {
    final client = _FakeClient(
      const HarnessSnapshot(
        phase: ConnectionPhase.live,
        title: 'Thinking chat',
        messages: [
          ChatMessage(
            id: 'answer',
            role: MessageRole.assistant,
            text: 'Visible answer',
            thinking: 'Private reasoning stays in source',
          ),
        ],
      ),
    );
    final controller = CompanionController(
      clientFactory: () => client,
      store: _MemoryStore(),
    );
    final thread = await controller.join('synthetic-thinking-capability');
    final sparkStore = _SparkStore();
    final container = ProviderContainer(
      overrides: [
        companionControllerProvider.overrideWith((ref) => controller),
        sparkSettingsStoreProvider.overrideWithValue(sparkStore),
        sparkVoiceSessionProvider.overrideWithValue(_FakeVoiceSession()),
      ],
    );
    addTearDown(container.dispose);
    final channel = Channel(
      id: thread.id,
      name: thread.title,
      channelType: 'dm',
      visibility: 'private',
      description: '',
      createdBy: 'local',
      createdAt: DateTime.utc(2026),
      memberCount: 2,
      isMember: true,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: ChannelDetailPage(channel: channel),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Visible answer'), findsOneWidget);
    expect(find.text('Private reasoning stays in source'), findsNothing);
    expect(
      client.snapshot.messages.single.thinking,
      'Private reasoning stays in source',
    );

    final spark = container.read(sparkControllerProvider);
    await spark.saveSettings(spark.settings.copyWith(hideThinking: false));
    await tester.pump();
    expect(find.text('Private reasoning stays in source'), findsOneWidget);
    await spark.saveSettings(spark.settings.copyWith(hideThinking: true));
    await tester.pump();
    expect(find.text('Private reasoning stays in source'), findsNothing);
    expect(
      client.snapshot.messages.single.thinking,
      'Private reasoning stays in source',
    );
  });

  testWidgets(
    'confirmed local deletion returns from detail only after success',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = _FakeClient(
        const HarnessSnapshot(
          phase: ConnectionPhase.live,
          title: 'Detail chat',
        ),
      );
      final store = _MemoryStore();
      final controller = CompanionController(
        clientFactory: () => client,
        store: store,
      );
      final thread = await controller.join('synthetic-detail-delete');
      final channel = Channel(
        id: thread.id,
        name: thread.title,
        channelType: 'dm',
        visibility: 'private',
        description: '',
        createdBy: 'local',
        createdAt: DateTime.utc(2026),
        memberCount: 2,
        isMember: true,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            companionControllerProvider.overrideWith((ref) => controller),
            sparkSettingsStoreProvider.overrideWithValue(_SparkStore()),
            sparkVoiceSessionProvider.overrideWithValue(_FakeVoiceSession()),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ChannelDetailPage(channel: channel),
                    ),
                  ),
                  child: const Text('Chat list'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Chat list'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('companion-channel-actions')));
      await tester.pumpAndSettle();
      final delete = find.byKey(
        const ValueKey('companion-actions-delete-chat'),
      );
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(ChannelDetailPage), findsOneWidget);
      expect(controller.chat(thread.id), isNotNull);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete chat').last);
      // The durable write and client cleanup can continue without scheduling
      // a Flutter frame; advance both clocks before asserting navigation.
      for (
        var attempt = 0;
        attempt < 30 && find.byType(ChannelDetailPage).evaluate().isNotEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pumpAndSettle();
      expect(controller.chat(thread.id), isNull);
      expect(store.values, isEmpty);
      expect(controller.chats, isEmpty);
      expect(client.disposed, isTrue);
      expect(find.byType(ChannelDetailPage), findsNothing);
      expect(find.text('Chat list'), findsOneWidget);
      expect(client.abortCalls, 0);
    },
  );

  testWidgets(
    'deletion never pops a newer route after the sheet is dismissed',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = _FakeClient(
        const HarnessSnapshot(
          phase: ConnectionPhase.live,
          title: 'Detail chat',
        ),
      );
      final store = _MemoryStore();
      final controller = CompanionController(
        clientFactory: () => client,
        store: store,
      );
      final thread = await controller.join('synthetic-newer-route-delete');
      final channel = Channel(
        id: thread.id,
        name: thread.title,
        channelType: 'dm',
        visibility: 'private',
        description: '',
        createdBy: 'local',
        createdAt: DateTime.utc(2026),
        memberCount: 2,
        isMember: true,
      );
      // Drain the join's scheduled write before holding deletion's write.
      await controller.flush();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            companionControllerProvider.overrideWith((ref) => controller),
            sparkSettingsStoreProvider.overrideWithValue(_SparkStore()),
            sparkVoiceSessionProvider.overrideWithValue(_FakeVoiceSession()),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ChannelDetailPage(channel: channel),
                    ),
                  ),
                  child: const Text('Chat list'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Chat list'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('companion-channel-actions')));
      await tester.pumpAndSettle();
      final delete = find.byKey(
        const ValueKey('companion-actions-delete-chat'),
      );
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      final commit = Completer<void>();
      store.waitNextSave = commit.future;
      await tester.tap(find.text('Delete chat').last);
      await tester.pumpAndSettle();
      expect(controller.chats, contains(thread));
      expect(store.values, isNotEmpty);
      await tester.drag(
        find.byKey(const ValueKey('buzz-sheet-drag-handle')),
        const Offset(0, 900),
      );
      await tester.pumpAndSettle();
      expect(delete, findsNothing);
      expect(controller.chats, contains(thread));
      final detailContext = tester.element(find.byType(ChannelDetailPage));
      Navigator.of(detailContext).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Newer route')),
        ),
      );
      await tester.pumpAndSettle();
      commit.complete();
      for (var attempt = 0; attempt < 30 && !client.disposed; attempt++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pumpAndSettle();
      expect(client.disposed, isTrue);
      expect(controller.chats, isEmpty);
      expect(controller.chat(thread.id), isNull);
      expect(store.values, isEmpty);
      expect(find.text('Newer route'), findsOneWidget);
      expect(
        find.byType(ChannelDetailPage, skipOffstage: false),
        findsOneWidget,
      );
      expect(client.abortCalls, 0);
    },
  );

  test(
    'controller sends, stops, and explicitly answers host questions',
    () async {
      final client = _FakeClient(
        const HarnessSnapshot(
          phase: ConnectionPhase.live,
          title: 'Real OMP chat',
          model: 'test-model',
          readOnly: false,
          isStreaming: true,
          messages: [
            ChatMessage(
              id: 'assistant-stream',
              role: MessageRole.assistant,
              text: 'Working',
              isStreaming: true,
            ),
          ],
          questions: [
            HarnessQuestion(
              id: 42,
              title: 'Choose a target',
              kind: 'select',
              options: [QuestionOption('safe target')],
            ),
          ],
        ),
      );
      final controller = CompanionController(
        clientFactory: () => client,
        store: _MemoryStore(),
      );
      addTearDown(controller.dispose);

      final thread = await controller.join('synthetic-test-capability');
      expect(thread.snapshot.canSend, isTrue);
      expect(projectTimelineMessages(thread.snapshot.messages), hasLength(1));

      await controller.sendPrompt(thread.id, 'Send once');
      await controller.abort(thread.id);
      await controller.respond(thread.id, 42, 'safe target');

      expect(client.sent, ['Send once']);
      expect(client.abortCalls, 1);
      expect(client.responses, [(42, 'safe target')]);
    },
  );

  test('read-only and error snapshots retain the transcript', () async {
    final client = _FakeClient(
      const HarnessSnapshot(
        phase: ConnectionPhase.error,
        title: 'Offline OMP chat',
        readOnly: true,
        error: 'Host is unavailable.',
        messages: [
          ChatMessage(
            id: 'durable-1',
            role: MessageRole.assistant,
            text: 'Previously received answer',
          ),
        ],
        questions: [
          HarnessQuestion(
            id: 7,
            title: 'Edit the command',
            kind: 'editor',
            prefill: 'safe value',
          ),
        ],
      ),
    );
    final controller = CompanionController(
      clientFactory: () => client,
      store: _MemoryStore(),
    );
    addTearDown(controller.dispose);

    final thread = await controller.join('synthetic-read-only-capability');
    expect(thread.snapshot.canSend, isFalse);
    expect(thread.snapshot.questions.single.kind, 'editor');
    expect(
      projectTimelineMessages(thread.snapshot.messages).single.content,
      'Previously received answer',
    );
  });
}

class _FakeClient implements HarnessClient {
  _FakeClient(this.connectedSnapshot);

  final HarnessSnapshot connectedSnapshot;
  final StreamController<HarnessSnapshot> _changes =
      StreamController<HarnessSnapshot>.broadcast(sync: true);

  void emit(HarnessSnapshot snapshot) {
    _snapshot = snapshot;
    _changes.add(snapshot);
  }

  HarnessSnapshot _snapshot = const HarnessSnapshot();
  final List<String> sent = [];
  final List<(int, String?)> responses = [];
  int abortCalls = 0;
  bool disposed = false;

  @override
  HarnessSnapshot get snapshot => _snapshot;

  @override
  Stream<HarnessSnapshot> get changes => _changes.stream;

  @override
  Future<void> connect(String input, {String displayName = 'raiju'}) async {
    _snapshot = connectedSnapshot;
    _changes.add(_snapshot);
  }

  @override
  Future<void> sendPrompt(String text) async => sent.add(text);

  @override
  Future<void> abort() async => abortCalls++;

  @override
  Future<void> respond(int requestId, String? value) async {
    responses.add((requestId, value));
  }

  @override
  Future<void> disconnect() async {
    _snapshot = HarnessSnapshot(
      phase: ConnectionPhase.disconnected,
      title: _snapshot.title,
      messages: _snapshot.messages,
      readOnly: true,
    );
    _changes.add(_snapshot);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _changes.close();
  }
}

class _MemoryStore implements ChatStore {
  List<StoredChat> values = [];
  Future<void>? waitNextSave;

  @override
  Future<List<StoredChat>> load() async => List.of(values);

  @override
  Future<void> save(List<StoredChat> chats) async {
    final pending = chats.isEmpty ? waitNextSave : null;
    if (pending != null) {
      waitNextSave = null;
      await pending;
    }
    values = List.of(chats);
  }
}

class _SparkStore implements SparkSettingsStore {
  SparkSettings settings = const SparkSettings();

  @override
  Future<StoredSparkSettings> load() async =>
      StoredSparkSettings(settings: settings, hasBrokerToken: false);

  @override
  Future<String?> readBrokerToken() async => null;

  @override
  Future<void> save(SparkSettings value, {String? brokerToken}) async {
    settings = value;
  }
}

class _FakeVoiceSession implements VoiceSession {
  final _events = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> dispose() => _events.close();

  @override
  Future<void> start({
    required String accessToken,
    String? accountId,
    required String instructions,
    required String voice,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> sendText(
    String text, {
    String? delegationId,
    String channel = 'speakable',
  }) async {}
}
