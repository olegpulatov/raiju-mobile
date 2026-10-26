import 'dart:async';

import 'package:raiju_mobile/companion_controller.dart';
import 'package:raiju_mobile/features/channels/channels_page.dart';
import 'package:raiju_mobile/features/channels/channel.dart';
import 'package:raiju_mobile/features/channels/channel_detail_page.dart';
import 'package:raiju_mobile/features/channels/channel_typing_indicator.dart';
import 'package:raiju_mobile/features/channels/channel_typing_provider.dart';
import 'package:raiju_mobile/features/profile/presence_cache_provider.dart';
import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/raiju/chat_avatar_preference.dart';
import 'package:raiju_mobile/raiju/companion_provider.dart';
import 'package:raiju_mobile/shared/profile/user_profile.dart';
import 'package:raiju_mobile/shared/profile/user_cache_provider.dart';
import 'package:raiju_mobile/shared/theme/theme.dart';
import 'package:raiju_mobile/shared/widgets/avatar_image.dart';
import 'package:raiju_mobile/storage/chat_store.dart';
import 'package:raiju_mobile/storage/voice_transcript.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'remote session row keeps the original avatar badge and long-press rows',
    (tester) async {
      final controller = CompanionController(
        clientFactory: () => _FakeClient(_snapshot),
        store: _MemoryStore(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      // Since collabs and remote sessions were grouped, only remote (ompd)
      // sessions use the DM avatar row; collab rows use the channel icon.
      final thread = await controller.join('ompd:synthetic-avatar-capability');

      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            companionControllerProvider.overrideWith((ref) => controller),
            savedPrefsProvider.overrideWithValue(prefs),
            userCacheProvider.overrideWith(_ForbiddenUserCacheNotifier.new),
            presenceCacheProvider.overrideWith(
              _ForbiddenPresenceCacheNotifier.new,
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: ChannelsPage(
              settingsPageBuilder: (_) => const SizedBox.shrink(),
              onSettingsTransitionProgress: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final row = find.byKey(ValueKey('chat-list-item-${thread.id}'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.byType(Stack)),
        findsOneWidget,
      );
      final avatar = find.descendant(
        of: row,
        matching: find.byType(AvatarImage),
      );
      expect(avatar, findsOneWidget);
      final avatarWidget = tester.widget<AvatarImage>(avatar);
      expect(avatarWidget.radius, 9);
      expect(avatarWidget.imageUrl, isNull);
      expect(avatarWidget.isAgent, isTrue);
      expect(
        find.descendant(of: avatar, matching: find.text('O')),
        findsOneWidget,
      );

      final badge = find.byKey(ValueKey('chat-avatar-presence-${thread.id}'));
      expect(badge, findsOneWidget);
      expect(tester.getSize(badge), const Size.square(8));
      final badgeDecoration = tester.widget<Container>(badge).decoration;
      expect(badgeDecoration, isA<BoxDecoration>());
      final badgeBoxDecoration = badgeDecoration as BoxDecoration;
      expect(badgeBoxDecoration.color, tester.element(row).appColors.success);
      expect(badgeBoxDecoration.shape, BoxShape.circle);

      await tester.longPress(row);
      await tester.pumpAndSettle();

      expect(find.text('Mute channel'), findsOneWidget);
      expect(find.text('Copy channel name'), findsOneWidget);
      expect(find.text('Copy channel ID'), findsOneWidget);
      expect(find.text('Disconnect'), findsOneWidget);
    },
  );

  testWidgets('message avatars are hidden by default without an empty column', (
    tester,
  ) async {
    final controller = CompanionController(
      clientFactory: () => _FakeClient(
        HarnessSnapshot(
          phase: ConnectionPhase.live,
          title: _snapshot.title,
          messages: [
            ..._snapshot.messages,
            const ChatMessage(
              id: 'assistant-2',
              role: MessageRole.assistant,
              text: 'Grouped reply',
            ),
            const ChatMessage(
              id: 'user-1',
              role: MessageRole.user,
              text: 'Typed prompt',
            ),
          ],
        ),
      ),
      store: _MemoryStore(),
    );
    addTearDown(controller.dispose);
    final thread = await controller.join('synthetic-message-avatar-capability');
    controller.upsertVoiceTurn(
      thread.id,
      const VoiceTurn(
        id: 'speech',
        sequence: 1,
        origin: VoiceTurnOrigin.user,
        text: 'Spoken prompt',
      ),
    );
    controller.upsertVoiceTurn(
      thread.id,
      const VoiceTurn(
        id: 'spark',
        sequence: 2,
        origin: VoiceTurnOrigin.spark,
        text: 'Voice reply',
      ),
    );
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          companionControllerProvider.overrideWith((ref) => controller),
          savedPrefsProvider.overrideWithValue(prefs),
          userCacheProvider.overrideWith(_ForbiddenUserCacheNotifier.new),
          presenceCacheProvider.overrideWith(
            _ForbiddenPresenceCacheNotifier.new,
          ),
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

    final row = find.byKey(const ValueKey('message-row-assistant-1'));
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.byType(AvatarImage)),
      findsNothing,
    );
    final author = find.byKey(const ValueKey('message-author-assistant-1'));
    expect(author, findsOneWidget);
    expect(tester.getTopLeft(author).dx, tester.getTopLeft(row).dx);
    expect(tester.getTopLeft(find.text('Hello')).dx, tester.getTopLeft(row).dx);
    expect(
      tester.getTopLeft(find.text('Grouped reply')).dx,
      tester.getTopLeft(row).dx,
    );
    for (final name in ['You', 'You · voice', 'Spark']) {
      expect(find.text(name), findsOneWidget);
    }

    final container = ProviderScope.containerOf(tester.element(row));
    await container.read(showChatAvatarsProvider.notifier).setVisible(true);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: row, matching: find.byType(AvatarImage)),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(author).dx - tester.getTopLeft(row).dx,
      messageAvatarSize + messageAvatarContentGap,
    );
    expect(
      tester.getTopLeft(find.text('Grouped reply')).dx,
      tester.getTopLeft(author).dx,
    );
    await container.read(showChatAvatarsProvider.notifier).setVisible(false);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: row, matching: find.byType(AvatarImage)),
      findsNothing,
    );
    expect(tester.getTopLeft(author).dx, tester.getTopLeft(row).dx);
  });

  testWidgets('typing avatars use the same preference without an empty gap', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          savedPrefsProvider.overrideWithValue(prefs),
          userCacheProvider.overrideWith(_TypingUserCacheNotifier.new),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: const Scaffold(
            body: ChannelTypingIndicator(
              entries: [TypingEntry(pubkey: 'alice', expiresAtMs: 999999)],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final indicator = find.byKey(const ValueKey('channel-typing-indicator'));
    final text = find.text('Alice is typing…');
    expect(find.byType(AvatarImage), findsNothing);
    expect(
      tester.getTopLeft(text).dx - tester.getTopLeft(indicator).dx,
      Grid.xxs + 1, // Inner padding plus the existing one-pixel border.
    );
    final container = ProviderScope.containerOf(tester.element(indicator));
    await container.read(showChatAvatarsProvider.notifier).setVisible(true);
    await tester.pumpAndSettle();
    expect(find.byType(AvatarImage), findsOneWidget);
    expect(
      tester.getTopLeft(text).dx - tester.getTopLeft(indicator).dx,
      Grid.xxs + 1 + 24 + Grid.xxs,
    );
  });

  test(
    'avatar preference survives provider and preferences recreation',
    () async {
      SharedPreferences.setMockInitialValues({'buzz_theme_mode': 'dark'});
      var prefs = await SharedPreferences.getInstance();
      var container = ProviderContainer(
        overrides: [savedPrefsProvider.overrideWithValue(prefs)],
      );
      expect(container.read(showChatAvatarsProvider), isFalse);
      await container.read(showChatAvatarsProvider.notifier).setVisible(true);
      container.dispose();

      SharedPreferences.resetStatic();
      prefs = await SharedPreferences.getInstance();
      container = ProviderContainer(
        overrides: [savedPrefsProvider.overrideWithValue(prefs)],
      );
      expect(container.read(showChatAvatarsProvider), isTrue);
      expect(prefs.getString('buzz_theme_mode'), 'dark');
      await container.read(showChatAvatarsProvider.notifier).setVisible(false);
      container.dispose();

      SharedPreferences.resetStatic();
      prefs = await SharedPreferences.getInstance();
      container = ProviderContainer(
        overrides: [savedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      expect(container.read(showChatAvatarsProvider), isFalse);
    },
  );
}

final _snapshot = HarnessSnapshot(
  phase: ConnectionPhase.live,
  title: 'Orchid agent',
  model: 'test-model',
  readOnly: false,
  messages: [
    ChatMessage(
      id: 'assistant-1',
      role: MessageRole.assistant,
      text: 'Hello',
      timestamp: DateTime.utc(2026, 9, 18, 12),
    ),
  ],
);

class _TypingUserCacheNotifier extends UserCacheNotifier {
  @override
  Map<String, UserProfile> build() => const {
    'alice': UserProfile(pubkey: 'alice', displayName: 'Alice'),
  };
}

class _ForbiddenUserCacheNotifier extends UserCacheNotifier {
  @override
  Map<String, UserProfile> build() {
    throw StateError('Buzz user cache must not activate for companion avatars');
  }
}

class _ForbiddenPresenceCacheNotifier extends PresenceCacheNotifier {
  @override
  Map<String, String> build() {
    throw StateError(
      'Buzz presence cache must not activate for companion avatars',
    );
  }
}

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
  List<StoredChat> value = [];

  @override
  Future<List<StoredChat>> load() async => value;

  @override
  Future<void> save(List<StoredChat> chats) async => value = chats;
}
