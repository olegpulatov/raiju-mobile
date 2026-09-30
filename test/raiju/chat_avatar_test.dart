import 'dart:async';

import 'package:buzz/companion_controller.dart';
import 'package:buzz/features/channels/channels_page.dart';
import 'package:buzz/features/profile/presence_cache_provider.dart';
import 'package:buzz/harness/harness.dart';
import 'package:buzz/raiju/companion_provider.dart';
import 'package:buzz/shared/profile/user_profile.dart';
import 'package:buzz/shared/profile/user_cache_provider.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:buzz/shared/widgets/avatar_image.dart';
import 'package:buzz/storage/chat_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'companion chat keeps the original avatar badge and long-press rows',
    (tester) async {
      final controller = CompanionController(
        clientFactory: () => _FakeClient(_snapshot),
        store: _MemoryStore(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final thread = await controller.join('synthetic-avatar-capability');

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
