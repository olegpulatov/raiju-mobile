import 'dart:async';

import 'package:raiju_mobile/companion_controller.dart';
import 'package:raiju_mobile/features/channels/channel_detail_page.dart';
import 'package:raiju_mobile/features/pairing/pairing_page.dart';
import 'package:raiju_mobile/features/pairing/pairing_provider.dart';
import 'package:raiju_mobile/features/settings/settings_page.dart';
import 'package:raiju_mobile/harness/collab_link.dart';
import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/raiju/collab_relay_preference.dart';
import 'package:raiju_mobile/raiju/companion_provider.dart';
import 'package:raiju_mobile/shared/theme/theme.dart';
import 'package:raiju_mobile/storage/chat_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('full QR link and ordinary token use the same join operation', () async {
    final inputs = <String>[];
    final controller = _controller((input) => inputs.add(input));
    final container = ProviderContainer(
      overrides: [
        companionControllerProvider.overrideWith((ref) => controller),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(pairingProvider.notifier)
        .pair('omp://example.test/room#secret');
    expect(container.read(pairingProvider).status, PairingStatus.success);
    container.read(pairingProvider.notifier).reset();
    await container.read(pairingProvider.notifier).pair('opaque-token');

    expect(inputs, ['omp://example.test/room#secret', 'opaque-token']);
    expect(container.read(pairingProvider).joinedChatId, isNotNull);
  });

  test('reset ignores a late join completion', () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final controller = CompanionController(
      clientFactory: () =>
          _Client(onConnect: (_) => started.complete(), gate: gate.future),
      store: _Store(),
      writeDebounce: Duration.zero,
    );
    final container = ProviderContainer(
      overrides: [
        companionControllerProvider.overrideWith((ref) => controller),
      ],
    );
    addTearDown(container.dispose);

    final joining = container
        .read(pairingProvider.notifier)
        .pair('opaque-token');
    await started.future;
    container.read(pairingProvider.notifier).reset();
    gate.complete();
    await joining;

    expect(container.read(pairingProvider).status, PairingStatus.idle);
    expect(container.read(pairingProvider).joinedChat, isNull);
    expect(controller.chats, isEmpty);
  });

  testWidgets('scanner result joins and navigates through the QR UI path', (
    tester,
  ) async {
    const qrPayload = 'omp://example.test/scanned#private';
    final inputs = <String>[];
    final controller = _controller(inputs.add);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          companionControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: PairingPage(
            addingCommunity: true,
            scannerLauncher: (_) async => qrPayload,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('omp-scan-qr')));
    await tester.pumpAndSettle();

    expect(inputs, [qrPayload]);
    expect(find.byType(ChannelDetailPage), findsOneWidget);
  });

  testWidgets('pasted join replaces Connect with the original chat detail', (
    tester,
  ) async {
    final controller = _controller((_) {});
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          companionControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const PairingPage(addingCommunity: true),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('raiju-paste-toggle')));
    await tester.pump();
    final joinInput = tester.widget<TextField>(
      find.byKey(const ValueKey('raiju-join-input')),
    );
    expect(joinInput.obscureText, isTrue);
    expect(joinInput.enableIMEPersonalizedLearning, isFalse);
    await tester.enterText(
      find.byKey(const ValueKey('raiju-join-input')),
      'opaque-token',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('raiju-join-submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('raiju-join-submit')));
    await tester.pumpAndSettle();

    expect(find.byType(ChannelDetailPage), findsOneWidget);
    expect(find.byType(PairingPage), findsNothing);
  });

  testWidgets('join failure remains on Connect and shows an explanation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = CompanionController(
      clientFactory: () => _Client(onConnect: (_) {}, fail: true),
      store: _Store(),
      writeDebounce: Duration.zero,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          companionControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const PairingPage(addingCommunity: true),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('raiju-paste-toggle')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('raiju-join-input')),
      'bad-token',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('raiju-join-submit')));
    await tester.pumpAndSettle();
    final scope = ProviderScope.containerOf(
      tester.element(find.byType(PairingPage)),
    );
    await tester.tap(find.byKey(const ValueKey('raiju-join-submit')));
    await tester.runAsync(() async {
      while (scope.read(pairingProvider).status == PairingStatus.connecting) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(controller.chats, isEmpty);
    expect(scope.read(pairingProvider).status, PairingStatus.error);
    expect(
      scope.read(pairingProvider).errorMessage,
      'The OMP link could not be opened.',
    );

    expect(find.byType(PairingPage), findsOneWidget);
    expect(find.text('The OMP link could not be opened.'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('raiju-join-input')))
          .controller
          ?.text,
      isEmpty,
    );
  });

  testWidgets('appearance rows retain and update local accent state', (
    tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'Raiju',
      packageName: 'buzz',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final controller = _controller((_) {});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          companionControllerProvider.overrideWith((ref) => controller),
          savedPrefsProvider.overrideWithValue(prefs),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const SettingsPage(profileHeader: SizedBox.shrink()),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('community-theme-row')), findsOneWidget);
    expect(find.byKey(const ValueKey('community-accent-row')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-connect-omp')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('community-accent-row')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(accentColors[1].name));
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text(accentColors[1].name), findsOneWidget);
  });
  testWidgets(
    'connection setting rejects unsafe relay and saves edited origin',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      PackageInfo.setMockInitialValues(
        appName: 'Raiju',
        packageName: 'buzz',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = _controller((_) {});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            companionControllerProvider.overrideWith((ref) => controller),
            savedPrefsProvider.overrideWithValue(prefs),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const SettingsPage(profileHeader: SizedBox.shrink()),
          ),
        ),
      );
      final row = find.byKey(const ValueKey('settings-default-collab-relay'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('default-collab-relay-input'));
      await tester.enterText(field, 'ws://remote.example');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('secure connection'), findsOneWidget);
      expect(prefs.getString(collabRelayPreferenceKey), isNull);
      await tester.enterText(field, 'wss://preferred.example');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        prefs.getString(collabRelayPreferenceKey),
        'wss://preferred.example',
      );
    },
  );

  test(
    'successful bare join stores pinned relay for reconnect after reload',
    () async {
      final store = _Store();
      final connected = <String>[];
      final key = encodeBase64Url(List<int>.generate(32, (i) => i));
      final bare = 'AbCdEf123456.$key';
      final first = CompanionController(
        clientFactory: () => _Client(onConnect: connected.add),
        store: store,
        joinInputResolver: (input) =>
            pinBareCollabLink(input, defaultRelay: 'wss://initial.example'),
        writeDebounce: Duration.zero,
      );
      await first.join(bare);
      expect(
        parseCollabLink(store.value.single.link).safeEndpoint,
        'wss://initial.example',
      );
      first.dispose();

      final reloaded = CompanionController(
        clientFactory: () => _Client(onConnect: connected.add),
        store: store,
        joinInputResolver: (input) =>
            pinBareCollabLink(input, defaultRelay: 'wss://changed.example'),
        writeDebounce: Duration.zero,
      );
      await reloaded.initialize();
      await reloaded.reconnect(reloaded.chats.single.id);
      expect(connected.last, store.value.single.link);
      expect(
        parseCollabLink(connected.last).safeEndpoint,
        'wss://initial.example',
      );
      reloaded.dispose();
    },
  );

  test(
    'bare-fragment QR wrapper persists resolved relay across reconnect',
    () async {
      final store = _Store();
      final connected = <String>[];
      final key = encodeBase64Url(List<int>.generate(32, (i) => i));
      final wrapper = 'https://viewer.example/#AbCdEf123456.$key';
      final initial = CompanionController(
        clientFactory: () => _Client(onConnect: connected.add),
        store: store,
        joinInputResolver: (input) =>
            pinBareCollabLink(input, defaultRelay: 'wss://original.example'),
        writeDebounce: Duration.zero,
      );
      await initial.join(wrapper);
      expect(
        parseCollabLink(store.value.single.link).safeEndpoint,
        'wss://original.example',
      );
      expect(store.value.single.link, isNot(wrapper));
      initial.dispose();

      final reloaded = CompanionController(
        clientFactory: () => _Client(onConnect: connected.add),
        store: store,
        joinInputResolver: (input) =>
            pinBareCollabLink(input, defaultRelay: 'wss://changed.example'),
        writeDebounce: Duration.zero,
      );
      await reloaded.initialize();
      await reloaded.reconnect(reloaded.chats.single.id);
      expect(
        parseCollabLink(connected.last).safeEndpoint,
        'wss://original.example',
      );
      reloaded.dispose();
    },
  );

  test(
    'legacy bare saved code pins its observed origin, not new preference',
    () async {
      final key = encodeBase64Url(List<int>.generate(32, (i) => i));
      final bare = 'AbCdEf123456.$key';
      final store = _Store()
        ..value = [
          StoredChat(
            id: '1',
            link: bare,
            label: 'Legacy',
            draft: '',
            reconnect: true,
            snapshot: const StoredSnapshot(
              title: 'Legacy',
              endpoint: 'wss://old.example',
              model: '',
              messages: [],
              readOnly: false,
            ),
          ),
        ];
      final connected = <String>[];
      final controller = CompanionController(
        clientFactory: () => _Client(onConnect: connected.add),
        store: store,
        joinInputResolver: (input) =>
            pinBareCollabLink(input, defaultRelay: 'wss://new.example'),
        writeDebounce: Duration.zero,
      );
      await controller.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(connected, isNotEmpty);
      expect(
        parseCollabLink(connected.first).safeEndpoint,
        'wss://old.example',
      );
      await controller.reconnect('1');
      expect(parseCollabLink(connected.last).safeEndpoint, 'wss://old.example');
      expect(
        parseCollabLink(store.value.single.link).safeEndpoint,
        'wss://old.example',
      );
      expect(store.value.single.link, isNot(bare));
      controller.dispose();
    },
  );

  test(
    'legacy bare code with unknown origin stays offline and retains link',
    () async {
      final key = encodeBase64Url(List<int>.generate(32, (i) => i));
      final bare = 'AbCdEf123456.$key';
      final store = _Store()
        ..value = [
          StoredChat(
            id: '1',
            link: bare,
            label: 'Legacy',
            draft: '',
            reconnect: true,
            snapshot: const StoredSnapshot(
              title: 'Legacy',
              endpoint: 'ws://unsafe.example',
              model: '',
              messages: [],
              readOnly: false,
            ),
          ),
        ];
      final connected = <String>[];
      final controller = CompanionController(
        clientFactory: () => _Client(onConnect: connected.add),
        store: store,
        writeDebounce: Duration.zero,
      );
      await controller.initialize();
      expect(controller.chats.single.snapshot.phase, ConnectionPhase.error);
      expect(
        controller.chats.single.snapshot.error,
        contains('verified relay'),
      );
      expect(connected, isEmpty);
      await expectLater(
        controller.reconnect('1'),
        throwsA(isA<HarnessException>()),
      );
      expect(store.value.single.link, bare);
      controller.dispose();
    },
  );
}

CompanionController _controller(void Function(String input) onConnect) {
  return CompanionController(
    clientFactory: () => _Client(onConnect: onConnect),
    store: _Store(),
    writeDebounce: Duration.zero,
  );
}

class _Store implements ChatStore {
  List<StoredChat> value = [];

  @override
  Future<List<StoredChat>> load() async => List.of(value);

  @override
  Future<void> save(List<StoredChat> chats) async {
    value = List.of(chats);
  }
}

class _Client implements HarnessClient {
  _Client({required this.onConnect, this.fail = false, this.gate});

  final void Function(String input) onConnect;
  final bool fail;
  final Future<void>? gate;
  final _changes = StreamController<HarnessSnapshot>.broadcast(sync: true);
  HarnessSnapshot _snapshot = const HarnessSnapshot();

  @override
  HarnessSnapshot get snapshot => _snapshot;

  @override
  Stream<HarnessSnapshot> get changes => _changes.stream;
  @override
  Future<void> connect(String input, {String displayName = 'raiju'}) async {
    onConnect(input);
    final connectGate = gate;
    if (connectGate != null) await connectGate;
    if (fail) {
      throw const HarnessException('The OMP link could not be opened.');
    }
    _snapshot = const HarnessSnapshot(
      phase: ConnectionPhase.live,
      title: 'Shared OMP chat',
      readOnly: false,
    );
    _changes.add(_snapshot);
  }

  @override
  Future<void> abort() async {}

  @override
  Future<void> disconnect() async {
    _snapshot = const HarnessSnapshot(
      phase: ConnectionPhase.disconnected,
      title: 'Shared OMP chat',
      readOnly: false,
    );
    _changes.add(_snapshot);
  }

  @override
  Future<void> dispose() async => _changes.close();

  @override
  Future<void> respond(int requestId, String? value) async {}

  @override
  Future<void> sendPrompt(String text) async {}
}
