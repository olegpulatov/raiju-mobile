import 'dart:async';

import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/storage/voice_transcript.dart';
import 'package:raiju_mobile/shared/theme/theme.dart';
import 'package:raiju_mobile/spark/spark.dart';
import 'package:raiju_mobile/spark/widgets/spark_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets('Spark starts folded without audio and chat stays interactive', (
    tester,
  ) async {
    var chatTaps = 0;
    final session = _FakeSession();
    await tester.pumpWidget(
      _fixture(
        session: session,
        child: TextButton(
          key: const ValueKey('chat-child'),
          onPressed: () => chatTaps++,
          child: const Text('Existing chat composer'),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('spark-minimized-button')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('spark-strip')), findsNothing);
    expect(find.byKey(const ValueKey('spark-start')), findsNothing);
    final compactSize = tester.getSize(
      find.byKey(const ValueKey('spark-minimized-button')),
    );
    expect(compactSize.width, compactSize.height);
    expect(session.startCalls, 0);
    expect(session.stopCalls, 0);
    await tester.tap(find.byKey(const ValueKey('chat-child')));
    expect(chatTaps, 1);

    await _expandSpark(tester);
    expect(find.byKey(const ValueKey('spark-strip')), findsOneWidget);
    expect(session.startCalls, 0);
    await tester.tap(find.byKey(const ValueKey('chat-child')));
    expect(chatTaps, 2);

    await tester.tap(find.byKey(const ValueKey('spark-minimize')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('spark-minimized-button')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('chat-child')));
    expect(chatTaps, 3);
    expect(session.startCalls, 0);
    expect(session.stopCalls, 0);
  });

  testWidgets('Spark sheet keeps typed input without manual handoff controls', (
    tester,
  ) async {
    await tester.pumpWidget(_fixture(child: const Text('Main chat')));
    await tester.pump();
    await _expandSpark(tester);
    final start = tester.widget<IconButton>(
      find.byKey(const ValueKey('spark-start')),
    );
    expect(start.onPressed, isNull);
    await tester.tap(find.text('Spark'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Open a chat to start Spark'), findsOneWidget);
    expect(find.byKey(const ValueKey('spark-manual-input')), findsOneWidget);
    expect(find.byKey(const ValueKey('spark-handoff-approve')), findsNothing);
    expect(find.byKey(const ValueKey('spark-agent-reply-share')), findsNothing);
  });

  testWidgets('typed Spark draft is preserved when inactive send is rejected', (
    tester,
  ) async {
    final session = _FakeSession();
    await tester.pumpWidget(
      _fixture(child: const Text('Main chat'), session: session),
    );
    await tester.pump();
    await _expandSpark(tester);
    await tester.tap(find.text('Spark'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('spark-manual-input')),
      'Synthetic typed message',
    );
    await tester.tap(find.byKey(const ValueKey('spark-manual-submit')));
    await tester.pump();
    expect(session.sent, isEmpty);
    expect(find.text('Synthetic typed message'), findsOneWidget);
  });
  testWidgets(
    'live user deltas update once, then final clears without a second saved turn',
    (tester) async {
      final session = _FakeSession();
      final bridge = _RecordingBridge();
      final controller = _activeController(session, bridge: bridge);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _fixture(child: const Text('Main chat'), controller: controller),
      );
      await _expandSpark(tester);
      await controller.start(chatId: 'bound-chat');
      session.emit(const {'type': 'connected'});
      await _pumpSessionUpdate(tester);
      final reservedHeight = tester
          .getSize(find.byKey(const ValueKey('spark-strip')))
          .height;
      final semantics = tester.ensureSemantics();
      try {
        session.emit(const {
          'type': 'transcript',
          'role': 'user',
          'id': 'speech-1',
          'text': 'I think',
          'final': false,
        });
        await _pumpSessionUpdate(tester);
        expect(find.text('You: I think'), findsOneWidget);
        expect(
          find.bySemanticsLabel(RegExp(r'Recognizing speech: I think\b')),
          findsOneWidget,
        );
        expect(bridge.saved, isEmpty);

        session.emit(const {
          'type': 'transcript',
          'role': 'user',
          'id': 'speech-1',
          'text': ' aloud',
          'final': false,
        });
        await _pumpSessionUpdate(tester);
        expect(find.text('You: I think aloud'), findsOneWidget);
        expect(find.text('You: I think'), findsNothing);
        expect(bridge.saved, isEmpty);
        expect(
          tester.getSize(find.byKey(const ValueKey('spark-strip'))).height,
          reservedHeight,
        );

        session.emit(const {
          'type': 'transcript',
          'role': 'user',
          'id': 'speech-1',
          'text': 'I think aloud',
          'final': true,
        });
        await _pumpSessionUpdate(tester);
        expect(
          find.byKey(const ValueKey('spark-live-transcript')),
          findsNothing,
        );
        expect(bridge.saved, hasLength(1));
        expect(bridge.saved.single.text, 'I think aloud');
        expect(bridge.saved.single.origin, VoiceTurnOrigin.user);
        session.emit(const {
          'type': 'transcript',
          'role': 'user',
          'id': 'speech-1',
          'text': 'I think aloud',
          'final': true,
        });
        await _pumpSessionUpdate(tester);
        expect(bridge.saved, hasLength(1));
        expect(
          tester.getSize(find.byKey(const ValueKey('spark-strip'))).height,
          reservedHeight,
        );
        expect(find.byKey(const ValueKey('spark-mic-toggle')), findsOneWidget);
        expect(find.byKey(const ValueKey('spark-stop')), findsOneWidget);
        expect(find.byKey(const ValueKey('spark-minimize')), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('newer assistant speech hides stale live user partial', (
    tester,
  ) async {
    final session = _FakeSession();
    final bridge = _RecordingBridge();
    final controller = _activeController(session, bridge: bridge);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _fixture(child: const Text('Main chat'), controller: controller),
    );
    await _expandSpark(tester);
    await controller.start(chatId: 'bound-chat');
    session.emit(const {'type': 'connected'});
    session.emit(const {
      'type': 'transcript',
      'role': 'user',
      'id': 'speech-2',
      'text': 'Please check',
      'final': false,
    });
    await _pumpSessionUpdate(tester);
    expect(find.byKey(const ValueKey('spark-live-transcript')), findsOneWidget);
    session.emit(const {
      'type': 'transcript',
      'role': 'assistant',
      'id': 'reply-2',
      'text': 'On it',
      'final': false,
    });
    await _pumpSessionUpdate(tester);
    expect(find.byKey(const ValueKey('spark-live-transcript')), findsNothing);
    expect(bridge.saved, isEmpty);
  });
  testWidgets(
    'later real user delta reappears after interleaved assistant speech',
    (tester) async {
      final session = _FakeSession();
      final bridge = _RecordingBridge();
      final controller = _activeController(session, bridge: bridge);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _fixture(child: const Text('Main chat'), controller: controller),
      );
      await _expandSpark(tester);
      await controller.start(chatId: 'bound-chat');
      session.emit(const {'type': 'connected'});
      session.emit(const {
        'type': 'transcript',
        'role': 'user',
        'id': 'speech-3',
        'text': 'One',
        'final': false,
      });
      await _pumpSessionUpdate(tester);
      session.emit(const {
        'type': 'transcript',
        'role': 'assistant',
        'id': 'reply-3',
        'text': 'Let me',
        'final': false,
      });
      await _pumpSessionUpdate(tester);
      expect(find.byKey(const ValueKey('spark-live-transcript')), findsNothing);
      session.emit(const {
        'type': 'transcript',
        'role': 'user',
        'id': 'speech-3',
        'text': ' more',
        'final': false,
      });
      await _pumpSessionUpdate(tester);
      expect(find.text('You: One more'), findsOneWidget);
      expect(bridge.saved, isEmpty);
      // Ambiguous coalesced role updates hide the partial until another user
      // delta arrives; the snapshot cannot establish event order in this frame.
      session.emit(const {
        'type': 'transcript',
        'role': 'assistant',
        'id': 'reply-3',
        'text': ' help',
        'final': false,
      });
      session.emit(const {
        'type': 'transcript',
        'role': 'user',
        'id': 'speech-3',
        'text': ' now',
        'final': false,
      });
      await _pumpSessionUpdate(tester);
      expect(find.byKey(const ValueKey('spark-live-transcript')), findsNothing);
      session.emit(const {
        'type': 'transcript',
        'role': 'user',
        'id': 'speech-3',
        'text': ' again',
        'final': false,
      });
      await _pumpSessionUpdate(tester);
      expect(find.text('You: One more now again'), findsOneWidget);
      session.emit(const {
        'type': 'transcript',
        'role': 'user',
        'id': 'speech-3',
        'text': 'One more now again',
        'final': true,
      });
      await _pumpSessionUpdate(tester);
      expect(find.byKey(const ValueKey('spark-live-transcript')), findsNothing);
      expect(bridge.saved, hasLength(1));
    },
  );

  testWidgets(
    'bounded live text ellipsizes, keeps navigation and minimize intact',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final session = _FakeSession();
      final controller = _activeController(session);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _fixture(
          controller: controller,
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('Another chat')),
                ),
              ),
              child: const Text('Go elsewhere'),
            ),
          ),
        ),
      );
      await _expandSpark(tester);
      await controller.start(chatId: 'bound-chat');
      session.emit(const {'type': 'connected'});
      session.emit({
        'type': 'transcript',
        'role': 'user',
        'id': 'long-speech',
        'text': '${List.filled(40, 'long speech ').join()}👩‍💻',
        'final': false,
      });
      await _pumpSessionUpdate(tester);
      final live = tester.widget<Text>(
        find.byKey(const ValueKey('spark-live-transcript')),
      );
      expect(live.maxLines, 1);
      expect(live.overflow, TextOverflow.ellipsis);
      expect(live.data, startsWith('You: …'));
      expect(live.data, endsWith('👩‍💻'));
      expect(live.data!.characters.length, lessThanOrEqualTo(166));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Go elsewhere'));
      await tester.pumpAndSettle();
      expect(find.text('Another chat'), findsOneWidget);
      expect(controller.snapshot.boundChatId, 'bound-chat');
      expect(
        find.byKey(const ValueKey('spark-live-transcript')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('spark-minimize')));
      await tester.pump();
      expect(find.byKey(const ValueKey('spark-live-transcript')), findsNothing);
      await tester.tap(find.byTooltip('Expand Spark controls'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('spark-live-transcript')),
        findsOneWidget,
      );
      expect(controller.snapshot.boundChatId, 'bound-chat');
    },
  );

  testWidgets('minimize and expand do not reanimate an expired meter sample', (
    tester,
  ) async {
    final session = _FakeSession();
    final controller = _activeController(session);
    addTearDown(controller.dispose);
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        _fixture(child: const Text('Main chat'), controller: controller),
      );
      await _expandSpark(tester);
      await controller.start(chatId: 'bound-chat');
      session.emit(const {'type': 'connected'});
      session.emit(const {'type': 'levels', 'input': 0.0, 'output': .05});
      await _pumpSessionUpdate(tester);
      expect(
        find.bySemanticsLabel(RegExp(r'Spark voice audio level')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('spark-minimize')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.byTooltip('Expand Spark controls'));
      await tester.pump();
      expect(controller.snapshot.outputLevel, .05);
      expect(
        find.bySemanticsLabel(RegExp(r'Spark voice connected, no audio level')),
        findsOneWidget,
      );
      session.emit(const {'type': 'levels', 'input': 0.0, 'output': .05});
      await _pumpSessionUpdate(tester);
      expect(
        find.bySemanticsLabel(RegExp(r'Spark voice audio level')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('spark-stop')), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'iOS retains active bound session, mute and events through lifecycle',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final session = _FakeSession();
      final controller = _activeController(session);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _fixture(child: const Text('Main chat'), controller: controller),
      );
      final starting = controller.start(chatId: 'bound-chat');
      await tester.pump();
      expect(session.startCalls, 1);
      await starting;
      session.emit(const {'type': 'connected'});
      await _pumpSessionUpdate(tester);
      await controller.setMicEnabled(false);
      final bound = controller.snapshot.boundChatId;
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      session.emit(const {
        'type': 'transcript',
        'role': 'user',
        'text': 'Continued in background',
        'final': true,
        'id': 'background-turn',
      });
      await _pumpSessionUpdate(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(session.stopCalls, 0);
      expect(session.startCalls, 1);
      expect(controller.snapshot.boundChatId, bound);
      expect(controller.snapshot.micEnabled, isFalse);
      expect(session.muted, isTrue);
      expect(
        controller.snapshot.transcript.any(
          (turn) => turn.text == 'Continued in background',
        ),
        isTrue,
      );
      await tester.runAsync(controller.stop);
      await tester.pump();
      expect(controller.snapshot.phase, SparkPhase.idle);
      expect(session.stopCalls, 1);
      expect(controller.snapshot.boundChatId, isNull);
      expect(session.startCalls, 1);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('iOS hidden cancels pending startup and does not auto-resume', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final session = _FakeSession()..pendingStart = Completer<void>();
    final controller = _activeController(session);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _fixture(child: const Text('Main chat'), controller: controller),
    );
    final starting = controller.start(chatId: 'bound-chat');
    await tester.pump();
    expect(controller.snapshot.phase, SparkPhase.connecting);
    await tester.runAsync(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    session.pendingStart!.complete();
    await starting;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(session.stopCalls, 1);
    expect(session.startCalls, 1);
    expect(controller.snapshot.phase, SparkPhase.idle);
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets(
    'iOS background during credential lookup cannot start on resume',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final credentials = Completer<void>();
      final session = _FakeSession();
      final controller = _activeController(
        session,
        credentials: _ReadyCredentials(credentials),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _fixture(child: const Text('Main chat'), controller: controller),
      );
      final starting = controller.start(chatId: 'bound-chat');
      await tester.pump();
      expect(controller.snapshot.phase, SparkPhase.connecting);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      credentials.complete();
      await starting;
      await tester.pump();
      expect(session.startCalls, 0);
      expect(controller.snapshot.phase, SparkPhase.idle);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('iOS detach still stops; non-iOS hidden and paused stop', (
    tester,
  ) async {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      debugDefaultTargetPlatformOverride = platform;
      final session = _FakeSession();
      final controller = _activeController(session);
      await tester.pumpWidget(
        _fixture(child: const Text('Main chat'), controller: controller),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await controller.start(chatId: 'bound-chat');
      session.emit(const {'type': 'connected'});
      await _pumpSessionUpdate(tester);
      await tester.runAsync(() async {
        if (platform == TargetPlatform.iOS) {
          // The test binding may suppress a redundant detached notification.
          (tester.state(find.byType(SparkShell)) as WidgetsBindingObserver)
              .didChangeAppLifecycleState(AppLifecycleState.detached);
        } else {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
        }
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(session.stopCalls, 1);
      if (platform == TargetPlatform.android) {
        await tester.runAsync(() async {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pump();
        expect(session.stopCalls, 1);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(session.stopCalls, 1);
      controller.dispose();
    }
    debugDefaultTargetPlatformOverride = null;
  });
}

Future<void> _expandSpark(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Expand Spark controls'));
  await tester.pump();
}

// Broadcast voice events can arrive after a pump's frame. Render the notified
// controller snapshot in the next frame before asserting shell widgets.
Future<void> _pumpSessionUpdate(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

SparkController _activeController(
  _FakeSession session, {
  _ReadyCredentials? credentials,
  SparkChatBridge? bridge,
}) => SparkController(
  session: session,
  credentials: credentials ?? _ReadyCredentials(),
  store: _ReadyStore(),
  chatBridge: bridge ?? _WritableBridge(),
);

Widget _fixture({
  required Widget child,
  _FakeSession? session,
  SparkController? controller,
}) {
  final navigatorKey = GlobalKey<NavigatorState>();
  return ProviderScope(
    overrides: [
      sparkVoiceSessionProvider.overrideWithValue(session ?? _FakeSession()),
      if (controller != null)
        sparkControllerProvider.overrideWith((ref) => controller),
      sparkCredentialSourceProvider.overrideWithValue(_FakeCredentials()),
      sparkSettingsStoreProvider.overrideWithValue(_MemoryStore()),
      sparkChatBridgeProvider.overrideWithValue(_ReadOnlyBridge()),
    ],
    child: MaterialApp(
      navigatorKey: navigatorKey,
      theme: AppTheme.light(),
      builder: (context, route) => Overlay(
        initialEntries: [
          OverlayEntry(
            builder: (_) => SparkShell(
              navigatorKey: navigatorKey,
              child: route ?? const SizedBox.shrink(),
            ),
          ),
        ],
      ),
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

class _FakeSession implements VoiceSession {
  final controller = StreamController<Map<String, Object?>>.broadcast();
  final sent = <String>[];
  int startCalls = 0;
  bool muted = false;
  Completer<void>? pendingStart;
  void emit(Map<String, Object?> event) => controller.add(event);
  int stopCalls = 0;
  @override
  Stream<Map<String, Object?>> get events => controller.stream;
  @override
  Future<void> dispose() => controller.close();
  @override
  Future<void> sendText(
    String text, {
    String? delegationId,
    String channel = 'speakable',
  }) async => sent.add(text);
  @override
  Future<void> setMuted(bool value) async => muted = value;
  @override
  Future<void> start({
    required String accessToken,
    String? accountId,
    required String instructions,
    required String voice,
  }) async {
    startCalls++;
    await pendingStart?.future;
  }

  @override
  Future<void> stop() async => stopCalls++;
}

class _FakeCredentials implements SparkCredentialSource {
  @override
  Future<SparkCredentialResult> acquire(
    SparkSettings settings,
    String brokerToken,
  ) async => const SparkCredentialResult(choices: []);
}

class _ReadyCredentials implements SparkCredentialSource {
  _ReadyCredentials([this.pending]);
  final Completer<void>? pending;
  @override
  Future<SparkCredentialResult> acquire(
    SparkSettings settings,
    String brokerToken,
  ) async {
    await pending?.future;
    return const SparkCredentialResult(
      choices: [
        SparkCredentialChoice(id: 'fixture', label: 'Synthetic account'),
      ],
      credential: SparkCredential(
        id: 'fixture',
        accessToken: 'synthetic-access',
        expiresAtMs: 4102444800000,
      ),
    );
  }
}

class _ReadyStore extends _MemoryStore {
  @override
  Future<StoredSparkSettings> load() async =>
      StoredSparkSettings(settings: value, hasBrokerToken: true);
  @override
  Future<String?> readBrokerToken() async => 'synthetic-broker';
}

class _WritableBridge extends _ReadOnlyBridge {
  @override
  SparkChatObservation? current(String chatId) => const SparkChatObservation(
    snapshot: HarnessSnapshot(phase: ConnectionPhase.live, readOnly: false),
    voiceTurns: [],
  );
}

class _RecordingBridge extends _WritableBridge {
  final saved = <VoiceTurn>[];

  @override
  Future<void> saveTurn(String chatId, VoiceTurn turn) async {
    saved.add(turn);
  }
}

class _MemoryStore implements SparkSettingsStore {
  SparkSettings value = const SparkSettings();
  @override
  Future<StoredSparkSettings> load() async =>
      StoredSparkSettings(settings: value, hasBrokerToken: false);
  @override
  Future<String?> readBrokerToken() async => null;
  @override
  Future<void> save(SparkSettings settings, {String? brokerToken}) async =>
      value = settings;
}

class _ReadOnlyBridge implements SparkChatBridge {
  @override
  SparkChatObservation? current(String chatId) => const SparkChatObservation(
    snapshot: HarnessSnapshot(phase: ConnectionPhase.live, readOnly: true),
    voiceTurns: [],
  );
  // A live chat keeps its observation stream open until the controller
  // unsubscribes; Stream.empty() would immediately tear down Spark startup.
  @override
  Stream<SparkChatObservation> observe(String chatId) =>
      Stream<SparkChatObservation>.multi((_) {});
  @override
  Future<void> saveTurn(String chatId, VoiceTurn turn) async {}
  @override
  Future<void> flush(String chatId) async {}
  @override
  void activateDirective(String chatId, String directive) {}
  @override
  void setPromptPreparer(
    String chatId,
    Future<String> Function(String text)? prepare,
  ) {}
  @override
  void setPromptDeliveryObserver(
    String chatId,
    void Function(String actualText, bool localSent)? observer,
  ) {}
  @override
  Future<List<SparkChatChoice>> listChats() async => const [
    SparkChatChoice(
      id: 'chat-read-only',
      label: 'Reference chat',
      canSend: false,
      isLive: true,
    ),
  ];
  @override
  Future<SparkChatSendResult> sendOnce(
    String chatId,
    String text, {
    required String requestId,
  }) async => const SparkChatSendResult(SparkSendOutcome.rejected);
}
