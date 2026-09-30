import 'dart:async';

import 'package:buzz/companion_controller.dart';
import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channel_actions_sheet.dart';
import 'package:buzz/harness/harness.dart';
import 'package:buzz/raiju/companion_provider.dart';
import 'package:buzz/spark/spark.dart';
import 'package:buzz/storage/chat_store.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final _channel = Channel(
  id: 'companion-test',
  name: 'Companion',
  channelType: 'dm',
  visibility: 'private',
  description: '',
  createdBy: 'local',
  createdAt: DateTime.utc(2026),
  memberCount: 2,
  isMember: true,
);

Widget _app(
  _QuickStore store, {
  CompanionController? companion,
  Channel? channel,
  ValueChanged<bool?>? onClosed,
  SparkController? spark,
}) => ProviderScope(
  overrides: [
    companionControllerProvider.overrideWith(
      (ref) =>
          companion ??
          CompanionController(
            clientFactory: () => throw StateError('No connection needed'),
            store: _ChatStore(),
          ),
    ),
    if (spark != null) sparkControllerProvider.overrideWith((ref) => spark),
    sparkVoiceSessionProvider.overrideWithValue(_NoopSession()),
    sparkSettingsStoreProvider.overrideWithValue(store),
  ],
  child: MaterialApp(
    theme: AppTheme.light(),
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () async {
            final deleted = await showChannelActionsSheet(
              context: context,
              channel: channel ?? _channel,
              isUnread: false,
              companionMode: true,
            );
            onClosed?.call(deleted);
          },
          child: const Text('Open actions'),
        ),
      ),
    ),
  ),
);

Future<void> _open(
  WidgetTester tester,
  _QuickStore store, {
  CompanionController? companion,
  Channel? channel,
  ValueChanged<bool?>? onClosed,
  SparkController? spark,
}) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    _app(
      store,
      companion: companion,
      channel: channel,
      onClosed: onClosed,
      spark: spark,
    ),
  );
  await tester.tap(find.text('Open actions'));
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'companion menu saves independent quick preferences and retains actions',
    (tester) async {
      final store = _QuickStore(
        const SparkSettings(
          userName: 'Nina',
          contextAddition: 'Keep my context',
          mainAgentDirective: 'Keep my directive',
          agentFinalMessage: 'Answer: {{message}}',
          promptPresets: [
            SparkPromptPreset(
              id: 'spark-default',
              name: 'Custom persona',
              instructions: 'Keep my instructions',
            ),
          ],
        ),
      );
      await _open(tester, store);
      for (final label in [
        'Mute channel',
        'Copy channel name',
        'Copy channel ID',
        'Disconnect',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(
        find.byKey(const ValueKey('companion-quick-show-thinking')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('companion-quick-tool-visibility')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('companion-quick-announce-terminal')),
        findsOneWidget,
      );
      expect(store.settings.hideThinking, isTrue);
      expect(store.settings.announceTerminalReplies, isTrue);
      expect(store.settings.toolVisibility, SparkToolVisibility.hideInVoice);

      await _tapVisible(
        tester,
        find.byKey(const ValueKey('companion-quick-show-thinking')),
      );
      expect(store.settings.hideThinking, isFalse);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('companion-quick-tool-visibility')),
      );
      await tester.tap(find.text('Show').last);
      await tester.pumpAndSettle();
      expect(store.settings.toolVisibility, SparkToolVisibility.show);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('companion-quick-announce-terminal')),
      );
      expect(store.settings.announceTerminalReplies, isFalse);
      expect(store.saves, 3);
      expect(store.settings.userName, 'Nina');
      expect(store.settings.contextAddition, 'Keep my context');
      expect(store.settings.mainAgentDirective, 'Keep my directive');
      expect(store.settings.agentFinalMessage, 'Answer: {{message}}');
      expect(
        store.settings.selectedPreset.instructions,
        'Keep my instructions',
      );
      expect(find.text('Disconnect'), findsOneWidget);
    },
  );

  testWidgets(
    'failed save shows error without changing switch and allows retry',
    (tester) async {
      final store = _QuickStore(const SparkSettings())..failSave = true;
      await _open(tester, store);
      final switchFinder = find.byKey(
        const ValueKey('companion-quick-announce-terminal'),
      );
      await _tapVisible(tester, switchFinder);
      expect(store.settings.announceTerminalReplies, isTrue);
      expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
      expect(find.text('Spark settings could not be saved.'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open actions'));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(switchFinder).onChanged, isNotNull);
      store.failSave = false;
      await _tapVisible(tester, switchFinder);
      expect(store.settings.announceTerminalReplies, isFalse);
      expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
      expect(find.text('Disconnect'), findsOneWidget);
    },
  );

  testWidgets('quick controls wait for protected settings to load', (
    tester,
  ) async {
    final load = Completer<StoredSparkSettings>();
    final store = _QuickStore(const SparkSettings())..pendingLoad = load.future;
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_app(store));
    await tester.tap(find.text('Open actions'));
    await tester.pump();
    final showThinking = find.byKey(
      const ValueKey('companion-quick-show-thinking'),
    );
    expect(tester.widget<SwitchListTile>(showThinking).onChanged, isNull);
    load.complete(
      const StoredSparkSettings(
        settings: SparkSettings(
          hideThinking: false,
          announceTerminalReplies: false,
        ),
        hasBrokerToken: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(showThinking).value, isTrue);
    expect(tester.widget<SwitchListTile>(showThinking).onChanged, isNotNull);
    expect(store.saves, 0);
  });
  testWidgets(
    'delete chat confirms local scope, keeps chat on failure, navigates only after success',
    (tester) async {
      final chatStore = _ChatStore();
      final client = _Client();
      final companion = CompanionController(
        clientFactory: () => client,
        store: chatStore,
      );
      final thread = await companion.join('synthetic-delete-capability');
      companion.updateDraft(thread.id, 'unsent draft');
      await companion.flush();
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
      final closed = <bool?>[];
      await _open(
        tester,
        _QuickStore(const SparkSettings()),
        companion: companion,
        channel: channel,
        onClosed: closed.add,
      );
      final delete = find.byKey(
        const ValueKey('companion-actions-delete-chat'),
      );
      await _tapVisible(tester, delete);
      expect(find.text('Delete this chat from your device?'), findsOneWidget);
      expect(
        find.textContaining(
          'Remote OMP history and work are not deleted or stopped.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(companion.chat(thread.id), isNotNull);
      expect(chatStore.values.single.draft, 'unsent draft');
      expect(closed, isEmpty);
      expect(client.abortCalls, 0);

      chatStore.failSave = true;
      await _tapVisible(tester, delete);
      await tester.tap(find.text('Delete chat').last);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Could not delete this chat from this device.'),
        findsOneWidget,
      );
      expect(companion.chat(thread.id), isNotNull);
      expect(chatStore.values.single.draft, 'unsent draft');
      expect(closed, isEmpty);
      expect(client.abortCalls, 0);

      chatStore.failSave = false;
      // A failed forget schedules a background retry. Drain it before
      // holding the next write so this completer fences the delete itself.
      await companion.flush();
      await _tapVisible(tester, delete);
      final commit = Completer<void>();
      chatStore.waitNextSave = commit.future;
      await tester.tap(find.text('Delete chat').last);
      await tester.pumpAndSettle();
      expect(tester.widget<ListTile>(delete).onTap, isNull);
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('companion-actions-disconnect')),
            )
            .onTap,
        isNull,
      );
      expect(companion.chats, contains(thread));
      expect(chatStore.values.single.draft, 'unsent draft');
      final copyId = find.text('Copy channel ID');
      await tester.ensureVisible(copyId);
      await tester.pump();
      expect(
        tester
            .widget<ListTile>(
              find.ancestor(of: copyId, matching: find.byType(ListTile)),
            )
            .onTap,
        isNull,
      );
      await tester.tap(copyId);
      await tester.pump();
      expect(closed, isEmpty);
      expect(delete, findsOneWidget);
      await tester.drag(
        find.byKey(const ValueKey('buzz-sheet-drag-handle')),
        const Offset(0, 900),
      );
      await tester.pumpAndSettle();
      expect(closed, isEmpty);
      expect(companion.chats, contains(thread));
      expect(chatStore.values.single.draft, 'unsent draft');
      expect(delete, findsNothing);
      expect(find.text('Open actions'), findsOneWidget);
      commit.complete();
      // The widget clock alone does not flush transport cleanup's real-zone
      // continuation; advance both clocks before checking the sheet result.
      for (var attempt = 0; attempt < 30 && closed.isEmpty; attempt++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pumpAndSettle();
      expect(closed, [true]);
      expect(find.text('Open actions'), findsOneWidget);
      expect(delete, findsNothing);
      expect(companion.chat(thread.id), isNull);
      expect(companion.chats, isEmpty);
      expect(chatStore.values, isEmpty);
      expect(client.abortCalls, 0);
      expect(client.disposed, isTrue);
    },
  );

  testWidgets('bound local voice stops before forgetting without host abort', (
    tester,
  ) async {
    final events = <String>[];
    final chatStore = _ChatStore()
      ..onSave = (chats) {
        if (chats.isEmpty) events.add('forgot');
      };
    final client = _Client();
    final companion = CompanionController(
      clientFactory: () => client,
      store: chatStore,
    );
    final thread = await companion.join('synthetic-voice-delete');
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
    final settings = _QuickStore(const SparkSettings());
    await _open(
      tester,
      settings,
      companion: companion,
      channel: channel,
      spark: _StopSpySpark(settings, thread.id, () => events.add('stopped')),
    );
    final delete = find.byKey(const ValueKey('companion-actions-delete-chat'));
    await _tapVisible(tester, delete);
    await tester.tap(find.text('Delete chat').last);
    await tester.pumpAndSettle();
    expect(events, ['stopped', 'forgot']);
    expect(client.abortCalls, 0);
    expect(companion.chat(thread.id), isNull);
  });
}

class _QuickStore implements SparkSettingsStore {
  _QuickStore(this.settings);
  SparkSettings settings;
  Future<StoredSparkSettings>? pendingLoad;
  bool failSave = false;
  int saves = 0;

  @override
  Future<StoredSparkSettings> load() =>
      pendingLoad ??
      Future.value(
        StoredSparkSettings(settings: settings, hasBrokerToken: false),
      );

  @override
  Future<String?> readBrokerToken() async => null;

  @override
  Future<void> save(SparkSettings value, {String? brokerToken}) async {
    if (failSave) {
      throw const SparkStoreException('Spark settings could not be saved.');
    }
    settings = value;
    saves++;
  }
}

class _ChatStore implements ChatStore {
  List<StoredChat> values = [];
  void Function(List<StoredChat>)? onSave;
  bool failSave = false;
  Future<void>? waitNextSave;

  @override
  Future<List<StoredChat>> load() async => List.of(values);

  @override
  Future<void> save(List<StoredChat> chats) async {
    if (failSave) {
      throw const ChatStoreException(
        ChatStoreFailure.io,
        'Encrypted chat store is unavailable.',
      );
    }
    final pending = chats.isEmpty ? waitNextSave : null;
    if (pending != null) {
      waitNextSave = null;
      await pending;
    }
    values = List.of(chats);
    onSave?.call(chats);
  }
}

class _Client implements HarnessClient {
  HarnessSnapshot _snapshot = const HarnessSnapshot();
  int abortCalls = 0;
  bool disposed = false;
  final _changes = StreamController<HarnessSnapshot>.broadcast(sync: true);

  @override
  HarnessSnapshot get snapshot => _snapshot;
  @override
  Stream<HarnessSnapshot> get changes => _changes.stream;
  @override
  Future<void> connect(String input, {String displayName = 'raiju'}) async {
    _snapshot = const HarnessSnapshot(
      phase: ConnectionPhase.live,
      title: 'Local chat',
    );
    _changes.add(_snapshot);
  }

  @override
  Future<void> sendPrompt(String text) async {}
  @override
  Future<void> abort() async => abortCalls++;
  @override
  Future<void> respond(int requestId, String? value) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async {
    disposed = true;
    await _changes.close();
  }
}

class _StopSpySpark extends SparkController {
  _StopSpySpark(SparkSettingsStore store, this.chatId, this.onStop)
    : super(
        session: _NoopSession(),
        credentials: _NoopCredentials(),
        store: store,
        chatBridge: const UnavailableSparkChatBridge(),
      );

  final String chatId;
  final void Function() onStop;

  @override
  SparkSnapshot get snapshot =>
      SparkSnapshot(phase: SparkPhase.listening, boundChatId: chatId);

  @override
  bool get settingsLoaded => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> stop() async => onStop();
}

class _NoopSession implements VoiceSession {
  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();
  @override
  Future<void> dispose() async {}
  @override
  Future<void> sendText(
    String text, {
    String? delegationId,
    String channel = 'speakable',
  }) async {}
  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> start({
    required String accessToken,
    String? accountId,
    required String instructions,
    required String voice,
  }) async {}
  @override
  Future<void> stop() async {}
}

class _NoopCredentials implements SparkCredentialSource {
  @override
  Future<SparkCredentialResult> acquire(
    SparkSettings settings,
    String brokerToken,
  ) async => const SparkCredentialResult(choices: []);
}
