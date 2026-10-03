import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:raiju_mobile/app.dart';
import 'package:raiju_mobile/companion_controller.dart';
import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/harness/omp_collab_client.dart';
import 'package:raiju_mobile/harness/ompd_client.dart';
import 'package:raiju_mobile/harness/ompd_connection.dart';
import 'package:raiju_mobile/raiju/companion_provider.dart';
import 'package:raiju_mobile/shared/theme/community_theme_provider.dart';
import 'package:raiju_mobile/shared/theme/theme_provider.dart';
import 'package:raiju_mobile/storage/encrypted_file_chat_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/helpers/ompd_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('optional daemon uses TCP through preserved app and restores', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final fixture = await OmpdFixture.start();
    addTearDown(fixture.close);
    final support = await getApplicationSupportDirectory();
    final testId = DateTime.now().toUtc().microsecondsSinceEpoch;
    final file = File('${support.path}/raiju-ompd-integration-$testId.enc');
    final keyName = 'raiju.ompd.integration.$testId';
    const secureStorage = FlutterSecureStorage();
    addTearDown(() async {
      if (await file.exists()) await file.delete();
      await secureStorage.delete(key: keyName);
    });

    EncryptedFileChatStore newStore() => EncryptedFileChatStore(
      // Use isolated test ciphertext, never overwrite normal saved chats.
      // Native protection permits only the production file name; this fixture
      // tests AES-GCM/Keychain recreation, not iOS file-protection migration.
      ciphertext: AppSupportCiphertextBackend(
        File(file.path),
        protect: (_) async {},
      ),
      keys: SecureStorageChatKeyBackend(
        const FlutterSecureStorage(),
        keyName: keyName,
      ),
    );

    CompanionController newController(EncryptedFileChatStore store) =>
        CompanionController(
          clientFactory: () => OmpCollabClient(),
          connectionClientFactory: (input) =>
              OmpdConnection.isOmpd(input) ? OmpdClient() : OmpCollabClient(),
          store: store,
          writeDebounce: Duration.zero,
        );

    final store = newStore();
    final controller = newController(store);
    var controllerDisposed = false;
    addTearDown(() async {
      if (!controllerDisposed) {
        try {
          await controller.flush();
        } finally {
          controller.dispose();
        }
      }
    });
    await controller.initialize();
    expect(controller.storageError, isNull);
    expect(controller.chats, isEmpty);

    Future<void> showApp(CompanionController owner) => tester.pumpWidget(
      ProviderScope(
        overrides: [
          savedPrefsProvider.overrideWithValue(preferences),
          companionControllerProvider.overrideWith((ref) => owner),
        ],
        child: const App(),
      ),
    );

    await showApp(controller);
    final connect = find.byKey(const Key('connect-omp-session'));
    await _until(tester, connect);
    expect(find.text('Log in'), findsNothing);
    expect(find.text('Sign in'), findsNothing);
    expect(fixture.controlRequests, isEmpty);
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
    }
    await _appearances(
      tester,
      binding,
      anchor: connect,
      lightName: 'ompd-home-light',
      darkName: 'ompd-home-dark',
    );

    await _openDaemon(tester);
    await tester.enterText(_key('ompd-endpoint'), fixture.endpoint);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.widget<CheckboxListTile>(_key('ompd-consent')).value,
      isFalse,
    );
    expect(
      tester.widget<OutlinedButton>(_key('ompd-refresh')).onPressed,
      isNull,
    );
    await _scrollTo(tester, _key('ompd-start'));
    expect(tester.widget<FilledButton>(_key('ompd-start')).onPressed, isNull);
    expect(fixture.controlRequests, isEmpty);
    await _scrollTo(tester, _key('ompd-endpoint'));
    await _screenshot(
      tester,
      binding,
      _key('ompd-endpoint'),
      'ompd-relay-consent',
    );

    await _scrollTo(tester, _key('ompd-consent'));
    await _tap(tester, _key('ompd-consent'));
    await _scrollTo(tester, _key('ompd-refresh'));
    await _tap(tester, _key('ompd-refresh'));
    final existingAttach = _key('ompd-attach-${OmpdFixture.existingName}');
    await _condition(
      tester,
      () =>
          tester.widget<OutlinedButton>(_key('ompd-refresh')).onPressed != null,
    );
    await _scrollTo(tester, existingAttach);
    expect(fixture.starts, isEmpty);
    expect(fixture.controlRequests.single['method'], 'status');
    await _screenshot(tester, binding, existingAttach, 'ompd-instance-list');
    await _tap(tester, existingAttach);
    await _until(tester, find.text('synthetic history'));
    expect(controller.chats, hasLength(1));
    final existingId = controller.chats.single.id;
    expect(controller.chat(existingId)!.client, isA<OmpdClient>());
    expect(
      controller.chat(existingId)!.snapshot.sessionId,
      OmpdFixture.existingSessionId,
    );
    expect(fixture.attachments, [OmpdFixture.existingName]);
    expect(fixture.starts, isEmpty);

    await _tap(tester, find.text('Message…'));
    await _until(tester, _key('raiju-composer-input'));
    const prompt = 'synthetic relay ping';
    await tester.enterText(_key('raiju-composer-input'), prompt);
    await _enabledSend(tester);
    await _tap(tester, _key('raiju-send'));
    await _until(tester, find.text(OmpdFixture.partialReply));
    expect(fixture.prompts, [prompt]);
    expect(fixture.hasPendingPrompt, isTrue);
    expect(controller.chat(existingId)!.snapshot.isStreaming, isTrue);
    FocusManager.instance.primaryFocus?.unfocus();
    await _screenshot(
      tester,
      binding,
      find.text(OmpdFixture.partialReply),
      'ompd-streaming-chat',
    );
    fixture.finishPrompt();
    await _until(tester, find.text(OmpdFixture.finalReply));
    await _condition(
      tester,
      () => !controller.chat(existingId)!.snapshot.isStreaming,
    );
    const draft = 'synthetic draft survives recreation';
    await _tap(tester, find.text('Message…'));
    await _until(tester, _key('raiju-composer-input'));
    await tester.enterText(_key('raiju-composer-input'), draft);
    await tester.pump();
    await controller.flush();
    await _home(tester, find.text(OmpdFixture.finalReply), existingId);

    // A new session is an explicit start with no resume selector, then status
    // readiness and attach. No RPC new_session is invented.
    await _openDaemon(tester);
    expect(
      tester.widget<TextField>(_key('ompd-endpoint')).controller!.text,
      fixture.endpoint,
    );
    expect(
      tester.widget<CheckboxListTile>(_key('ompd-consent')).value,
      isFalse,
    );
    await _tap(tester, _key('ompd-consent'));
    await _enterForm(tester, 'ompd-name', OmpdFixture.newName);
    await _enterForm(tester, 'ompd-profile', 'synthetic-profile');
    await _enterForm(tester, 'ompd-cwd', '/synthetic/workspace');
    await _scrollTo(tester, _key('ompd-session'));
    expect(
      tester.widget<TextField>(_key('ompd-session')).controller!.text,
      isEmpty,
    );
    await _scrollTo(tester, _key('ompd-start'));
    await _tap(tester, _key('ompd-start'));
    await _until(tester, find.text('Message…'));
    expect(controller.chats, hasLength(2));
    final newChat = controller.chats.firstWhere(
      (chat) => chat.id != existingId,
    );
    final newId = newChat.id;
    expect(newChat.snapshot.sessionId, OmpdFixture.newSessionId);
    expect(fixture.starts, hasLength(1));
    expect(fixture.starts.single['name'], OmpdFixture.newName);
    expect(fixture.starts.single['profile'], 'synthetic-profile');
    expect(fixture.starts.single['cwd'], '/synthetic/workspace');
    expect(fixture.starts.single.containsKey('session'), isFalse);
    expect(fixture.attachments, [
      OmpdFixture.existingName,
      OmpdFixture.newName,
    ]);

    // Use the preserved chat actions sheet, not an injected offline snapshot.
    await _tap(tester, _key('companion-channel-actions'));
    await _scrollTo(tester, _key('companion-actions-disconnect'));
    await _tap(tester, _key('companion-actions-disconnect'));
    await _condition(
      tester,
      () =>
          controller.chat(newId)!.snapshot.phase ==
          ConnectionPhase.disconnected,
    );
    await _until(tester, find.textContaining('Disconnected'));
    await controller.flush();
    final saved = await store.load();
    expect(saved, hasLength(2));
    for (final chat in saved) {
      final connection = OmpdConnection.parse(chat.link);
      expect(connection.endpoint.toString(), fixture.endpoint);
      expect(connection.trustedNetwork, isTrue);
      expect(
        connection.sessionId,
        controller.chat(chat.id)!.snapshot.sessionId,
      );
      expect(connection.sessionFile, '/synthetic/${connection.instance}.jsonl');
      expect(chat.link, isNot(contains('synthetic-profile')));
      expect(chat.link, isNot(contains('/synthetic/workspace')));
    }
    expect(saved.firstWhere((chat) => chat.id == newId).reconnect, isFalse);
    final ciphertext = utf8.decode(
      await file.readAsBytes(),
      allowMalformed: true,
    );
    for (final plaintext in [fixture.endpoint, OmpdFixture.finalReply, draft]) {
      expect(ciphertext, isNot(contains(plaintext)));
    }

    await tester.pumpWidget(const SizedBox.shrink());
    controllerDisposed = true;
    controller.dispose();

    // This is a distinct controller + store, in the SAME OS process. It does
    // not establish force-quit, process restart, or native file protection.
    final restoredStore = newStore();
    final restored = newController(restoredStore);
    var restoredDisposed = false;
    addTearDown(() async {
      if (!restoredDisposed) {
        try {
          await restored.flush();
        } finally {
          restored.dispose();
        }
      }
    });
    await restored.initialize();
    expect(restored.storageError, isNull);
    expect(restored.chats, hasLength(2));
    expect(restored.chat(existingId)!.draft, draft);
    expect(
      restored.chat(existingId)!.snapshot.messages.last.text,
      OmpdFixture.finalReply,
    );
    expect(restored.chat(newId)!.snapshot.phase, ConnectionPhase.disconnected);
    await showApp(restored);
    await _condition(
      tester,
      () => restored.chat(existingId)!.snapshot.phase == ConnectionPhase.live,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      restored.chat(existingId)!.snapshot.sessionId,
      OmpdFixture.existingSessionId,
    );
    expect(restored.chat(newId)!.snapshot.phase, ConnectionPhase.disconnected);
    expect(fixture.attachments, [
      OmpdFixture.existingName,
      OmpdFixture.newName,
      OmpdFixture.existingName,
    ]);
    expect(fixture.starts, hasLength(1));
    expect(fixture.prompts, [prompt]);
    expect(
      restored
          .chat(existingId)!
          .snapshot
          .messages
          .where((message) => message.text == OmpdFixture.finalReply),
      hasLength(1),
    );

    // Manual retry of the disconnected new session is attach-only too.
    await _tap(tester, _key('chat-list-item-$newId'));
    await _until(tester, _key('companion-retry'));
    await _tap(tester, _key('companion-retry'));
    await _condition(
      tester,
      () => restored.chat(newId)!.snapshot.phase == ConnectionPhase.live,
    );
    expect(restored.chat(newId)!.snapshot.sessionId, OmpdFixture.newSessionId);
    expect(fixture.attachments.last, OmpdFixture.newName);
    expect(fixture.starts, hasLength(1));
    expect(fixture.prompts, [prompt]);
    await _home(tester, find.text('Message…'), newId);
    await _tap(tester, _key('chat-list-item-$existingId'));
    await _until(tester, find.text(OmpdFixture.finalReply));
    await _until(tester, find.text(draft));
    await _appearances(
      tester,
      binding,
      anchor: find.text(OmpdFixture.finalReply),
      lightName: 'ompd-restored-chat-light',
      darkName: 'ompd-restored-chat-dark',
    );
    expect(fixture.errors, isEmpty);
    expect(
      fixture.controlRequests.every(
        (request) =>
            const ['status', 'start', 'attach'].contains(request['method']),
      ),
      isTrue,
    );
    expect(
      fixture.rpcRequests.every(
        (request) => const [
          'set_event_filter',
          'get_state',
          'get_messages',
          'get_messages_page',
          'prompt',
        ].contains(request['type']),
      ),
      isTrue,
    );
    await restored.flush();
    await tester.pumpWidget(const SizedBox.shrink());
    restoredDisposed = true;
    restored.dispose();
  });
}

Finder _key(String name) => find.byKey(ValueKey(name));

Future<void> _openDaemon(WidgetTester tester) async {
  final emptyConnect = find.byKey(const Key('connect-omp-session'));
  if (emptyConnect.evaluate().isNotEmpty) {
    await _tap(tester, emptyConnect);
  } else {
    // Once chats exist, the preserved Connect action lives in the home
    // quick-actions launcher instead of the empty-state button.
    await _tap(tester, find.byTooltip('Create or start conversation'));
    await _tap(
      tester,
      find.byKey(const Key('quick-action-create-channel-card')),
    );
  }
  await _until(tester, _key('raiju-paste-toggle'));
  expect(_key('omp-scan-qr'), findsOneWidget);
  await _tap(tester, _key('raiju-paste-toggle'));
  await _until(tester, _key('raiju-join-input'));
  expect(_key('raiju-join-submit'), findsOneWidget);
  await _tap(tester, _key('raiju-paste-toggle'));
  await _scrollTo(tester, _key('ompd-entry'));
  await _tap(tester, _key('ompd-entry'));
  await _until(tester, _key('ompd-endpoint'));
}

Future<void> _enterForm(WidgetTester tester, String key, String value) async {
  await _scrollTo(tester, _key(key));
  await tester.enterText(_key(key), value);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 100));
  final scrollable = find
      .byWidgetPredicate(
        (widget) =>
            widget is Scrollable &&
            (widget.axisDirection == AxisDirection.down ||
                widget.axisDirection == AxisDirection.up),
      )
      .last;
  // Start from the top so lazily built fields above the viewport can also be
  // found. The same helper handles the retained chat actions sheet.
  final position = tester.state<ScrollableState>(scrollable).position;
  position.jumpTo(position.minScrollExtent);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: scrollable,
    maxScrolls: 15,
  );
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _home(WidgetTester tester, Finder anchor, String chatId) async {
  FocusManager.instance.primaryFocus?.unfocus();
  // Native glass back-button gestures are not driven by Flutter's tester.
  // Pop the actual preserved route; do not substitute a different home UI.
  Navigator.of(tester.element(anchor.first)).pop();
  await _until(tester, _key('chat-list-item-$chatId'));
}

Future<void> _condition(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue, reason: 'Timed out waiting for TCP/UI state');
}

Future<void> _until(WidgetTester tester, Finder finder) =>
    _condition(tester, () => finder.evaluate().isNotEmpty);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _condition(tester, () => finder.hitTestable().evaluate().isNotEmpty);
  await tester.tap(finder.hitTestable().first);
  await tester.pump();
}

Future<void> _enabledSend(WidgetTester tester) => _condition(tester, () {
  final finder = _key('raiju-send');
  return finder.evaluate().isNotEmpty &&
      tester.widget<IconButton>(finder).onPressed != null;
});

Future<void> _paint(WidgetTester tester, Finder anchor) async {
  await _condition(tester, () {
    if (anchor.evaluate().isEmpty) return false;
    final animation = ModalRoute.of(tester.element(anchor.first))?.animation;
    return animation == null || animation.status == AnimationStatus.completed;
  });
  for (var frame = 0; frame < 3; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _screenshot(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  Finder anchor,
  String name,
) async {
  await _paint(tester, anchor);
  await binding.takeScreenshot(name);
}

Future<void> _appearances(
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
  try {
    for (final appearance in [
      (ThemeMode.light, Brightness.light, lightName),
      (ThemeMode.dark, Brightness.dark, darkName),
    ]) {
      notifier.setMode(appearance.$1);
      await _condition(
        tester,
        () =>
            Theme.of(tester.element(anchor.first)).brightness == appearance.$2,
      );
      await _screenshot(tester, binding, anchor, appearance.$3);
    }
  } finally {
    notifier.setPreference(original);
    await notifier.flush();
    await tester.pump(const Duration(milliseconds: 300));
  }
}
