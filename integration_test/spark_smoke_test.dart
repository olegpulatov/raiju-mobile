// Modified for Raiju: synthetic Spark journey with no network, credentials, or audio.
import 'dart:async';
import 'package:buzz/app.dart';
import 'package:buzz/companion_controller.dart';
import 'package:buzz/features/channels/channel_detail_page.dart';
import 'package:buzz/harness/harness.dart';
import 'package:buzz/harness/voice_directive.dart';
import 'package:buzz/raiju/companion_provider.dart';
import 'package:buzz/shared/theme/community_theme_provider.dart';
import 'package:buzz/spark/spark.dart';
import 'package:buzz/shared/theme/theme_provider.dart';
import 'package:buzz/storage/chat_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'synthetic Spark chat and simulated lifecycle retain active voice (not real iOS suspension)',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final preferences = await SharedPreferences.getInstance();
      final chatStore = _MemoryChatStore();
      final companion = CompanionController(
        clientFactory: _FixtureHarness.new,
        store: chatStore,
      );
      await companion.initialize();
      final boundChat = await companion.join('synthetic-first-chat');
      final otherChat = await companion.join('synthetic-second-chat');
      addTearDown(companion.dispose);
      final session = _FixtureVoiceSession();
      final chat = CompanionSparkChatBridge(companion);
      final controller = SparkController(
        session: session,
        credentials: const _FixtureCredentials(),
        store: const _FixtureStore(),
        chatBridge: chat,
      );
      await controller.initialize();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            savedPrefsProvider.overrideWithValue(preferences),
            companionControllerProvider.overrideWith((ref) => companion),
            sparkControllerProvider.overrideWith((ref) => controller),
            sparkChatBridgeProvider.overrideWithValue(chat),
          ],
          child: const App(),
        ),
      );
      await _pumpFrames(tester);
      await tester.tap(find.text(boundChat.title).first);
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const ValueKey('spark-start')));
      await _pumpFrames(tester);
      expect(session.started, isTrue);
      session.emit(const {
        'type': 'transcript',
        'role': 'user',
        'text': 'Synthetic spoken request',
        'final': false,
        'id': 'fixture-user-partial-1',
      });
      session.emit(const {'type': 'levels', 'input': 0.025, 'output': 0.0});
      await _pumpFrames(tester);
      expect(
        find.byKey(const ValueKey('spark-live-transcript')),
        findsOneWidget,
      );
      expect(boundChat.voiceTurns, isEmpty);
      session.emit(const {'type': 'levels', 'input': 0.025, 'output': 0.0});
      await tester.pump(const Duration(milliseconds: 80));
      await binding.takeScreenshot('spark-live-transcript');
      await tester.tap(find.byKey(const ValueKey('spark-mic-toggle')));
      await tester.pump();
      expect(controller.snapshot.micEnabled, isFalse);
      expect(session.muted, isTrue);
      final originalBinding = controller.snapshot.boundChatId;
      addTearDown(() => _resumeLifecycle(tester));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // A paused live test binding cannot render frames; let events progress without pumping.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(session.stopped, isFalse);
      expect(session.startCalls, 1);
      expect(controller.snapshot.boundChatId, originalBinding);
      expect(controller.snapshot.micEnabled, isFalse);
      session.emit(const {
        'type': 'transcript',
        'role': 'user',
        'text': 'Synthetic spoken request',
        'final': true,
        'id': 'fixture-user-voice-1',
      });
      session.emit(const {
        'type': 'transcript',
        'role': 'assistant',
        'text': 'Synthetic Spark reply',
        'final': true,
        'id': 'fixture-spark-1',
      });
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(
        controller.snapshot.transcript.any(
          (turn) => turn.text == 'Synthetic spoken request',
        ),
        isTrue,
      );
      _resumeLifecycle(tester);
      await _pumpFrames(tester);
      expect(session.startCalls, 1);
      expect(session.muted, isTrue);
      expect(controller.snapshot.boundChatId, boundChat.id);
      expect(session.stopped, isFalse);
      expect(find.byKey(const ValueKey('spark-live-transcript')), findsNothing);

      expect(find.text('Synthetic spoken request'), findsOneWidget);
      expect(find.text('Synthetic Spark reply'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('spark-strip')));
      await _pumpFrames(tester);
      await tester.enterText(
        find.byKey(const ValueKey('spark-manual-input')),
        'Synthetic typed message',
      );
      await tester.tap(find.byKey(const ValueKey('spark-manual-submit')));
      await _pumpFrames(tester);
      expect(session.sentTexts, contains('Synthetic typed message'));
      Navigator.of(
        tester.element(find.byKey(const ValueKey('spark-transcript'))),
      ).pop();
      await _pumpFrames(tester);
      await tester.tap(find.text('Message…'));
      await _pumpFrames(tester);
      await tester.enterText(
        find.byKey(const ValueKey('raiju-composer-input')),
        'Typed composer suffix',
      );
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const ValueKey('raiju-send')));
      await _pumpFrames(tester);
      expect(session.sentTexts, contains('Typed composer suffix'));
      expect((boundChat.client as _FixtureHarness).sent, isEmpty);
      expect(find.text('Typed composer suffix'), findsOneWidget);
      expect(find.text('Synthetic spoken request'), findsOneWidget);
      expect(find.text('Synthetic Spark reply'), findsOneWidget);
      session.emit(const {
        'type': 'transcript',
        'role': 'user',
        'text': 'Synthetic follow-up',
        'final': true,
        'id': 'fixture-user-voice-2',
      });
      session.emit(const {
        'type': 'transcript',
        'role': 'assistant',
        'text': 'Follow-up from Spark',
        'final': true,
        'id': 'fixture-spark-2',
      });
      await _pumpFrames(tester);
      session.emit(const {
        'type': 'delegation',
        'id': 'synthetic-delegation',
        'text': '',
      });
      await _pumpFrames(tester);
      expect(
        (boundChat.client as _FixtureHarness).sent,
        contains(contains('User: Synthetic follow-up')),
      );
      expect(
        (boundChat.client as _FixtureHarness).sent.single,
        contains('User: Typed composer suffix'),
      );
      expect(
        session.sentTexts.where(
          (text) => text.contains('Synthetic finished 2.'),
        ),
        isEmpty,
      );
      expect(
        session.sentTexts.where(
          (text) => text.contains('Synthetic finished 1.'),
        ),
        hasLength(1),
      );
      expect(controller.snapshot.boundChatId, boundChat.id);
      expect(find.text('Synthetic spoken request'), findsOneWidget);
      expect(find.text('Typed composer suffix'), findsOneWidget);
      expect(find.text('Synthetic follow-up'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('message-row-fixture-assistant-1')),
        findsOneWidget,
      );
      await Navigator.of(
        tester.element(find.byKey(const ValueKey('channel-ios-glass-back'))),
      ).maybePop();
      await _pumpFrames(tester);
      await tester.tap(find.text(otherChat.title).first);
      await _pumpFrames(tester);
      expect(controller.snapshot.boundChatId, boundChat.id);
      expect(find.text('Synthetic spoken request'), findsNothing);
      expect(find.byKey(const ValueKey('spark-mic-toggle')), findsOneWidget);
      await Navigator.of(
        tester.element(find.byKey(const ValueKey('channel-ios-glass-back'))),
      ).maybePop();
      await _pumpFrames(tester);
      await tester.tap(find.text(boundChat.title).first);
      await _pumpFrames(tester);
      expect(find.text('Synthetic spoken request'), findsOneWidget);
      await _tapVisibleKey(tester, 'companion-channel-actions');
      expect(controller.settings.hideThinking, isTrue);
      await _tapVisibleKey(tester, 'companion-quick-show-thinking');
      expect(controller.settings.hideThinking, isFalse);
      await binding.takeScreenshot('spark-chat-quick-controls');
      await _tapVisibleKey(tester, 'companion-quick-show-thinking');
      expect(controller.settings.hideThinking, isTrue);
      expect(session.startCalls, 1);
      Navigator.of(
        tester.element(
          find.byKey(const ValueKey('companion-quick-show-thinking')),
        ),
      ).pop();
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const ValueKey('spark-strip')));
      await _pumpFrames(tester);
      final scope = ProviderScope.containerOf(
        tester.element(find.byKey(const ValueKey('spark-transcript'))),
        listen: false,
      );
      scope.read(communityThemeProvider.notifier).setMode(ThemeMode.light);
      await tester.pump(const Duration(milliseconds: 300));
      await binding.takeScreenshot('spark-expanded-light');
      Navigator.of(
        tester.element(find.byKey(const ValueKey('spark-transcript'))),
      ).pop();
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const ValueKey('spark-minimize')));
      await _pumpFrames(tester);
      await binding.takeScreenshot('spark-minimized-light');
      scope.read(communityThemeProvider.notifier).setMode(ThemeMode.dark);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Expand Spark controls'));
      await _pumpFrames(tester);
      await binding.takeScreenshot('spark-expanded-dark');
      final harness = boundChat.client as _FixtureHarness;
      harness.emitTerminalReply('Synthetic terminal answer');
      await _pumpFrames(tester);
      final terminalReply = session.sentContexts.singleWhere(
        (item) => item.text.contains('Synthetic terminal answer'),
      );
      expect(terminalReply.delegationId, isNull);
      expect(terminalReply.channel, 'speakable');
      expect(harness.sent, hasLength(1));
      harness.repeatSnapshot();
      await _pumpFrames(tester);
      expect(
        session.sentTexts.where(
          (text) => text.contains('Synthetic terminal answer'),
        ),
        hasLength(1),
      );
      await controller.saveSettings(
        controller.settings.copyWith(announceTerminalReplies: false),
      );
      harness.emitTerminalReply('Synthetic suppressed terminal answer');
      await _pumpFrames(tester);
      expect(
        session.sentTexts.any(
          (text) => text.contains('Synthetic suppressed terminal answer'),
        ),
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('spark-stop')));
      await _pumpFrames(tester);
      expect(session.stopped, isTrue);
      expect(session.startCalls, 1);
      await companion.flush();
      // The app owns a global Navigator key. Unmount its old route tree before
      // mounting a second ProviderScope so no old route keeps the first scope.
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpFrames(tester);
      expect(find.byKey(const ValueKey('spark-start')), findsNothing);
      final restored = CompanionController(
        clientFactory: _FixtureHarness.new,
        store: chatStore,
      );
      await restored.initialize();
      addTearDown(restored.dispose);
      final restartedSession = _FixtureVoiceSession();
      final restartedBridge = CompanionSparkChatBridge(restored);
      final restartedSpark = SparkController(
        session: restartedSession,
        credentials: const _FixtureCredentials(),
        store: const _FixtureStore(),
        chatBridge: restartedBridge,
      );
      await restartedSpark.initialize();
      addTearDown(restartedSpark.dispose);
      expect(
        restored.chat(boundChat.id)!.voiceTurns.map((turn) => turn.text),
        contains('Synthetic spoken request'),
      );
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('restored-spark-fixture'),
          overrides: [
            savedPrefsProvider.overrideWithValue(preferences),
            companionControllerProvider.overrideWith((ref) => restored),
            sparkControllerProvider.overrideWith((ref) => restartedSpark),
            sparkChatBridgeProvider.overrideWithValue(restartedBridge),
          ],
          child: const App(),
        ),
      );
      await _pumpFrames(tester);
      await tester.tap(find.text(boundChat.title).first);
      await _pumpFrames(tester);
      final startFinder = find.byKey(const ValueKey('spark-start'));
      final startScope = ProviderScope.containerOf(
        tester.element(startFinder),
        listen: false,
      );
      final chatScope = ProviderScope.containerOf(
        tester.element(find.byType(ChannelDetailPage)),
        listen: false,
      );
      final startButton = tester.widget<IconButton>(startFinder);
      final viewedChatId = startScope.read(viewedCompanionChatProvider);
      final startupDiagnostics =
          'startScope=${identityHashCode(startScope)} '
          'chatScope=${identityHashCode(chatScope)} '
          'startController=${identityHashCode(startScope.read(sparkControllerProvider))} '
          'expectedController=${identityHashCode(restartedSpark)} '
          'viewedChat=$viewedChatId expectedChat=${boundChat.id} '
          'onPressed=${startButton.onPressed != null} '
          'phase=${restartedSpark.snapshot.phase} '
          'lifecycle=${binding.lifecycleState}';
      expect(
        identical(startScope, chatScope),
        isTrue,
        reason: startupDiagnostics,
      );
      expect(
        identical(startScope.read(sparkControllerProvider), restartedSpark),
        isTrue,
        reason: startupDiagnostics,
      );
      expect(viewedChatId, boundChat.id, reason: startupDiagnostics);
      expect(startButton.onPressed, isNotNull, reason: startupDiagnostics);
      expect(find.text('Synthetic spoken request'), findsOneWidget);
      expect(restartedSession.started, isFalse);
      await binding.takeScreenshot('spark-restored-bound-chat');
      await _tapVisibleKey(tester, 'spark-start');
      for (
        var attempt = 0;
        attempt < 30 &&
            !restartedSession.started &&
            restartedSpark.snapshot.phase != SparkPhase.error;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        restartedSession.started,
        isTrue,
        reason:
            '$startupDiagnostics; after tap: phase=${restartedSpark.snapshot.phase} '
            'error=${restartedSpark.snapshot.error} '
            'startCalls=${restartedSession.startCalls} '
            'viewedChat=${startScope.read(viewedCompanionChatProvider)} '
            'lifecycle=${binding.lifecycleState}',
      );
      final deletingHarness =
          restored.chat(boundChat.id)!.client as _FixtureHarness;
      await _tapVisibleKey(tester, 'companion-channel-actions');
      await _tapVisibleKey(tester, 'companion-actions-delete-chat');
      await binding.takeScreenshot('spark-delete-confirmation');
      await tester.tap(find.text('Cancel'));
      await _pumpFrames(tester);
      expect(restored.chat(boundChat.id), isNotNull);
      expect(restartedSession.stopped, isFalse);
      await _tapVisibleKey(tester, 'companion-actions-delete-chat');
      await tester.tap(find.widgetWithText(FilledButton, 'Delete chat'));
      await _pumpFrames(tester);
      expect(restored.chat(boundChat.id), isNull);
      expect(chatStore.value.any((item) => item.id == boundChat.id), isFalse);
      expect(restartedSession.stopped, isTrue);
      expect(deletingHarness.abortCalls, 0);
      expect(find.text(otherChat.title), findsWidgets);
      expect(session.stopped, isTrue);
    },
  );
}

Future<void> _pumpFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tapVisibleKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await _pumpFrames(tester);
  await tester.tap(finder);
  await _pumpFrames(tester);
}

final class _FixtureVoiceSession implements VoiceSession {
  final _events = StreamController<Map<String, Object?>>.broadcast();
  final sentTexts = <String>[];
  final sentContexts =
      <({String text, String? delegationId, String channel})>[];
  int startCalls = 0;
  bool started = false;
  bool stopped = false;
  bool muted = false;
  @override
  Stream<Map<String, Object?>> get events => _events.stream;
  void emit(Map<String, Object?> event) => _events.add(event);
  @override
  Future<void> start({
    required String accessToken,
    String? accountId,
    required String instructions,
    required String voice,
  }) async {
    startCalls++;
    started = true;
    emit(const {'type': 'connected'});
  }

  @override
  Future<void> stop() async {
    stopped = true;
    emit(const {'type': 'closed'});
  }

  @override
  Future<void> setMuted(bool value) async => muted = value;
  @override
  Future<void> sendText(
    String text, {
    String? delegationId,
    String channel = 'speakable',
  }) async {
    sentTexts.add(text);
    sentContexts.add((
      text: text,
      delegationId: delegationId,
      channel: channel,
    ));
  }

  @override
  Future<void> dispose() async => _events.close();
}

final class _FixtureCredentials implements SparkCredentialSource {
  const _FixtureCredentials();
  @override
  Future<SparkCredentialResult> acquire(
    SparkSettings settings,
    String brokerToken,
  ) async => const SparkCredentialResult(
    choices: [SparkCredentialChoice(id: 'fixture', label: 'Synthetic account')],
    credential: SparkCredential(
      id: 'fixture',
      accessToken: 'synthetic-runtime-token',
      expiresAtMs: 4102444800000,
    ),
  );
}

final class _FixtureStore implements SparkSettingsStore {
  const _FixtureStore();
  @override
  Future<StoredSparkSettings> load() async => const StoredSparkSettings(
    settings: SparkSettings(brokerUrl: 'https://fixture.invalid'),
    hasBrokerToken: true,
  );
  @override
  Future<String?> readBrokerToken() async => 'synthetic-runtime-token';
  @override
  Future<void> save(SparkSettings settings, {String? brokerToken}) async {}
}

final class _MemoryChatStore implements ChatStore {
  List<StoredChat> value = const [];
  @override
  Future<List<StoredChat>> load() async => value;
  @override
  Future<void> save(List<StoredChat> chats) async => value = List.of(chats);
}

final class _FixtureHarness implements HarnessClient {
  final _changes = StreamController<HarnessSnapshot>.broadcast();
  final sent = <String>[];
  final entries = <Map<String, Object?>>[];
  int abortCalls = 0;
  @override
  HarnessSnapshot snapshot = const HarnessSnapshot();
  @override
  Stream<HarnessSnapshot> get changes => _changes.stream;
  @override
  Future<void> connect(String input, {String displayName = 'raiju'}) async {
    snapshot = HarnessSnapshot(
      phase: ConnectionPhase.live,
      readOnly: false,
      title: input == 'synthetic-first-chat'
          ? 'Synthetic first chat'
          : 'Synthetic second chat',
    );
    _changes.add(snapshot);
  }

  @override
  Future<void> sendPrompt(String text) async {
    sent.add(text);
    final id = 'fixture-echo-${entries.length}';
    entries.add({
      'id': id,
      'type': 'custom_message',
      'customType': 'collab-prompt',
      'content': text,
    });
    final observed = HarnessSnapshot(
      phase: ConnectionPhase.live,
      readOnly: false,
      title: snapshot.title,
      rawEntries: List.of(entries),
      messages: [
        for (final entry in entries)
          ChatMessage(
            id: entry['id']! as String,
            role: MessageRole.user,
            text: VoiceDirective.strip(entry['content']! as String),
            source: entry,
          ),
        ChatMessage(
          id: 'fixture-assistant-${entries.length}',
          role: MessageRole.assistant,
          text: 'Synthetic finished ${entries.length}.',
          prose: 'Synthetic finished ${entries.length}.',
          origin: ChatMessageOrigin.remoteAssistant,
          thinking: 'Synthetic hidden reasoning',
        ),
      ],
      agentEvents: [
        AgentEvent(
          sequence: entries.length * 4 - 3,
          event: const {'type': 'agent_start'},
        ),
        AgentEvent(
          sequence: entries.length * 4 - 2,
          event: {
            'type': 'message_start',
            'message': {
              'role': 'custom',
              'customType': 'collab-prompt',
              'content': text,
            },
          },
        ),
        AgentEvent(
          sequence: entries.length * 4 - 1,
          event: const {
            'type': 'message_end',
            'message': {
              'role': 'assistant',
              'stopReason': 'toolUse',
              'content': [
                {'type': 'text', 'text': 'Synthetic work is underway.'},
              ],
            },
          },
        ),
        AgentEvent(
          sequence: entries.length * 4,
          event: {
            'type': 'agent_end',
            'isTerminal': true,
            'messages': [
              {
                'role': 'custom',
                'customType': 'collab-prompt',
                'content': text,
              },
              {
                'role': 'assistant',
                'stopReason': 'toolUse',
                'content': [
                  {'type': 'text', 'text': 'Synthetic work is underway.'},
                ],
              },
              {
                'role': 'assistant',
                'stopReason': 'stop',
                'content': [
                  {
                    'type': 'text',
                    'text': 'Synthetic finished ${entries.length}.',
                  },
                ],
              },
            ],
          },
        ),
      ],
    );
    Timer(const Duration(milliseconds: 40), () {
      snapshot = observed;
      _changes.add(snapshot);
    });
  }

  void repeatSnapshot() => _changes.add(snapshot);

  void emitTerminalReply(String reply) {
    final sequence = snapshot.agentEvents.isEmpty
        ? 1
        : snapshot.agentEvents.last.sequence + 1;
    final user = <String, Object?>{
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'Synthetic terminal request $sequence'},
      ],
    };
    snapshot = HarnessSnapshot(
      phase: snapshot.phase,
      title: snapshot.title,
      sessionId: snapshot.sessionId,
      sessionStartedAt: snapshot.sessionStartedAt,
      readOnly: snapshot.readOnly,
      messages: snapshot.messages,
      rawEntries: snapshot.rawEntries,
      agentEvents: [
        ...snapshot.agentEvents,
        AgentEvent(sequence: sequence, event: const {'type': 'agent_start'}),
        AgentEvent(
          sequence: sequence + 1,
          event: {'type': 'message_start', 'message': user},
        ),
        AgentEvent(
          sequence: sequence + 2,
          event: {
            'type': 'agent_end',
            'isTerminal': true,
            'messages': [
              user,
              {
                'role': 'assistant',
                'stopReason': 'stop',
                'content': [
                  {'type': 'text', 'text': reply},
                ],
              },
            ],
          },
        ),
      ],
    );
    _changes.add(snapshot);
  }

  @override
  Future<void> abort() async => abortCalls++;
  @override
  Future<void> respond(int requestId, String? value) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async => _changes.close();
}

void _resumeLifecycle(WidgetTester tester) {
  final binding = tester.binding;
  if (binding.lifecycleState == AppLifecycleState.paused) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (binding.lifecycleState == AppLifecycleState.hidden) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  if (binding.lifecycleState != AppLifecycleState.resumed) {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }
}
