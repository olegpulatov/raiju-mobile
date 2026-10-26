import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:raiju_mobile/app.dart';
import 'package:raiju_mobile/companion_controller.dart';
import 'package:raiju_mobile/features/channels/compose_bar.dart';
import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/raiju/companion_provider.dart';
import 'package:raiju_mobile/shared/theme/theme_provider.dart';
import 'package:raiju_mobile/storage/encrypted_file_chat_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _input = ValueKey('raiju-composer-input');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('raiju/spark/methods'),
          (_) async => null,
        );
  });

  testWidgets('keystrokes stay local and persist once after idle', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    await tester.pumpWidget(fixture.composer());
    await tester.tap(find.text('Message…'));
    await tester.pumpAndSettle();
    final writes = fixture.disk.writes;
    var notifications = 0;
    fixture.controller.addListener(() => notifications++);

    const text = 'local typing';
    for (var i = 1; i <= text.length; i++) {
      await tester.enterText(find.byKey(_input), text.substring(0, i));
      await tester.pump(const Duration(milliseconds: 30));
      expect(fixture.client.networkCalls, 0);
      expect(notifications, 0);
      expect(fixture.disk.writes, writes);
    }
    expect(fixture.controller.chat(fixture.id)!.draft, text);
    await tester.pump(const Duration(milliseconds: 401));
    expect(fixture.disk.writes - writes, 1);
    expect(notifications, 0);
    expect(String.fromCharCodes(fixture.disk.bytes!), isNot(contains(text)));
    expect((await fixture.store().load()).single.draft, text);

    await tester.pumpWidget(const SizedBox());
    final restored = fixture.recreate();
    await restored.initialize();
    expect(restored.chat(fixture.id)!.draft, text);
    restored.dispose();
  });

  testWidgets(
    'successful send durably clears before debounce and stays clear',
    (tester) async {
      final fixture = await _Fixture.create();
      fixture.controller.updateDraft(fixture.id, 'old saved draft');
      await fixture.controller.flush();
      await tester.pumpWidget(fixture.composer());
      await tester.tap(find.text('old saved draft'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(_input), 'send this');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('raiju-send')));
      await tester.pump();
      expect(fixture.client.prompts, ['send this']);
      expect((await fixture.store().load()).single.draft, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect((await fixture.store().load()).single.draft, isEmpty);
      await tester.pumpWidget(const SizedBox());
      final restored = fixture.recreate();
      await restored.initialize();
      expect(restored.chat(fixture.id)!.draft, isEmpty);
      restored.dispose();
    },
  );

  testWidgets('leaving composer flushes without waiting for idle', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    final container = ProviderContainer(
      overrides: [
        companionControllerProvider.overrideWith((ref) => fixture.controller),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: fixture.composerContent(),
      ),
    );
    await tester.tap(find.text('Message…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(_input), 'leave immediately');
    await tester.pumpWidget(const SizedBox());
    expect((await fixture.store().load()).single.draft, 'leave immediately');
  });

  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  ]) {
    testWidgets('app $state flushes draft before idle', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final fixture = await _Fixture.create();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            companionControllerProvider.overrideWith(
              (ref) => fixture.controller,
            ),
            savedPrefsProvider.overrideWithValue(prefs),
          ],
          child: const App(),
        ),
      );
      await tester.pump();
      if (state != AppLifecycleState.inactive) {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        if (state == AppLifecycleState.detached) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        }
        await tester.pump();
      }
      fixture.controller.updateDraft(fixture.id, 'suspend now');
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
      expect((await fixture.store().load()).single.draft, 'suspend now');
      await tester.pumpWidget(const SizedBox());
      if (state == AppLifecycleState.paused) {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final restored = fixture.recreate();
      await restored.initialize();
      expect(restored.chat(fixture.id)!.draft, 'suspend now');
      restored.dispose();
    });
  }

  testWidgets('edits during an active save still wait for idle', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    fixture.controller.updateDraft(fixture.id, 'saving now');
    final writes = fixture.disk.writes;
    fixture.disk.gate = Completer<void>();
    fixture.disk.entered = Completer<void>();
    final saving = fixture.controller.flush();
    await fixture.disk.entered!.future;
    fixture.controller.updateDraft(fixture.id, 'still typing');
    fixture.disk.gate!.complete();
    await saving;
    expect(fixture.disk.writes - writes, 1);
    expect((await fixture.store().load()).single.draft, 'saving now');
    await tester.pump(const Duration(milliseconds: 401));
    expect(fixture.disk.writes - writes, 2);
    expect((await fixture.store().load()).single.draft, 'still typing');
    fixture.controller.dispose();
  });

  testWidgets('send starts draft flush immediately and preserves newer edits', (
    tester,
  ) async {
    final fixture = await _Fixture.create();
    fixture.client.sendGate = Completer<void>();
    fixture.controller.updateDraft(fixture.id, 'sending now');
    final sending = fixture.controller.sendPrompt(fixture.id, 'sending now');
    await tester.pump();
    expect((await fixture.store().load()).single.draft, 'sending now');
    fixture.controller.updateDraft(fixture.id, 'new draft during send');
    fixture.client.sendGate!.complete();
    await sending;
    expect(
      (await fixture.store().load()).single.draft,
      'new draft during send',
    );
    fixture.controller.dispose();
  });

  test(
    'storage failure after send never becomes a retryable send error',
    () async {
      final fixture = await _Fixture.create();
      fixture.controller.updateDraft(fixture.id, 'send once');
      fixture.disk.failWrite = true;
      expect(
        await fixture.controller.sendPrompt(fixture.id, 'send once'),
        'send once',
      );
      expect(fixture.client.prompts, ['send once']);
      expect(fixture.controller.chat(fixture.id)!.draft, isEmpty);
      expect(fixture.controller.storageError, isNotNull);
      fixture.disk.failWrite = false;
      await fixture.controller.flush();
      expect((await fixture.store().load()).single.draft, isEmpty);
      fixture.controller.dispose();
    },
  );

  test(
    'controller disposal commits latest draft behind active write',
    () async {
      final fixture = await _Fixture.create();
      fixture.controller.updateDraft(fixture.id, 'earlier draft');
      fixture.disk.gate = Completer<void>();
      fixture.disk.entered = Completer<void>();
      final flushing = fixture.controller.flush();
      await fixture.disk.entered!.future;
      fixture.controller.updateDraft(fixture.id, 'latest before close');
      fixture.controller.dispose();
      fixture.disk.gate!.complete();
      await flushing;
      // Complete in-memory crypto/write microtasks before recreating the store.
      await Future<void>.delayed(Duration.zero);
      final restored = fixture.recreate();
      await restored.initialize();
      expect(restored.chat(fixture.id)!.draft, 'latest before close');
      restored.dispose();
    },
  );
}

class _Fixture {
  _Fixture(this.controller, this.client, this.disk, this.keys, this.id);

  final CompanionController controller;
  final _Client client;
  final _Ciphertext disk;
  final _Keys keys;
  final String id;

  static Future<_Fixture> create() async {
    final disk = _Ciphertext();
    final keys = _Keys();
    final client = _Client();
    final controller = CompanionController(
      clientFactory: () => client,
      store: EncryptedFileChatStore(ciphertext: disk, keys: keys),
    );
    await controller.initialize();
    final chat = await controller.join('synthetic-draft-link');
    return _Fixture(controller, client, disk, keys, chat.id);
  }

  EncryptedFileChatStore store() =>
      EncryptedFileChatStore(ciphertext: disk, keys: keys);

  CompanionController recreate() =>
      CompanionController(clientFactory: _Client.new, store: store());

  Widget composer() => ProviderScope(
    overrides: [companionControllerProvider.overrideWith((ref) => controller)],
    child: composerContent(),
  );

  Widget composerContent() => MaterialApp(
    home: Scaffold(
      body: ComposeBar(
        channelId: id,
        onSend: (text, mentions, {mediaTags = const []}) async {
          await controller.sendPrompt(id, text);
        },
      ),
    ),
  );
}

class _Client implements HarnessClient {
  final _changes = StreamController<HarnessSnapshot>.broadcast();
  final prompts = <String>[];
  int networkCalls = 0;
  Completer<void>? sendGate;

  @override
  HarnessSnapshot get snapshot => const HarnessSnapshot(
    phase: ConnectionPhase.live,
    title: 'Draft test',
    readOnly: false,
  );

  @override
  Stream<HarnessSnapshot> get changes => _changes.stream;

  @override
  Future<void> connect(String input, {String displayName = 'raiju'}) async {}

  @override
  Future<void> sendPrompt(String text) async {
    networkCalls++;
    prompts.add(text);
    await sendGate?.future;
  }

  @override
  Future<void> abort() async => networkCalls++;

  @override
  Future<void> respond(int requestId, String? value) async => networkCalls++;

  @override
  Future<void> disconnect() async => networkCalls++;

  @override
  Future<void> dispose() async => _changes.close();
}

class _Ciphertext implements ChatCiphertextBackend {
  Uint8List? bytes;
  int writes = 0;
  Completer<void>? gate;
  Completer<void>? entered;
  bool failWrite = false;

  @override
  Future<Uint8List?> read() async => bytes;

  @override
  Future<void> writeAtomic(Uint8List value) async {
    writes++;
    if (!(entered?.isCompleted ?? true)) entered!.complete();
    await gate?.future;
    if (failWrite) throw StateError('synthetic disk failure');
    bytes = Uint8List.fromList(value);
  }
}

class _Keys implements ChatKeyBackend {
  Uint8List? bytes;

  @override
  Future<Uint8List?> read() async => bytes;

  @override
  Future<void> write(Uint8List key) async => bytes = Uint8List.fromList(key);
}
