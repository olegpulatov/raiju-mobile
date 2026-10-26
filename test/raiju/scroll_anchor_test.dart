import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:raiju_mobile/companion_controller.dart';
import 'package:raiju_mobile/features/channels/channel.dart';
import 'package:raiju_mobile/features/channels/channel_detail_page.dart';
import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/raiju/companion_provider.dart';
import 'package:raiju_mobile/shared/theme/theme.dart';
import 'package:raiju_mobile/spark/spark.dart';
import 'package:raiju_mobile/storage/chat_store.dart';
import 'package:raiju_mobile/storage/voice_transcript.dart';
import 'package:shared_preferences/shared_preferences.dart';

late SharedPreferences _testPrefs;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _testPrefs = await SharedPreferences.getInstance();
  });

  testWidgets('detached reading position survives streaming and new messages', (
    tester,
  ) async {
    final fixture = await _Fixture.mount(tester);
    await fixture.detach(tester);
    final reference = fixture.reference(tester);
    final y = tester.getTopLeft(reference).dy;

    for (var frame = 1; frame <= 20; frame++) {
      fixture.messages[fixture.messages.length - 1] = ChatMessage(
        id: 'newest',
        role: MessageRole.assistant,
        text: List.filled(frame + 1, 'Streaming line $frame').join('\n'),
        isStreaming: true,
      );
      fixture.emit();
      await tester.pump(const Duration(milliseconds: 16));
      fixture.expectStill(tester, reference, y);
    }
    fixture.messages.add(
      const ChatMessage(
        id: 'appended',
        role: MessageRole.assistant,
        text: 'New response',
      ),
    );
    fixture.emit();
    await tester.pump();
    fixture.expectStill(tester, reference, y);
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      fixture.expectStill(tester, reference, y);
    }
    fixture.messages.insertAll(0, [
      for (var index = 0; index < 8; index++)
        ChatMessage(
          id: 'older-history-$index',
          role: MessageRole.user,
          text: 'Older history $index',
        ),
    ]);
    fixture.emit();
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      fixture.expectStill(tester, reference, y);
    }
    expect(
      find.byKey(const ValueKey('channel-jump-to-latest')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('channel-jump-to-latest')));
    await _settle(tester);
    fixture.expectLatest(tester);
  });

  testWidgets('small detach never resumes following on a stream update', (
    tester,
  ) async {
    final fixture = await _Fixture.mount(tester);
    final initialReference = fixture.reference(tester);
    final initialY = tester.getTopLeft(initialReference).dy;
    final list = find.byKey(const ValueKey('channel-message-list'));
    final gesture = await tester.startGesture(tester.getCenter(list));
    await gesture.moveBy(const Offset(0, 25));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 3));
    await tester.pump();
    await gesture.up();
    await _settle(tester);
    final reference = fixture.reference(tester);
    final y = tester.getTopLeft(reference).dy;
    expect(tester.getTopLeft(initialReference).dy, closeTo(initialY + 3, 1));
    fixture.messages.last = const ChatMessage(
      id: 'newest',
      role: MessageRole.assistant,
      text: 'Streaming line\nExtra line',
      isStreaming: true,
    );
    fixture.emit();
    await tester.pump();
    fixture.expectStill(tester, reference, y);
    await _settle(tester);
    fixture.expectStill(tester, reference, y);
    expect(
      find.byKey(const ValueKey('channel-jump-to-latest')),
      findsOneWidget,
    );
  });

  testWidgets('stream updates do not cancel an active reading drag', (
    tester,
  ) async {
    final fixture = await _Fixture.mount(tester);
    final list = find.byKey(const ValueKey('channel-message-list'));
    final gesture = await tester.startGesture(tester.getCenter(list));
    await gesture.moveBy(const Offset(0, 150));
    await tester.pump();
    final reference = fixture.reference(tester);
    final y = tester.getTopLeft(reference).dy;
    fixture.messages.last = const ChatMessage(
      id: 'newest',
      role: MessageRole.assistant,
      text: 'Streaming line\nExtra line',
      isStreaming: true,
    );
    fixture.emit();
    await tester.pump();
    expect(tester.getTopLeft(reference).dy, closeTo(y, 1));
    fixture.messages.add(
      const ChatMessage(
        id: 'during-drag',
        role: MessageRole.assistant,
        text: 'New reply',
      ),
    );
    fixture.emit();
    await tester.pump();
    expect(tester.getTopLeft(reference).dy, closeTo(y, 1));
    await gesture.moveBy(const Offset(0, 50));
    await tester.pump();
    expect(tester.getTopLeft(reference).dy, closeTo(y + 50, 1));
    await gesture.up();
    await _settle(tester);
    final settledY = tester.getTopLeft(reference).dy;
    await _settle(tester);
    fixture.expectStill(tester, reference, settledY);
  });

  testWidgets('reading inside a screen-filling streamed row stays anchored', (
    tester,
  ) async {
    final fixture = await _Fixture.mount(tester);
    fixture.messages.last = ChatMessage(
      id: 'newest',
      role: MessageRole.assistant,
      text: List.filled(90, 'Long streaming line').join('\n'),
      isStreaming: true,
    );
    fixture.emit();
    await _settle(tester);
    await fixture.detach(tester);
    final reference = find.byKey(const ValueKey('message-row-newest'));
    final y = tester.getTopLeft(reference).dy;
    fixture.messages.last = ChatMessage(
      id: 'newest',
      role: MessageRole.assistant,
      text: List.filled(95, 'Long streaming line').join('\n'),
      isStreaming: true,
    );
    fixture.emit();
    await tester.pump();
    fixture.expectStill(tester, reference, y);
    await _settle(tester);
    fixture.expectStill(tester, reference, y);
  });

  testWidgets(
    'detached reading survives composer, keyboard, voice, and send',
    (tester) async {
      const nativeAttachments = MethodChannel('buzz/native_attachment_popover');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        nativeAttachments,
        (call) async => call.method == 'isSupported' ? false : null,
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          nativeAttachments,
          null,
        );
      });
      final fixture = await _Fixture.mount(tester);
      await fixture.detach(tester);
      final reference = fixture.reference(tester);
      final y = tester.getTopLeft(reference).dy;
      Future<void> checkFrames() async {
        for (var frame = 0; frame < 24; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          fixture.expectStill(tester, reference, y);
        }
      }

      await tester.tap(find.text('Message…'));
      await checkFrames();
      await tester.enterText(
        find.byKey(const ValueKey('raiju-composer-input')),
        'Draft',
      );
      await checkFrames();
      for (final inset in [80.0, 160.0, 300.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await checkFrames();
      }
      await tester.enterText(
        find.byKey(const ValueKey('raiju-composer-input')),
        'First line\nSecond line\nThird line\nFourth line',
      );
      await checkFrames();

      final chatId = fixture.controller.chats.single.id;
      for (var partial = 1; partial <= 6; partial++) {
        fixture.controller.upsertVoiceTurn(
          chatId,
          VoiceTurn(
            id: 'recognized-speech',
            sequence: 0,
            origin: VoiceTurnOrigin.user,
            text: List.filled(partial, 'Recognized words').join(' '),
            precedingHostEntryId: 'newest',
          ),
        );
        await checkFrames();
      }
      fixture.controller.upsertVoiceTurn(
        chatId,
        const VoiceTurn(
          id: 'spark-response',
          sequence: 1,
          origin: VoiceTurnOrigin.spark,
          text: 'Spark response',
          precedingHostEntryId: 'newest',
        ),
      );
      await checkFrames();

      await tester.tap(find.byKey(const ValueKey('raiju-send')));
      await checkFrames();
      expect(fixture.controller.chat(chatId)!.draft, isEmpty);
      expect(fixture.client.prompts, [
        'First line\nSecond line\nThird line\nFourth line',
      ]);
      expect(
        find.byKey(const ValueKey('channel-jump-to-latest')),
        findsOneWidget,
      );
      for (final inset in [160.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await checkFrames();
      }
      await tester.tap(find.byTooltip('Add attachment').hitTestable());
      await checkFrames();
      expect(find.byKey(const ValueKey('attachment-menu')), findsOneWidget);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  testWidgets('attached timeline continues following streamed content', (
    tester,
  ) async {
    final fixture = await _Fixture.mount(tester);
    for (var frame = 1; frame <= 10; frame++) {
      fixture.messages[fixture.messages.length - 1] = ChatMessage(
        id: 'newest',
        role: MessageRole.assistant,
        text: List.filled(frame + 1, 'Streaming line').join('\n'),
        isStreaming: true,
      );
      fixture.emit();
      await tester.pump(const Duration(milliseconds: 16));
      fixture.expectLatest(tester);
    }
  });

  testWidgets(
    'attached timeline follows keyboard, composer growth, and typed send',
    (tester) async {
      final fixture = await _Fixture.mount(tester);
      await tester.tap(find.text('Message…'));
      await _settle(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await _settle(tester);
      fixture.expectLatest(tester);
      await tester.enterText(
        find.byKey(const ValueKey('raiju-composer-input')),
        'First line\nSecond line\nThird line',
      );
      await _settle(tester);
      fixture.expectLatest(tester);
      await tester.tap(find.byKey(const ValueKey('raiju-send')));
      await _settle(tester);
      expect(fixture.client.prompts, ['First line\nSecond line\nThird line']);
      fixture.expectLatest(tester);
      expect(
        find.byKey(const ValueKey('channel-jump-to-latest')),
        findsNothing,
      );
      tester.view.viewInsets = const FakeViewPadding();
      await _settle(tester);
      fixture.expectLatest(tester);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 30; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

class _Fixture {
  _Fixture(this.client, this.controller, this.messages);

  final _Client client;
  final CompanionController controller;
  final List<ChatMessage> messages;

  static Future<_Fixture> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final messages = [
      for (var index = 0; index < 40; index++)
        ChatMessage(
          id: 'history-$index',
          role: index.isEven ? MessageRole.user : MessageRole.assistant,
          text: 'History row $index\nSecond line',
        ),
      const ChatMessage(
        id: 'newest',
        role: MessageRole.assistant,
        text: 'Streaming line',
        isStreaming: true,
      ),
    ];
    final client = _Client();
    final fixture = _Fixture(
      client,
      CompanionController(clientFactory: () => client, store: _Store()),
      messages,
    );
    fixture.emit();
    final chat = await fixture.controller.join('synthetic-scroll-capability');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          savedPrefsProvider.overrideWithValue(_testPrefs),
          companionControllerProvider.overrideWith((ref) => fixture.controller),
          sparkVoiceSessionProvider.overrideWithValue(_Voice()),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: ChannelDetailPage(
            channel: Channel(
              id: chat.id,
              name: chat.title,
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
    await _settle(tester);
    return fixture;
  }

  void emit() => client.emit(
    HarnessSnapshot(
      phase: ConnectionPhase.live,
      title: 'Scroll chat',
      readOnly: false,
      messages: List.of(messages),
    ),
  );

  Future<void> detach(WidgetTester tester, {double distance = 240}) async {
    await tester.drag(
      find.byKey(const ValueKey('channel-message-list')),
      Offset(0, distance),
    );
    await _settle(tester);
  }

  Finder reference(WidgetTester tester) {
    final rows = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key as ValueKey<String>).value.startsWith(
            'message-row-history-',
          ),
    );
    return rows
        .evaluate()
        .map((element) => find.byKey(element.widget.key!))
        .firstWhere(
          (finder) =>
              tester.getTopLeft(finder).dy > 200 &&
              tester.getBottomLeft(finder).dy < 600,
        );
  }

  void expectStill(WidgetTester tester, Finder reference, double y) {
    expect(tester.getTopLeft(reference).dy, closeTo(y, 1));
    final scrollables = tester.stateList<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('channel-message-list')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      scrollables.every((state) => !state.position.isScrollingNotifier.value),
      isTrue,
    );
  }

  void expectLatest(WidgetTester tester) {
    final newestId = controller.chats.single.snapshot.messages.last.id;
    final latest = find.byKey(ValueKey('channel-message-group-$newestId'));
    final dock = find.byKey(const ValueKey('channel-composer-dock'));
    expect(
      tester.getBottomLeft(latest).dy,
      closeTo(tester.getTopLeft(dock).dy, 1),
    );
  }
}

class _Client implements HarnessClient {
  final _changes = StreamController<HarnessSnapshot>.broadcast(sync: true);
  HarnessSnapshot _snapshot = const HarnessSnapshot();
  final prompts = <String>[];
  @override
  HarnessSnapshot get snapshot => _snapshot;
  @override
  Stream<HarnessSnapshot> get changes => _changes.stream;
  void emit(HarnessSnapshot value) {
    _snapshot = value;
    _changes.add(value);
  }

  @override
  Future<void> connect(String input, {String displayName = 'raiju'}) async =>
      _changes.add(_snapshot);
  @override
  Future<void> sendPrompt(String text) async {
    prompts.add(text);
    emit(
      HarnessSnapshot(
        phase: ConnectionPhase.live,
        title: _snapshot.title,
        readOnly: false,
        messages: [
          ..._snapshot.messages,
          ChatMessage(
            id: 'sent-${prompts.length}',
            role: MessageRole.user,
            author: 'raiju',
            text: text,
          ),
        ],
      ),
    );
  }

  @override
  Future<void> abort() async {}
  @override
  Future<void> respond(int requestId, String? value) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() => _changes.close();
}

class _Store implements ChatStore {
  @override
  Future<List<StoredChat>> load() async => [];
  @override
  Future<void> save(List<StoredChat> chats) async {}
}

class _Voice implements VoiceSession {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> dispose() async {}
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
