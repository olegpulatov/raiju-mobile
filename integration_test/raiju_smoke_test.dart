import 'dart:async';
import 'dart:io';

import 'package:raiju_mobile/app.dart';
import 'package:raiju_mobile/companion_controller.dart';
import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/raiju/companion_provider.dart';
import 'package:raiju_mobile/shared/theme/community_theme_provider.dart';
import 'package:raiju_mobile/shared/theme/theme_provider.dart';
import 'package:raiju_mobile/storage/encrypted_file_chat_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/material.dart';
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
      writeDebounce: Duration.zero,
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

    const savedDraft = 'draft survives restart';
    await tester.enterText(
      find.byKey(const ValueKey('raiju-composer-input')),
      savedDraft,
    );
    await tester.pump();
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
      writeDebounce: Duration.zero,
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
  HarnessSnapshot copyWith({ConnectionPhase? phase, bool? readOnly}) =>
      HarnessSnapshot(
        phase: phase ?? this.phase,
        title: title,
        sessionId: sessionId,
        endpoint: endpoint,
        model: model,
        messages: messages,
        readOnly: readOnly ?? this.readOnly,
        isStreaming: isStreaming,
        activity: activity,
        error: error,
        questions: questions,
      );
}
