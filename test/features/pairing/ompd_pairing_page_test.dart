import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:raiju_mobile/companion_controller.dart';
import 'package:raiju_mobile/features/pairing/ompd_pairing_page.dart';
import 'package:raiju_mobile/features/pairing/pairing_page.dart';
import 'package:raiju_mobile/features/pairing/pairing_provider.dart';
import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/harness/ompd_api.dart';
import 'package:raiju_mobile/harness/ompd_connection.dart';
import 'package:raiju_mobile/raiju/companion_provider.dart';
import 'package:raiju_mobile/raiju/ompd_relay_preferences.dart';
import 'package:raiju_mobile/shared/theme/theme_provider.dart';
import 'package:raiju_mobile/storage/chat_store.dart';

void main() {
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test(
    'QR and paste keep relay entry separate from collaboration pairing',
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
        contains('Use Browse relay'),
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
          savedPrefsProvider.overrideWithValue(prefs),
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

  testWidgets('last chat prefills relay without writing during page build', (
    tester,
  ) async {
    final api = _Api();
    await _open(
      tester,
      api,
      _Client(),
      savedRelay: OmpdConnection(
        endpoint: OmpdEndpoint.parse('legacy.example:8543'),
        instance: 'worker',
        sessionId: 'session-one',
        sessionFile: '/synthetic/worker.jsonl',
        trustedNetwork: true,
      ).encode(),
    );
    expect(tester.takeException(), isNull);
    expect(
      _button<TextField>(tester, 'ompd-endpoint').controller!.text,
      'legacy.example:8543',
    );
    expect(prefs.getStringList(ompdRelayPreferencesKey), isNull);
    await _tap(tester, 'ompd-save');
    expect(prefs.getStringList(ompdRelayPreferencesKey), [
      'legacy.example:8543',
      '',
    ]);
    expect(api.statusCalls, 0);
    expect(api.startCalls, 0);
  });

  testWidgets('save confirms persistence without contacting the relay', (
    tester,
  ) async {
    final api = _Api();
    await _open(tester, api, _Client(), view: OmpdPairingView.start);
    await tester.enterText(
      find.byKey(const ValueKey('ompd-endpoint')),
      '  HOST.example:8543  ',
    );
    await _show(tester, find.byKey(const ValueKey('ompd-profile')));
    await tester.enterText(find.byKey(const ValueKey('ompd-profile')), 'test');
    await _tap(tester, 'ompd-save');
    expect(find.byKey(const ValueKey('ompd-saved')), findsOneWidget);
    expect(prefs.getStringList(ompdRelayPreferencesKey), [
      'host.example:8543',
      'test',
    ]);
    expect(api.statusCalls, 0);
    expect(api.startCalls, 0);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open relay'));
    await tester.pumpAndSettle();
    expect(
      _button<TextField>(tester, 'ompd-endpoint').controller!.text,
      'host.example:8543',
    );
    await _show(tester, find.byKey(const ValueKey('ompd-profile')));
    expect(_button<TextField>(tester, 'ompd-profile').controller!.text, 'test');
  });

  testWidgets('typed endpoint and profile survive failed join and recreation', (
    tester,
  ) async {
    final api = _Api();
    final client = _Client()
      ..error = const HarnessException('Synthetic join failure.');
    await _open(tester, api, client, view: OmpdPairingView.start);
    await tester.enterText(
      find.byKey(const ValueKey('ompd-endpoint')),
      'other.example:8543',
    );
    await _show(tester, find.byKey(const ValueKey('ompd-profile')));
    await tester.enterText(find.byKey(const ValueKey('ompd-profile')), 'test');
    await _tap(tester, 'ompd-view-browse');
    await _tap(tester, 'ompd-refresh');
    await _tap(
      tester,
      'ompd-attach-worker',
      completion: client.disposal.future,
    );
    expect(
      OmpdConnection.parse(client.inputs.single).endpoint.toString(),
      'other.example:8543',
    );
    await tester.pumpWidget(const SizedBox());
    await prefs.reload();
    await _open(tester, _Api(), _Client(), view: OmpdPairingView.start);
    expect(
      _button<TextField>(tester, 'ompd-endpoint').controller!.text,
      'other.example:8543',
    );
    await _show(tester, find.byKey(const ValueKey('ompd-profile')));
    expect(_button<TextField>(tester, 'ompd-profile').controller!.text, 'test');
  });

  testWidgets('unfinished edits return before any save or connection', (
    tester,
  ) async {
    await _open(tester, _Api(), _Client(), view: OmpdPairingView.start);
    await tester.enterText(
      find.byKey(const ValueKey('ompd-endpoint')),
      'unfinished:',
    );
    await _show(tester, find.byKey(const ValueKey('ompd-profile')));
    await tester.enterText(
      find.byKey(const ValueKey('ompd-profile')),
      'last typed profile',
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open relay'));
    await tester.pumpAndSettle();
    expect(
      _button<TextField>(tester, 'ompd-endpoint').controller!.text,
      'unfinished:',
    );
    await _show(tester, find.byKey(const ValueKey('ompd-profile')));
    expect(
      _button<TextField>(tester, 'ompd-profile').controller!.text,
      'last typed profile',
    );
  });

  testWidgets('save requires an explicit editable port', (tester) async {
    final api = _Api();
    await _open(tester, api, _Client());
    await tester.enterText(
      find.byKey(const ValueKey('ompd-endpoint')),
      'host.example',
    );
    await _tap(tester, 'ompd-save');
    await _show(tester, find.byKey(const ValueKey('ompd-error')));
    expect(find.byKey(const ValueKey('ompd-saved')), findsNothing);
    expect(api.statusCalls, 0);
    expect(api.startCalls, 0);
  });

  testWidgets('relay actions need no consent and use edited endpoint', (
    tester,
  ) async {
    final api = _Api();
    await _open(tester, api, _Client());
    expect(api.statusCalls, 0);
    expect(api.startCalls, 0);
    expect(find.byKey(const ValueKey('ompd-consent')), findsNothing);
    expect(find.textContaining('no authentication'), findsNothing);
    expect(
      _button<OutlinedButton>(tester, 'ompd-refresh').onPressed,
      isNotNull,
    );
    await tester.enterText(
      find.byKey(const ValueKey('ompd-endpoint')),
      'host.example:8550',
    );
    await _tap(tester, 'ompd-refresh');
    expect(api.endpoints, ['host.example:8550']);
    await _show(
      tester,
      find.byKey(const ValueKey('ompd-endpoint')),
      scrollDelta: -300,
    );
    await tester.enterText(
      find.byKey(const ValueKey('ompd-endpoint')),
      'other.example:8543',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('ompd-attach-worker')), findsNothing);
    await _tap(tester, 'ompd-refresh');
    expect(api.endpoints, ['host.example:8550', 'other.example:8543']);
  });

  testWidgets('attach uses bound session identity and never starts', (
    tester,
  ) async {
    final api = _Api();
    final client = _Client();
    ChatThread? result;
    await _open(tester, api, client, onJoined: (chat) => result = chat);
    await _enterEndpoint(tester);
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
    await _enterEndpoint(tester);
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
      await _enterEndpoint(tester);
      await _tap(tester, 'ompd-refresh');
      expect(
        _button<TextButton>(tester, 'ompd-attach-worker').onPressed,
        isNull,
      );
    },
  );

  testWidgets('profile path is rejected until explicitly moved to directory', (
    tester,
  ) async {
    final api = _Api()
      ..waitError = const HarnessException('Session did not become ready.');
    final client = _Client();
    await _open(tester, api, client, view: OmpdPairingView.start);
    await _enterEndpoint(tester);
    await _show(tester, find.byKey(const ValueKey('ompd-name')));
    await tester.enterText(find.byKey(const ValueKey('ompd-name')), 'voice');
    await _show(tester, find.byKey(const ValueKey('ompd-profile')));
    final profileField = _button<TextField>(tester, 'ompd-profile');
    expect(
      profileField.decoration!.labelText,
      'Profile (configured host profile)',
    );
    expect(profileField.decoration!.helperText, contains('not a path'));
    await tester.enterText(
      find.byKey(const ValueKey('ompd-profile')),
      '/srv/locus/hub',
    );
    await _show(tester, find.byKey(const ValueKey('ompd-cwd')));
    final directoryField = _button<TextField>(tester, 'ompd-cwd');
    expect(
      directoryField.decoration!.labelText,
      'Working directory (absolute host path)',
    );
    expect(
      directoryField.decoration!.helperText,
      contains('Required when Profile is empty'),
    );
    await _tap(tester, 'ompd-start');
    await _show(tester, find.byKey(const ValueKey('ompd-error')));
    final error = _button<Text>(tester, 'ompd-error').data!;
    expect(error, contains('Profile must be a configured host profile name'));
    expect(error, contains('Put the path in Working directory'));
    expect(error, contains('leave Profile empty'));
    expect(api.startCalls, 0);
    expect(api.waitCalls, 0);
    expect(client.inputs, isEmpty);
    expect(_button<FilledButton>(tester, 'ompd-start').onPressed, isNotNull);
    await _show(
      tester,
      find.byKey(const ValueKey('ompd-profile')),
      scrollDelta: -300,
    );
    expect(
      _button<TextField>(tester, 'ompd-profile').controller!.text,
      '/srv/locus/hub',
    );
    await tester.enterText(find.byKey(const ValueKey('ompd-profile')), '');
    await _show(tester, find.byKey(const ValueKey('ompd-cwd')));
    expect(_button<TextField>(tester, 'ompd-cwd').controller!.text, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('ompd-cwd')),
      '/srv/locus/hub',
    );
    await _tap(tester, 'ompd-start');
    expect(api.calls, ['start', 'wait']);
    expect(api.startCalls, 1);
    expect(api.startedName, 'voice');
    expect(api.startedProfile, isNull);
    expect(api.startedCwd, '/srv/locus/hub');
    expect(_button<FilledButton>(tester, 'ompd-start').onPressed, isNull);
    await _tap(tester, 'ompd-view-browse');
    await _tap(tester, 'ompd-view-start');
    await _show(tester, find.byKey(const ValueKey('ompd-start')));
    expect(api.startCalls, 1);
    expect(_button<FilledButton>(tester, 'ompd-start').onPressed, isNull);
  });

  testWidgets('invalid instance and profile names identify the edited field', (
    tester,
  ) async {
    final api = _Api();
    await _open(tester, api, _Client(), view: OmpdPairingView.start);
    await _enterEndpoint(tester);
    await _show(tester, find.byKey(const ValueKey('ompd-name')));
    await tester.enterText(find.byKey(const ValueKey('ompd-name')), 'bad name');
    await _show(tester, find.byKey(const ValueKey('ompd-profile')));
    await tester.enterText(
      find.byKey(const ValueKey('ompd-profile')),
      'mobile',
    );
    await _tap(tester, 'ompd-start');
    await _show(tester, find.byKey(const ValueKey('ompd-error')));
    expect(
      _button<Text>(tester, 'ompd-error').data,
      startsWith('Instance name must use'),
    );
    expect(_button<Text>(tester, 'ompd-error').data, contains('underscores'));
    await _show(
      tester,
      find.byKey(const ValueKey('ompd-name')),
      scrollDelta: -300,
    );
    await tester.enterText(find.byKey(const ValueKey('ompd-name')), 'voice');
    await _show(tester, find.byKey(const ValueKey('ompd-profile')));
    await tester.enterText(
      find.byKey(const ValueKey('ompd-profile')),
      'bad profile',
    );
    await _tap(tester, 'ompd-start');
    await _show(tester, find.byKey(const ValueKey('ompd-error')));
    expect(
      _button<Text>(tester, 'ompd-error').data,
      startsWith('Profile name must use'),
    );
    expect(api.startCalls, 0);
    expect(api.waitCalls, 0);
    expect(_button<FilledButton>(tester, 'ompd-start').onPressed, isNotNull);
  });

  testWidgets(
    'resume starts once and failed readiness remains attachable by refresh',
    (tester) async {
      final api = _Api()
        ..waitError = const HarnessException('Session did not become ready.');
      await _open(tester, api, _Client(), view: OmpdPairingView.start);
      await _enterEndpoint(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('ompd-name')));
      await tester.enterText(find.byKey(const ValueKey('ompd-name')), 'worker');
      await tester.ensureVisible(find.byKey(const ValueKey('ompd-profile')));
      await tester.enterText(
        find.byKey(const ValueKey('ompd-profile')),
        'mobile_test',
      );
      await _show(tester, find.byKey(const ValueKey('ompd-cwd')));
      await tester.enterText(
        find.byKey(const ValueKey('ompd-cwd')),
        '/host/override',
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
      expect(api.startedProfile, 'mobile_test');
      expect(api.startedCwd, '/host/override');
      expect(_button<FilledButton>(tester, 'ompd-start').onPressed, isNull);
      await _show(tester, find.byKey(const ValueKey('ompd-error')));
      expect(find.textContaining('instance may still run'), findsOneWidget);
      await _tap(tester, 'ompd-view-browse');
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
      await _open(
        tester,
        api,
        client,
        view: OmpdPairingView.start,
        onJoined: (chat) => result = chat,
      );
      await _enterEndpoint(tester);
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
      expect(api.startedProfile, isNull);
      expect(api.startedCwd, '/host/project');
      expect(client.inputs, hasLength(1));
      expect(result, isNotNull);
    },
  );

  testWidgets('leaving during readiness never joins or restarts worker', (
    tester,
  ) async {
    final api = _Api()..readyGate = Completer<OmpdInstance>();
    final client = _Client();
    await _open(tester, api, client, view: OmpdPairingView.start);
    await _enterEndpoint(tester);
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
      await _enterEndpoint(tester);
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
    await _enterEndpoint(tester);
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
    scrollDelta:
        key == 'ompd-refresh' ||
            key == 'ompd-save' ||
            key.startsWith('ompd-view-')
        ? -300
        : 300,
  );
  await tester.tap(find.byKey(ValueKey(key)));
  if (completion != null) {
    // Stream cleanup can finish without scheduling a Flutter frame.
    await tester.runAsync(() => completion.timeout(const Duration(seconds: 5)));
  }
  await tester.pumpAndSettle();
}

Future<void> _enterEndpoint(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('ompd-endpoint')),
    'host.example:7420',
  );
  await tester.pumpAndSettle();
}

Future<CompanionController> _open(
  WidgetTester tester,
  _Api api,
  _Client client, {
  void Function(ChatThread?)? onJoined,
  OmpdPairingView view = OmpdPairingView.browse,
  String? savedRelay,
}) async {
  final controller = CompanionController(
    clientFactory: () => client,
    store: _Store(),
  );
  await controller.initialize();
  addTearDown(controller.dispose);
  if (savedRelay != null) await controller.join(savedRelay);
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        companionControllerProvider.overrideWith((ref) => controller),
        savedPrefsProvider.overrideWithValue(prefs),
        ompdApiProvider.overrideWithValue(api),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                final chat = await Navigator.of(context).push<ChatThread>(
                  MaterialPageRoute<ChatThread>(
                    builder: (_) => OmpdPairingPage(initialView: view),
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
  final endpoints = <String>[];
  String? startedSession;
  String? startedProfile;
  String? startedName;
  String? startedCwd;
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
    endpoints.add(endpoint.toString());
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
    startedName = name;
    startedCwd = cwd;
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
