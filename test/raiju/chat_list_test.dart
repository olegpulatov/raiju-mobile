import 'dart:async';

import 'package:raiju_mobile/companion_controller.dart';
import 'package:raiju_mobile/features/channels/channel_detail_page.dart';
import 'package:raiju_mobile/features/channels/channels_page.dart';
import 'package:raiju_mobile/features/channels/channels_provider.dart';
import 'package:raiju_mobile/features/pairing/pairing_page.dart';
import 'package:raiju_mobile/features/pairing/ompd_pairing_page.dart';
import 'package:raiju_mobile/features/search/search_page.dart';
import 'package:raiju_mobile/features/search/search_provider.dart';
import 'package:raiju_mobile/harness/ompd_connection.dart';
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
      expect(channels.single.channelType, 'stream');
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
    await tester.tap(find.byKey(const Key('quick-action-attach-collab-card')));
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

  test(
    'local search covers restored collabs and remote sessions offline',
    () async {
      final controller = await _groupedController();
      addTearDown(controller.dispose);
      final container = ProviderContainer(
        overrides: [
          companionControllerProvider.overrideWith((ref) => controller),
        ],
      );
      addTearDown(container.dispose);
      final channels = await container.read(channelsProvider.future);
      expect(channels.firstWhere((c) => c.id == 'collab').isDm, isFalse);
      expect(channels.firstWhere((c) => c.id == 'remote').isDm, isTrue);
      final search = container.read(searchProvider.notifier);
      search.search('  OFFLINE  ');
      var results = container.read(searchProvider);
      expect(
        results.channelResults.map((c) => c.id),
        containsAll(['collab', 'remote']),
      );
      expect(
        results.messageResults.map((hit) => hit.channelId),
        containsAll(['collab', 'remote']),
      );
      expect(results.messageResults.every((hit) => hit.isLocal), isTrue);
      expect(results.isLoading, isFalse);
      expect(results.error, isNull);
      search.search('test-model');
      expect(container.read(searchProvider).channelResults, hasLength(2));
      await controller.join('synthetic-added-collab');
      await container.read(channelsProvider.future);
      expect(container.read(searchProvider).query, 'test-model');
      expect(container.read(searchProvider).channelResults, hasLength(3));
      search.search('missing text');
      results = container.read(searchProvider);
      expect(results.channelResults, isEmpty);
      expect(results.messageResults, isEmpty);
      search.search('  ');
      expect(container.read(searchProvider).query, isEmpty);
    },
  );

  testWidgets('saved transports render inside their real groups', (
    tester,
  ) async {
    final controller = await _groupedController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(await _testable(controller));
    await tester.pumpAndSettle();
    final collab = find.byKey(const ValueKey('chat-list-item-collab'));
    final remote = find.byKey(const ValueKey('chat-list-item-remote'));
    expect(collab, findsOneWidget);
    expect(remote, findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Collabs')).dy,
      lessThan(tester.getTopLeft(collab).dy),
    );
    expect(
      tester.getTopLeft(collab).dy,
      lessThan(tester.getTopLeft(find.text('Remote sessions')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Remote sessions')).dy,
      lessThan(tester.getTopLeft(remote).dy),
    );
    await tester.tap(find.text('Collabs'));
    await tester.pumpAndSettle();
    expect(collab.hitTestable(), findsNothing);
    expect(remote.hitTestable(), findsOneWidget);
  });

  testWidgets('relay menu opens start and browse modes independently', (
    tester,
  ) async {
    final controller = await _groupedController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(await _testable(controller));
    await tester.pumpAndSettle();
    for (final entry in {
      'quick-action-add-remote-session-card': OmpdPairingView.start,
      'quick-action-browse-relay-card': OmpdPairingView.browse,
    }.entries) {
      await tester.tap(find.byTooltip('Create or start conversation'));
      await tester.pumpAndSettle();
      expect(find.text('Attach to collab'), findsOneWidget);
      expect(find.text('Add remote session'), findsOneWidget);
      expect(find.text('Browse relay'), findsOneWidget);
      await tester.tap(find.byKey(Key(entry.key)));
      await tester.pumpAndSettle();
      final page = tester.widget<OmpdPairingPage>(find.byType(OmpdPairingPage));
      expect(page.initialView, entry.value);
      Navigator.of(tester.element(find.byType(OmpdPairingPage))).pop();
      await tester.pumpAndSettle();
    }
  });

  testWidgets(
    'production search opens both saved chat and cached message routes',
    (tester) async {
      final controller = await _groupedController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        await _testable(controller, page: const SearchPage()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('search-field')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'offline');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('search-channel-row-collab')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('search-channel-row-remote')),
        findsOneWidget,
      );
      await tester.tap(find.text('Collabs'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('search-channel-row-collab')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('search-channel-row-remote')),
        findsNothing,
      );
      await tester.tap(find.text('Remote sessions'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('search-channel-row-collab')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('search-channel-row-remote')),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'cached');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('search-channel-row-remote')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('search-message-row-remote:cached')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('search-message-row-collab:cached')),
        findsNothing,
      );
      await tester.tap(find.text('Collabs'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('search-channel-row-collab')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('search-message-row-collab:cached')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('search-message-row-remote:cached')),
        findsNothing,
      );
      await tester.enterText(find.byType(TextField), 'offline');
      await tester.pumpAndSettle();
      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('search-channel-row-remote')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChannelDetailPage>(find.byType(ChannelDetailPage))
            .channel
            .id,
        'remote',
      );
      Navigator.of(tester.element(find.byType(ChannelDetailPage))).pop();
      await tester.pumpAndSettle();
      final hit = find.byKey(
        const ValueKey('search-message-row-collab:cached'),
      );
      await tester.ensureVisible(hit);
      await tester.tap(hit);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChannelDetailPage>(find.byType(ChannelDetailPage))
            .channel
            .id,
        'collab',
      );
    },
  );
}

Future<Widget> _testable(CompanionController controller, {Widget? page}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      companionControllerProvider.overrideWith((ref) => controller),
      savedPrefsProvider.overrideWithValue(prefs),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home:
          page ??
          Stack(
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

Future<CompanionController> _groupedController() async {
  final controller = CompanionController(
    clientFactory: () => _FakeClient(_snapshot),
    store: _MemoryStore([
      for (final id in ['collab', 'remote'])
        StoredChat(
          id: id,
          link: id == 'remote'
              ? OmpdConnection(
                  endpoint: OmpdEndpoint.parse('relay.example:7420'),
                  instance: 'fixture',
                  trustedNetwork: false,
                ).encode()
              : 'synthetic-collab-capability',
          label: 'Offline $id',
          localLabel: true,
          draft: '',
          reconnect: false,
          snapshot: StoredSnapshot(
            title: 'Offline $id',
            endpoint: '',
            model: 'test-model',
            messages: [
              ChatMessage(
                id: 'cached',
                role: MessageRole.assistant,
                text: 'Offline cached $id answer',
                timestamp: DateTime.utc(2026, 10, 3),
              ),
            ],
            readOnly: false,
          ),
        ),
    ]),
  );
  await controller.initialize();
  return controller;
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
