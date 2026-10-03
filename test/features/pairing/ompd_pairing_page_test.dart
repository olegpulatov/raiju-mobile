import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:raiju_mobile/companion_controller.dart';
import 'package:raiju_mobile/features/pairing/ompd_pairing_page.dart';
import 'package:raiju_mobile/features/pairing/pairing_page.dart';
import 'package:raiju_mobile/features/pairing/pairing_provider.dart';
import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/harness/ompd_api.dart';
import 'package:raiju_mobile/harness/ompd_connection.dart';
import 'package:raiju_mobile/raiju/companion_provider.dart';
import 'package:raiju_mobile/storage/chat_store.dart';

void main() {
  test(
    'QR and paste cannot supply daemon consent or create a client',
    () async {
      var controllerCreations = 0;
      final container = ProviderContainer(
        overrides: [
          companionControllerProvider.overrideWith((ref) {
            controllerCreations++;
            throw StateError(
              'Daemon QR/paste must not create controller or client',
            );
          }),
        ],
      );
      addTearDown(container.dispose);
      final encoded = OmpdConnection(
        endpoint: OmpdEndpoint.parse('host.example:7420'),
        instance: 'worker',
        sessionId: 'session-one',
        sessionFile: '/synthetic/worker.jsonl',
        trustedNetwork: true,
      ).encode();
      await container.read(pairingProvider.notifier).pair(encoded);
      expect(controllerCreations, 0);
      expect(container.read(pairingProvider).status, PairingStatus.error);
      expect(
        container.read(pairingProvider).errorMessage,
        contains('Use Daemon relay'),
      );
    },
  );

  testWidgets('connect retains QR and paste beside optional daemon entry', (
    tester,
  ) async {
    final api = _Api();
    final client = _Client()
      ..error = const HarnessException('Synthetic collab failure.');
    final controller = CompanionController(
      clientFactory: () => client,
      store: _Store(),
    );
    await controller.initialize();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          companionControllerProvider.overrideWith((ref) => controller),
          ompdApiProvider.overrideWithValue(api),
        ],
        child: const MaterialApp(home: PairingPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('omp-scan-qr')), findsOneWidget);
    expect(find.byKey(const ValueKey('raiju-paste-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('ompd-entry')), findsOneWidget);
    await _tap(tester, 'raiju-paste-toggle');
    await tester.enterText(
      find.byKey(const ValueKey('raiju-join-input')),
      'synthetic-collab-link',
    );
    await _tap(tester, 'raiju-join-submit', completion: client.disposal.future);
    expect(client.inputs, ['synthetic-collab-link']);
    expect(api.startCalls, 0);
    expect(api.statusCalls, 0);
    await _tap(tester, 'ompd-entry');
    expect(find.byKey(const ValueKey('ompd-endpoint')), findsOneWidget);
    expect(api.statusCalls, 0);
  });

  testWidgets('no networking before consent; editing endpoint revokes it', (
    tester,
  ) async {
    final api = _Api();
    final client = _Client();
    await _open(tester, api, client);
    expect(api.statusCalls, 0);
    expect(api.startCalls, 0);
    expect(_button<OutlinedButton>(tester, 'ompd-refresh').onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('ompd-endpoint')),
      'host.example:7420',
    );
    await _tap(tester, 'ompd-consent');
    await _tap(tester, 'ompd-refresh');
    expect(api.statusCalls, 1);
    await _show(
      tester,
      find.byKey(const ValueKey('ompd-endpoint')),
      scrollDelta: -300,
    );
    await tester.enterText(
      find.byKey(const ValueKey('ompd-endpoint')),
      'other.example:7420',
    );
    await tester.pump();
    await _show(tester, find.byKey(const ValueKey('ompd-refresh')));
    expect(_button<OutlinedButton>(tester, 'ompd-refresh').onPressed, isNull);
    expect(api.statusCalls, 1);
  });

  testWidgets('attach uses bound session identity and never starts', (
    tester,
  ) async {
    final api = _Api();
    final client = _Client();
    ChatThread? result;
    await _open(tester, api, client, onJoined: (chat) => result = chat);
    await _consent(tester);
    await _tap(tester, 'ompd-refresh');
    await _show(
      tester,
      find.textContaining('takes write control'),
      scrollDelta: -300,
    );
    expect(find.textContaining('takes write control'), findsOneWidget);
    await _tap(tester, 'ompd-attach-worker');
    expect(api.startCalls, 0);
    expect(api.waitCalls, 0);
    final connection = OmpdConnection.parse(client.inputs.single);
    expect(connection.instance, 'worker');
    expect(connection.sessionId, 'session-one');
    expect(connection.sessionFile, '/synthetic/worker.jsonl');
    expect(connection.trustedNetwork, isTrue);
    expect(result, isNotNull);
  });

  testWidgets('missing session identity disables attach', (tester) async {
    final api = _Api()
      ..instances = const [
        OmpdInstance(name: 'worker', state: 'running', ready: true, rpc: true),
      ];
    await _open(tester, api, _Client());
    await _consent(tester);
    await _tap(tester, 'ompd-refresh');
    expect(_button<TextButton>(tester, 'ompd-attach-worker').onPressed, isNull);
    expect(find.textContaining('session identity are ready'), findsOneWidget);
  });

  testWidgets(
    'missing transcript file disables attach even with provider session ID',
    (tester) async {
      final api = _Api()
        ..instances = const [
          OmpdInstance(
            name: 'worker',
            state: 'running',
            ready: true,
            rpc: true,
            sessionId: 'session-one',
          ),
        ];
      await _open(tester, api, _Client());
      await _consent(tester);
      await _tap(tester, 'ompd-refresh');
      expect(
        _button<TextButton>(tester, 'ompd-attach-worker').onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'resume starts once and failed readiness remains attachable by refresh',
    (tester) async {
      final api = _Api()
        ..waitError = const HarnessException('Session did not become ready.');
      await _open(tester, api, _Client());
      await _consent(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('ompd-name')));
      await tester.enterText(find.byKey(const ValueKey('ompd-name')), 'worker');
      await tester.ensureVisible(find.byKey(const ValueKey('ompd-profile')));
      await tester.enterText(
        find.byKey(const ValueKey('ompd-profile')),
        'mobile',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('ompd-session')));
      await tester.enterText(
        find.byKey(const ValueKey('ompd-session')),
        '/host/session.jsonl',
      );
      await _tap(tester, 'ompd-start');
      expect(api.startCalls, 1);
      expect(api.waitCalls, 1);
      expect(api.startedSession, '/host/session.jsonl');
      expect(api.startedProfile, 'mobile');
      expect(_button<FilledButton>(tester, 'ompd-start').onPressed, isNull);
      await _show(tester, find.byKey(const ValueKey('ompd-error')));
      expect(find.textContaining('instance may still run'), findsOneWidget);
      await _tap(tester, 'ompd-refresh');
      expect(api.startCalls, 1);
      expect(find.byKey(const ValueKey('ompd-attach-worker')), findsOneWidget);
    },
  );

  testWidgets(
    'start then readiness then join opens existing chat without second start',
    (tester) async {
      final api = _Api();
      final client = _Client();
      ChatThread? result;
      await _open(tester, api, client, onJoined: (chat) => result = chat);
      await _consent(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('ompd-name')));
      await tester.enterText(find.byKey(const ValueKey('ompd-name')), 'worker');
      await tester.ensureVisible(find.byKey(const ValueKey('ompd-cwd')));
      await tester.enterText(
        find.byKey(const ValueKey('ompd-cwd')),
        '/host/project',
      );
      await _tap(tester, 'ompd-start');
      expect(api.calls, ['start', 'wait']);
      expect(api.startCalls, 1);
      expect(client.inputs, hasLength(1));
      expect(result, isNotNull);
    },
  );

  testWidgets('leaving during readiness never joins or restarts worker', (
    tester,
  ) async {
    final api = _Api()..readyGate = Completer<OmpdInstance>();
    final client = _Client();
    await _open(tester, api, client);
    await _consent(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('ompd-name')));
    await tester.enterText(find.byKey(const ValueKey('ompd-name')), 'worker');
    await tester.ensureVisible(find.byKey(const ValueKey('ompd-profile')));
    await tester.enterText(
      find.byKey(const ValueKey('ompd-profile')),
      'mobile',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('ompd-start')));
    await tester.tap(find.byKey(const ValueKey('ompd-start')));
    await tester.pump();
    expect(api.startCalls, 1);
    await tester.pageBack();
    await tester.pumpAndSettle();
    api.readyGate!.complete(api.instances.single);
    await tester.pumpAndSettle();
    expect(client.inputs, isEmpty);
    expect(client.abortCalls, 0);
    expect(api.startCalls, 1);
  });

  testWidgets(
    'pop during pending bootstrap cancels client before any later attach',
    (tester) async {
      final api = _Api();
      final status = Completer<void>();
      final client = _Client()..statusGate = status;
      final controller = await _open(tester, api, client);
      await _consent(tester);
      await _tap(tester, 'ompd-refresh');
      await tester.ensureVisible(
        find.byKey(const ValueKey('ompd-attach-worker')),
      );
      await tester.tap(find.byKey(const ValueKey('ompd-attach-worker')));
      await tester.pump();
      expect(client.inputs, hasLength(1));
      expect(client.disposed, isFalse);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(client.disposed, isTrue);
      expect(controller.chats, isEmpty);
      status.complete();
      await tester.pumpAndSettle();
      expect(client.attachCalls, 0);
      expect(client.abortCalls, 0);
      expect(api.startCalls, 0);
      expect(controller.chats, isEmpty);
    },
  );

  testWidgets('attach failure shows safe error and does not start', (
    tester,
  ) async {
    final api = _Api();
    final client = _Client()
      ..error = const HarnessException('Conversation identity changed.');
    await _open(tester, api, client);
    await _consent(tester);
    await _tap(tester, 'ompd-refresh');
    await _tap(
      tester,
      'ompd-attach-worker',
      completion: client.disposal.future,
    );
    await _show(tester, find.byKey(const ValueKey('ompd-error')));
    expect(find.text('Conversation identity changed.'), findsOneWidget);
    expect(api.startCalls, 0);
  });
}

T _button<T extends Widget>(WidgetTester tester, String key) =>
    tester.widget<T>(find.byKey(ValueKey(key)));

Future<void> _show(
  WidgetTester tester,
  Finder target, {
  double scrollDelta = 300,
}) async {
  // Flush deferred caret scrolling before moving to a different control.
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      scrollDelta,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  } else {
    await tester.ensureVisible(target);
  }
  await tester.pump();
}

Future<void> _tap(
  WidgetTester tester,
  String key, {
  Future<void>? completion,
}) async {
  await _show(
    tester,
    find.byKey(ValueKey(key)),
    scrollDelta: key == 'ompd-refresh' || key == 'ompd-consent' ? -300 : 300,
  );
  await tester.tap(find.byKey(ValueKey(key)));
  if (completion != null) {
    // Stream cleanup can finish without scheduling a Flutter frame.
    await tester.runAsync(() => completion.timeout(const Duration(seconds: 5)));
  }
  await tester.pumpAndSettle();
}

Future<void> _consent(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('ompd-endpoint')),
    'host.example:7420',
  );
  await _tap(tester, 'ompd-consent');
}

Future<CompanionController> _open(
  WidgetTester tester,
  _Api api,
  _Client client, {
  void Function(ChatThread?)? onJoined,
}) async {
  final controller = CompanionController(
    clientFactory: () => client,
    store: _Store(),
  );
  await controller.initialize();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        companionControllerProvider.overrideWith((ref) => controller),
        ompdApiProvider.overrideWithValue(api),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                final chat = await Navigator.of(context).push<ChatThread>(
                  MaterialPageRoute<ChatThread>(
                    builder: (_) => const OmpdPairingPage(),
                  ),
                );
                onJoined?.call(chat);
              },
              child: const Text('Open relay'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open relay'));
  await tester.pumpAndSettle();
  return controller;
}

class _Api extends OmpdApi {
  int statusCalls = 0;
  int startCalls = 0;
  int waitCalls = 0;
  final calls = <String>[];
  String? startedSession;
  String? startedProfile;
  HarnessException? waitError;
  Completer<OmpdInstance>? readyGate;
  List<OmpdInstance> instances = const [
    OmpdInstance(
      name: 'worker',
      state: 'running',
      ready: true,
      rpc: true,
      sessionId: 'session-one',
      sessionFile: '/synthetic/worker.jsonl',
    ),
  ];

  @override
  Future<List<OmpdInstance>> status(OmpdEndpoint endpoint) async {
    statusCalls++;
    return instances;
  }

  @override
  Future<OmpdInstance> start(
    OmpdEndpoint endpoint, {
    required String name,
    String? profile,
    String? cwd,
    String? session,
  }) async {
    calls.add('start');
    startCalls++;
    startedSession = session;
    startedProfile = profile;
    return instances.single;
  }

  @override
  Future<OmpdInstance> waitUntilReady(
    OmpdEndpoint endpoint,
    String name,
  ) async {
    calls.add('wait');
    waitCalls++;
    if (waitError != null) throw waitError!;
    return readyGate == null ? instances.single : await readyGate!.future;
  }
}

class _Store implements ChatStore {
  @override
  Future<List<StoredChat>> load() async => [];
  @override
  Future<void> save(List<StoredChat> chats) async {}
}

class _Client implements HarnessClient {
  final inputs = <String>[];
  final _changes = StreamController<HarnessSnapshot>.broadcast();
  HarnessException? error;
  int abortCalls = 0;
  final disposal = Completer<void>();
  Completer<void>? statusGate;
  bool disposed = false;
  int attachCalls = 0;
  @override
  HarnessSnapshot snapshot = const HarnessSnapshot();
  @override
  Stream<HarnessSnapshot> get changes => _changes.stream;
  @override
  Future<void> connect(String input, {String displayName = 'raiju'}) async {
    inputs.add(input);
    if (statusGate != null) await statusGate!.future;
    if (disposed) throw const HarnessException('Connection cancelled.');
    if (error != null) throw error!;
    attachCalls++;
    snapshot = const HarnessSnapshot(
      phase: ConnectionPhase.live,
      sessionId: 'session-one',
    );
  }

  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async {
    disposed = true;
    if (!_changes.isClosed) await _changes.close();
    if (!disposal.isCompleted) disposal.complete();
  }

  @override
  Future<void> abort() async {
    abortCalls++;
  }

  @override
  Future<void> respond(int requestId, String? value) async {}
  @override
  Future<void> sendPrompt(String text) async {}
}
