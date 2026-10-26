import 'dart:async';
import 'dart:io';

import 'package:raiju_mobile/app.dart';
import 'package:raiju_mobile/companion_controller.dart';
import 'package:raiju_mobile/features/channels/jump_to_latest_button.dart';
import 'package:raiju_mobile/features/profile/profile_avatar.dart';
import 'package:raiju_mobile/features/settings/settings_page.dart';
import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/raiju/companion_provider.dart';
import 'package:raiju_mobile/shared/theme/community_theme_provider.dart';
import 'package:raiju_mobile/shared/theme/theme_provider.dart';
import 'package:raiju_mobile/shared/widgets/avatar_image.dart';
import 'package:raiju_mobile/storage/encrypted_file_chat_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('original app connects, talks, goes offline, and restores', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final support = await getApplicationSupportDirectory();
    final testId = DateTime.now().toUtc().microsecondsSinceEpoch;
    final file = File('${support.path}/raiju-integration-$testId.enc');
    final keyName = 'raiju.integration.$testId';
    const secureStorage = FlutterSecureStorage();
    addTearDown(() async {
      if (await file.exists()) await file.delete();
      await secureStorage.delete(key: keyName);
    });
    final store = EncryptedFileChatStore(
      ciphertext: AppSupportCiphertextBackend(file, protect: (_) async {}),
      keys: SecureStorageChatKeyBackend(secureStorage, keyName: keyName),
    );
    final client = _FixtureClient();
    final controller = CompanionController(
      clientFactory: () => client,
      store: store,
    );
    var controllerDisposed = false;
    addTearDown(() async {
      if (controllerDisposed) return;
      try {
        await controller.flush();
      } catch (_) {
        // Cleanup must still stop timers and clients after an assertion failure.
      }
      controller.dispose();
    });
    await controller.initialize();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          savedPrefsProvider.overrideWithValue(preferences),
          companionControllerProvider.overrideWith((ref) => controller),
        ],
        child: const App(),
      ),
    );
    await _pumpUntil(tester, find.byKey(const Key('connect-omp-session')));

    await _tapWhenHittable(
      tester,
      find.byKey(const Key('connect-omp-session')),
    );
    await _pumpUntil(tester, find.byKey(const ValueKey('raiju-paste-toggle')));
    await _tapWhenHittable(
      tester,
      find.byKey(const ValueKey('raiju-paste-toggle')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('raiju-join-input')),
      'synthetic-fixture-capability',
    );
    await _tapWhenHittable(
      tester,
      find.byKey(const ValueKey('raiju-join-submit')),
    );
    await _pumpUntil(tester, find.text('Message…'));
    await _tapWhenHittable(tester, find.text('Message…'));
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('raiju-composer-input')),
    );

    const prompt = 'fixture ping';
    await tester.enterText(
      find.byKey(const ValueKey('raiju-composer-input')),
      prompt,
    );
    await _pumpUntilEnabledIconButton(tester, const ValueKey('raiju-send'));
    await _tapWhenHittable(tester, find.byKey(const ValueKey('raiju-send')));
    await _pumpUntil(tester, find.text('fixture pong'));
    expect(
      find.byKey(const ValueKey('message-row-assistant-1')),
      findsOneWidget,
    );
    expect(client.sent, [prompt]);

    FocusManager.instance.primaryFocus?.unfocus();
    await _pumpFrames(tester);
    await _checkChatAvatars(tester, binding, controller.chats.single.id);
    await _checkMessageSelection(tester, binding);
    await _checkDetachedReading(tester, client);

    const savedDraft = 'draft survives restart';
    // Send successive editing updates faster than the 400 ms idle debounce.
    // The unchanged encrypted-store recreation below must retain the final text.
    final composer = find.byKey(const ValueKey('raiju-composer-input'));
    for (var length = 1; length <= savedDraft.length; length++) {
      await tester.enterText(composer, savedDraft.substring(0, length));
      await tester.pump(const Duration(milliseconds: 5));
    }
    await tester.pump(const Duration(milliseconds: 450));
    expect(controller.chats.single.draft, savedDraft);
    expect(
      (await store.load()).single.draft,
      savedDraft,
      reason: 'Idle debounce must reach encrypted storage before any flush.',
    );
    expect(client.sent, [prompt], reason: 'Typing a draft must not send it.');
    client.emit(client.snapshot.copyWith(readOnly: true));
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('raiju-send')))
          .onPressed,
      isNull,
    );
    client.emit(
      client.snapshot.copyWith(
        phase: ConnectionPhase.disconnected,
        readOnly: false,
      ),
    );
    await tester.pump();
    expect(find.textContaining('Disconnected'), findsWidgets);
    await controller.flush();

    await tester.pumpWidget(const SizedBox.shrink());
    controllerDisposed = true;
    controller.dispose();

    final restoredClient = _FixtureClient(blockConnect: true);
    final restored = CompanionController(
      clientFactory: () => restoredClient,
      store: EncryptedFileChatStore(
        ciphertext: AppSupportCiphertextBackend(
          File(file.path),
          protect: (_) async {},
        ),
        keys: SecureStorageChatKeyBackend(
          const FlutterSecureStorage(),
          keyName: keyName,
        ),
      ),
    );
    var restoredDisposed = false;
    addTearDown(() async {
      if (restoredDisposed) return;
      try {
        await restored.flush();
      } catch (_) {
        // Cleanup must still stop timers and clients after an assertion failure.
      }
      restored.dispose();
    });
    await restored.initialize();
    expect(restored.chats, hasLength(1));
    expect(restored.chats.single.draft, savedDraft);
    expect(restored.chats.single.snapshot.messages.last.text, 'fixture pong');
    expect(restoredClient.connectedInput, 'synthetic-fixture-capability');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          savedPrefsProvider.overrideWithValue(preferences),
          companionControllerProvider.overrideWith((ref) => restored),
        ],
        child: const App(),
      ),
    );
    final row = find.byKey(
      ValueKey('chat-list-item-${restored.chats.single.id}'),
    );
    await _pumpUntil(tester, row);
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
    }
    await _captureAppearanceScreenshots(
      tester,
      binding,
      anchor: row,
      lightName: 'raiju-home-light',
      darkName: 'raiju-home-dark',
    );
    await _tapWhenHittable(tester, row);
    await _pumpUntil(tester, find.text(savedDraft));
    expect(find.byKey(const ValueKey('raiju-composer-input')), findsNothing);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('raiju-send')))
          .onPressed,
      isNull,
    );
    expect(find.text('fixture pong'), findsOneWidget);
    await _captureAppearanceScreenshots(
      tester,
      binding,
      anchor: find.text('fixture pong'),
      lightName: 'raiju-chat-light',
      darkName: 'raiju-chat-dark',
    );
    await restored.flush();
    await tester.pumpWidget(const SizedBox.shrink());
    restoredDisposed = true;
    restored.dispose();
  });
}

Future<void> _pumpFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _checkChatAvatars(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  String chatId,
) async {
  final row = find.byKey(const ValueKey('message-row-assistant-1'));
  final avatar = find.descendant(of: row, matching: find.byType(AvatarImage));
  expect(avatar, findsNothing);
  for (final visible in [true, false]) {
    await Navigator.of(tester.element(row)).maybePop();
    final chat = find.byKey(ValueKey('chat-list-item-$chatId'));
    await _pumpUntil(tester, chat);
    await _tapWhenHittable(tester, find.byType(ProfileAvatar).first);
    await _pumpUntil(tester, find.byType(SettingsPage));
    final setting = find.byKey(const ValueKey('settings-chat-avatars'));
    await _pumpFrames(tester);
    await tester.scrollUntilVisible(
      setting,
      200,
      scrollable: find
          .descendant(
            of: find.byType(SettingsPage),
            matching: find.byType(Scrollable),
          )
          .last,
    );
    await _pumpFrames(tester);
    expect(find.text('Interface'), findsOneWidget);
    expect(find.text('Show avatars in chats'), findsOneWidget);
    final toggle = find.descendant(of: setting, matching: find.byType(Switch));
    expect(tester.widget<Switch>(toggle).value, !visible);
    await _tapWhenHittable(tester, toggle);
    await _pumpFrames(tester);
    expect(tester.widget<Switch>(toggle).value, visible);
    Navigator.of(tester.element(setting)).pop();
    await _tapWhenHittable(tester, chat);
    await _pumpUntil(tester, row);
    await _pumpUntilRouteTransitionCompleted(tester, row);
    expect(avatar, visible ? findsOneWidget : findsNothing);
    if (visible) await binding.takeScreenshot('raiju-chat-avatars-on');
  }
}

Future<void> _checkMessageSelection(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  final text = find.byWidgetPredicate(
    (widget) =>
        widget is RichText && widget.text.toPlainText() == 'fixture pong',
  );
  final paragraph = tester.renderObject<RenderParagraph>(text);
  final word = paragraph
      .getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 7))
      .first;
  await tester.longPressAt(paragraph.localToGlobal(word.toRect().center));
  await _pumpFrames(tester);
  expect(
    paragraph.selections.single.textInside(paragraph.text.toPlainText()),
    'fixture',
  );
  expect(find.text('Copy'), findsOneWidget);
  expect(find.text('More'), findsOneWidget);
  final actions = find.byKey(const ValueKey('message-actions-backdrop-filter'));
  expect(actions, findsNothing);
  await binding.takeScreenshot('raiju-message-selection');
  await _tapWhenHittable(tester, find.text('More'));
  await _pumpUntil(tester, actions);
  // Simulator retains the real UIKit surface, unlike plugin-free widget tests.
  expect(
    find.byKey(const ValueKey('ios-native-message-action-surface')),
    findsOneWidget,
  );
  expect(find.byKey(const ValueKey('quick-reaction-more')), findsOneWidget);
  await _pumpFrames(tester);
  await binding.takeScreenshot('raiju-message-actions');
  expect(paragraph.selections, isEmpty);
  Navigator.of(tester.element(actions)).pop();
  await _pumpFrames(tester);
  expect(actions, findsNothing);
}

Future<void> _checkDetachedReading(
  WidgetTester tester,
  _FixtureClient client,
) async {
  final original = client.snapshot;
  final messages = [
    for (var index = 0; index < 40; index++)
      ChatMessage(
        id: 'history-$index',
        role: index.isEven ? MessageRole.user : MessageRole.assistant,
        text: 'Synthetic history row $index\nSecond line',
      ),
    const ChatMessage(
      id: 'streaming-tail',
      role: MessageRole.assistant,
      text: 'Streaming line',
      isStreaming: true,
    ),
  ];
  void emit({bool streaming = true}) => client.emit(
    original.copyWith(messages: List.of(messages), isStreaming: streaming),
  );
  emit();
  await _pumpFrames(tester);
  final list = find.byKey(const ValueKey('channel-message-list'));
  // A reversed chat list moves toward older history with a downward finger drag.
  await tester.drag(list, const Offset(0, 320));
  await _pumpFrames(tester);
  final listRect = tester.getRect(list);
  final rows = find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        (widget.key as ValueKey<String>).value.startsWith(
          'message-row-history-',
        ),
  );
  final reference = rows
      .evaluate()
      .map((element) {
        return find.byKey(element.widget.key!);
      })
      .firstWhere((row) {
        final rect = tester.getRect(row);
        return rect.top > listRect.top + 80 && rect.bottom < listRect.center.dy;
      });
  final y = tester.getTopLeft(reference).dy;
  Future<void> expectAnchored(String reason) async {
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 25));
      expect(tester.getTopLeft(reference).dy, closeTo(y, 1), reason: reason);
    }
  }

  for (var update = 1; update <= 6; update++) {
    messages.last = ChatMessage(
      id: 'streaming-tail',
      role: MessageRole.assistant,
      text: List.filled(
        update * 3,
        'Synthetic streaming line $update',
      ).join('\n'),
      isStreaming: true,
    );
    emit();
    await expectAnchored('Streaming growth must not move detached history.');
  }
  messages.add(
    const ChatMessage(
      id: 'appended-tail',
      role: MessageRole.assistant,
      text: 'Synthetic new response',
    ),
  );
  emit(streaming: false);
  await expectAnchored('A new message must not move detached history.');
  final jump = find.byKey(const ValueKey('channel-jump-to-latest'));
  expect(jump, findsOneWidget);
  await _tapWhenHittable(tester, find.text('Message…'));
  await expectAnchored('Opening composer must retain the same global y.');
  final composer = find.byKey(const ValueKey('raiju-composer-input'));
  await _pumpUntil(tester, composer);
  await tester.tap(composer);
  await tester.enterText(composer, 'Detached draft\nSecond line\nThird line');
  await expectAnchored('Keyboard and typing must retain the same global y.');
  expect(tester.widget<TextField>(composer).focusNode!.hasFocus, isTrue);
  expect(jump, findsOneWidget);
  // Flutter's tester cannot synthesize touches inside UIKit platform views.
  // Invoke the mounted native button's Dart callback, like native back above:
  // this checks the navigation seam, not UIKit touch delivery/hit testing.
  tester.widget<JumpToLatestButton>(jump).onPressed();
  await _pumpFrames(tester);
  final latestRow = find.byKey(const ValueKey('message-row-appended-tail'));
  expect(latestRow, findsOneWidget);
  final latest = find
      .ancestor(
        of: latestRow,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key as ValueKey<String>).value.startsWith(
                'channel-message-group-',
              ),
        ),
      )
      .first;
  final dock = find.byKey(const ValueKey('channel-composer-dock'));
  expect(
    tester.getBottomLeft(latest).dy,
    closeTo(tester.getTopLeft(dock).dy, 1),
    reason: 'Jump to latest must return to the bottom boundary.',
  );
  expect(jump, findsNothing);
  // Keep the existing restore and appearance checks on their original fixture.
  await tester.enterText(composer, '');
  client.emit(original);
  await _pumpFrames(tester);
}

Future<void> _captureAppearanceScreenshots(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required Finder anchor,
  required String lightName,
  required String darkName,
}) async {
  final scope = ProviderScope.containerOf(
    tester.element(anchor.first),
    listen: false,
  );
  final original = scope.read(communityThemeProvider);
  final notifier = scope.read(communityThemeProvider.notifier);
  await _pumpUntilRouteTransitionCompleted(tester, anchor);
  try {
    notifier.setMode(ThemeMode.light);
    await _pumpUntilBrightness(tester, anchor, Brightness.light);
    await binding.takeScreenshot(lightName);

    notifier.setMode(ThemeMode.dark);
    await _pumpUntilBrightness(tester, anchor, Brightness.dark);
    await binding.takeScreenshot(darkName);
  } finally {
    notifier.setPreference(original);
    await notifier.flush();
    // Use a bounded number of frames: the app has repeating animations, so
    // pumpAndSettle is not a safe rendering barrier.
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
}

Future<void> _pumpUntilRouteTransitionCompleted(
  WidgetTester tester,
  Finder anchor, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final animation = ModalRoute.of(tester.element(anchor.first))?.animation;
    if (animation == null || animation.status == AnimationStatus.completed) {
      await tester.pump(const Duration(milliseconds: 100));
      return;
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(
    ModalRoute.of(tester.element(anchor.first))?.animation?.status,
    AnimationStatus.completed,
    reason: 'Timed out waiting for screenshot route transition.',
  );
}

Future<void> _pumpUntilBrightness(
  WidgetTester tester,
  Finder anchor,
  Brightness brightness, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (anchor.evaluate().isNotEmpty &&
        Theme.of(tester.element(anchor.first)).brightness == brightness) {
      // Give retained original widgets two more frames to paint in the new
      // appearance without waiting on unrelated animations.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      return;
    }
  }
  expect(
    Theme.of(tester.element(anchor.first)).brightness,
    brightness,
    reason: 'Timed out waiting for screenshot appearance.',
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsWidgets);
}

Future<void> _tapWhenHittable(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (finder.hitTestable().evaluate().isEmpty &&
      DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  final hittable = finder.hitTestable();
  expect(hittable, findsWidgets);
  await tester.tap(hittable.first);
}

Future<void> _pumpUntilEnabledIconButton(
  WidgetTester tester,
  Key key, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final finder = find.byKey(key);
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final widgets = finder.evaluate();
    if (widgets.isNotEmpty &&
        tester.widget<IconButton>(finder).onPressed != null) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(
    tester.widget<IconButton>(finder).onPressed,
    isNotNull,
    reason: 'Timed out waiting for enabled icon button.',
  );
}

class _FixtureClient implements HarnessClient {
  _FixtureClient({this.blockConnect = false});

  final bool blockConnect;
  final sent = <String>[];
  String? connectedInput;
  final _changes = StreamController<HarnessSnapshot>.broadcast(sync: true);
  HarnessSnapshot _snapshot = const HarnessSnapshot();

  @override
  HarnessSnapshot get snapshot => _snapshot;

  @override
  Stream<HarnessSnapshot> get changes => _changes.stream;

  @override
  Future<void> connect(String input, {String displayName = 'raiju'}) async {
    connectedInput = input;
    if (blockConnect) return Completer<void>().future;
    emit(
      const HarnessSnapshot(
        phase: ConnectionPhase.live,
        title: 'Fixture OMP chat',
        endpoint: 'wss://fixture.invalid',
        model: 'fixture-model',
        readOnly: false,
      ),
    );
  }

  @override
  Future<void> sendPrompt(String text) async {
    sent.add(text);
    emit(
      HarnessSnapshot(
        phase: ConnectionPhase.live,
        title: 'Fixture OMP chat',
        endpoint: 'wss://fixture.invalid',
        model: 'fixture-model',
        readOnly: false,
        isStreaming: true,
        messages: [
          ChatMessage(id: 'user-1', role: MessageRole.user, text: text),
          const ChatMessage(
            id: 'assistant-1',
            role: MessageRole.assistant,
            text: 'fixture po',
            isStreaming: true,
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    emit(
      HarnessSnapshot(
        phase: ConnectionPhase.live,
        title: 'Fixture OMP chat',
        endpoint: 'wss://fixture.invalid',
        model: 'fixture-model',
        readOnly: false,
        messages: [
          ChatMessage(id: 'user-1', role: MessageRole.user, text: text),
          const ChatMessage(
            id: 'assistant-1',
            role: MessageRole.assistant,
            text: 'fixture pong',
          ),
        ],
      ),
    );
  }

  void emit(HarnessSnapshot value) {
    _snapshot = value;
    _changes.add(value);
  }

  @override
  Future<void> abort() async {}

  @override
  Future<void> respond(int requestId, String? value) async {}

  @override
  Future<void> disconnect() async {
    emit(_snapshot.copyWith(phase: ConnectionPhase.disconnected));
  }

  @override
  Future<void> dispose() async {
    await _changes.close();
  }
}

extension on HarnessSnapshot {
  HarnessSnapshot copyWith({
    ConnectionPhase? phase,
    bool? readOnly,
    List<ChatMessage>? messages,
    bool? isStreaming,
  }) => HarnessSnapshot(
    phase: phase ?? this.phase,
    title: title,
    sessionId: sessionId,
    endpoint: endpoint,
    model: model,
    messages: messages ?? this.messages,
    readOnly: readOnly ?? this.readOnly,
    isStreaming: isStreaming ?? this.isStreaming,
    activity: activity,
    error: error,
    questions: questions,
  );
}
