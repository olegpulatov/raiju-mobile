import 'dart:async';

import 'package:flutter/material.dart';
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
    final newestId = messages.last.id;
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
  Future<void> sendPrompt(String text) async {}
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
