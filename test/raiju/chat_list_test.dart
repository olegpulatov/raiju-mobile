import 'dart:async';

import 'package:raiju_mobile/companion_controller.dart';
import 'package:raiju_mobile/features/channels/channel_detail_page.dart';
import 'package:raiju_mobile/features/channels/channels_page.dart';
import 'package:raiju_mobile/features/channels/channels_provider.dart';
import 'package:raiju_mobile/features/pairing/pairing_page.dart';
import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/raiju/companion_provider.dart';
import 'package:raiju_mobile/shared/theme/theme.dart';
import 'package:raiju_mobile/storage/chat_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'production adapter maps restored sessions without Nostr identities',
    () async {
      final store = _MemoryStore([
        StoredChat(
          id: 'saved-1',
          link: 'synthetic-saved-capability',
          label: 'Saved OMP session',
          draft: 'remembered draft',
          reconnect: false,
          snapshot: StoredSnapshot(
            title: _snapshot.title,
            endpoint: _snapshot.endpoint,
            model: _snapshot.model,
            messages: _snapshot.messages,
            readOnly: _snapshot.readOnly,
          ),
        ),
      ]);
      final controller = CompanionController(
        clientFactory: () => _FakeClient(_snapshot),
        store: store,
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      final container = ProviderContainer(
        overrides: [
          companionControllerProvider.overrideWith((ref) => controller),
        ],
      );
      addTearDown(container.dispose);

      final channels = await container.read(channelsProvider.future);
      expect(channels, hasLength(1));
      expect(channels.single.id, 'saved-1');
      expect(channels.single.channelType, 'dm');
      expect(channels.single.visibility, 'private');
      expect(channels.single.isMember, isTrue);
      expect(channels.single.participantPubkeys, ['local', 'assistant']);
      expect(channels.single.lastMessageAt, DateTime.utc(2026, 9, 18, 12));
    },
  );

  test(
    'storage failure remains an error instead of a fake empty list',
    () async {
      final controller = CompanionController(
        clientFactory: () => _FakeClient(_snapshot),
        store: _FailingStore(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          companionControllerProvider.overrideWith((ref) => controller),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(channelsProvider.future),
        throwsStateError,
      );
    },
  );

  testWidgets('empty list opens original pairing route', (tester) async {
    final controller = CompanionController(
      clientFactory: () => _FakeClient(_snapshot),
      store: _MemoryStore(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(await _testable(controller));
    await tester.pumpAndSettle();
    expect(find.text('No conversations yet'), findsOneWidget);

    await tester.tap(find.byKey(const Key('connect-omp-session')));
    await tester.pumpAndSettle();
    expect(find.byType(PairingPage), findsOneWidget);
  });

  testWidgets('saved chat row opens the existing detail page', (tester) async {
    final controller = CompanionController(
      clientFactory: () => _FakeClient(_snapshot),
      store: _MemoryStore(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final thread = await controller.join('synthetic-test-capability');

    await tester.pumpWidget(await _testable(controller));
    await tester.pumpAndSettle();
    final row = find.byKey(ValueKey('chat-list-item-${thread.id}'));
    expect(row, findsOneWidget);

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(ChannelDetailPage), findsOneWidget);
  });
  testWidgets('populated list quick action opens connection route', (
    tester,
  ) async {
    final controller = CompanionController(
      clientFactory: () => _FakeClient(_snapshot),
      store: _MemoryStore(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.join('synthetic-test-capability');

    await tester.pumpWidget(await _testable(controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Create or start conversation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect OMP session'));
    await tester.pumpAndSettle();

    final page = tester.widget<PairingPage>(find.byType(PairingPage));
    expect(page.addingCommunity, isTrue);
  });

  testWidgets('save failure keeps restored chats and shows the error', (
    tester,
  ) async {
    final store = _SaveFailingStore([
      StoredChat(
        id: 'saved-1',
        link: 'synthetic-saved-capability',
        label: 'Saved OMP session',
        draft: '',
        reconnect: false,
        snapshot: StoredSnapshot(
          title: _snapshot.title,
          endpoint: _snapshot.endpoint,
          model: _snapshot.model,
          messages: _snapshot.messages,
          readOnly: _snapshot.readOnly,
        ),
      ),
    ]);
    final controller = CompanionController(
      clientFactory: () => _FakeClient(_snapshot),
      store: store,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.updateDraft('saved-1', 'retained draft');
    await expectLater(controller.flush(), throwsA(isA<ChatStoreException>()));
    expect(controller.storageError, isNotNull);

    await tester.pumpWidget(await _testable(controller));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('chat-list-item-saved-1')),
      findsOneWidget,
    );
    expect(find.text('Could not save chats.'), findsOneWidget);
  });
}

Future<Widget> _testable(CompanionController controller) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      companionControllerProvider.overrideWith((ref) => controller),
      savedPrefsProvider.overrideWithValue(prefs),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Stack(
        children: [
          ChannelsPage(
            settingsPageBuilder: (_) => const SizedBox.shrink(),
            onSettingsTransitionProgress: (_) {},
          ),
          const Positioned.fill(
            child: ChannelQuickActionsLauncher(
              visible: true,
              navigationBarHeight: 60,
              navigationBarBottomGap: 12,
              navigationBarWidth: 218,
              systemBottomInset: 0,
              rightInset: 16,
            ),
          ),
        ],
      ),
    ),
  );
}

final _snapshot = HarnessSnapshot(
  phase: ConnectionPhase.live,
  title: 'Saved OMP session',
  model: 'test-model',
  readOnly: false,
  messages: [
    ChatMessage(
      id: 'assistant-1',
      role: MessageRole.assistant,
      text: 'Hello from OMP',
      timestamp: DateTime.utc(2026, 9, 18, 12),
    ),
  ],
);

class _FakeClient implements HarnessClient {
  _FakeClient(this.connectedSnapshot);

  final HarnessSnapshot connectedSnapshot;
  final _changes = StreamController<HarnessSnapshot>.broadcast(sync: true);
  HarnessSnapshot _snapshot = const HarnessSnapshot();

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
  Future<void> abort() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() => _changes.close();

  @override
  Future<void> respond(int requestId, String? value) async {}

  @override
  Future<void> sendPrompt(String text) async {}
}

class _MemoryStore implements ChatStore {
  _MemoryStore([List<StoredChat>? initial]) : value = initial ?? [];

  List<StoredChat> value;

  @override
  Future<List<StoredChat>> load() async => value;

  @override
  Future<void> save(List<StoredChat> chats) async => value = chats;
}

class _SaveFailingStore implements ChatStore {
  _SaveFailingStore(this.value);

  final List<StoredChat> value;

  @override
  Future<List<StoredChat>> load() async => value;

  @override
  Future<void> save(List<StoredChat> chats) async =>
      throw const ChatStoreException(
        ChatStoreFailure.io,
        'Could not save chats.',
      );
}

class _FailingStore implements ChatStore {
  @override
  Future<List<StoredChat>> load() async => throw const ChatStoreException(
    ChatStoreFailure.corrupt,
    'Saved chat data is corrupt.',
  );

  @override
  Future<void> save(List<StoredChat> chats) async {}
}
