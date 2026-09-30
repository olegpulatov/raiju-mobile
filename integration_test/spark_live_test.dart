import 'dart:convert';
import 'dart:io';

import 'package:buzz/harness/harness.dart';
import 'package:buzz/storage/voice_transcript.dart';
import 'package:buzz/spark/chat_bridge.dart';
import 'package:buzz/spark/controller.dart';
import 'package:buzz/spark/credential_broker.dart';
import 'package:buzz/spark/models.dart';
import 'package:buzz/spark/settings_store.dart';
import 'package:buzz/spark/voice_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _ipcPort = int.fromEnvironment('SPARK_LIVE_IPC_PORT');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'production native voice reaches live provider with synthetic chat boundary',
    (tester) async {
      if (_ipcPort <= 0 || _ipcPort > 65535) {
        fail(
          'SPARK_LIVE_IPC_PORT is required; use tool/ios_dev.dart spark-live.',
        );
      }

      debugPrint('spark-live:runtime-config');
      final config = await _awaitWithPumps(
        tester,
        _readRuntimeConfig(),
        timeout: const Duration(seconds: 10),
        label: 'private runtime configuration',
      );
      final store = _MemorySparkSettingsStore(config.settings, config.token);
      final session = MethodChannelVoiceSession();
      final controller = SparkController(
        session: session,
        credentials: OmpBrokerCredentialSource(),
        store: store,
        chatBridge: _NativeProbeChatBridge(),
      );
      var observeRequestOutput = false;
      var observedRequestOutput = false;
      final outputEvents = session.events.listen((event) {
        if (observeRequestOutput &&
            event['type'] == 'levels' &&
            (event['output'] as num?) != null &&
            (event['output'] as num) > 0) {
          observedRequestOutput = true;
        }
      });
      addTearDown(() async {
        await outputEvents.cancel();
        debugPrint('spark-live:bounded-teardown');
        await _stopAndVerifyReleased(controller, session);
        controller.dispose();
      });

      debugPrint('spark-live:initialize');
      await controller.initialize().timeout(const Duration(seconds: 10));
      debugPrint('spark-live:start-native-session');
      await _awaitWithPumps(
        tester,
        controller.start(chatId: 'synthetic-native-chat'),
        timeout: const Duration(seconds: 30),
        label: 'native session start',
      );
      if (config.muteTiming == _MuteTiming.beforeConnection) {
        debugPrint('spark-live:mute-before-connection');
        await session.setMuted(true).timeout(const Duration(seconds: 10));
      }
      await _pumpUntil(
        tester,
        () => controller.snapshot.phase == SparkPhase.listening,
        timeout: const Duration(seconds: 45),
        label: 'provider connection',
      );
      expect(controller.snapshot.micEnabled, isTrue);

      if (config.muteTiming == _MuteTiming.afterConnection) {
        debugPrint('spark-live:mute-immediately-after-connection');
      }
      debugPrint('spark-live:mute-capture');
      await controller
          .setMicEnabled(false)
          .timeout(const Duration(seconds: 10));
      expect(controller.snapshot.phase, SparkPhase.muted);
      expect(controller.snapshot.micEnabled, isFalse);
      final transcriptBeforeRequest = controller.snapshot.transcript.length;
      observeRequestOutput = true;

      debugPrint('spark-live:typed-request');
      await controller
          .sendText('Reply aloud with exactly: Spark probe ready.')
          .timeout(const Duration(seconds: 10));
      await _pumpUntil(
        tester,
        () => controller.snapshot.transcript
            .skip(transcriptBeforeRequest)
            .any(
              (entry) =>
                  entry.role == SparkTranscriptRole.assistant &&
                  entry.isFinal &&
                  entry.text.contains('Spark probe ready'),
            ),
        timeout: const Duration(seconds: 90),
        label:
            'causal final assistant transcript '
            '(error=${controller.snapshot.error != null}, '
            'requestOutput=$observedRequestOutput)',
      );
      await _pumpUntil(
        tester,
        () => observedRequestOutput,
        timeout: const Duration(seconds: 30),
        label: 'post-request native output audio level',
      );

      debugPrint('spark-live:stop-native-session');
      await _stopAndVerifyReleased(controller, session);
      debugPrint('spark-live:complete');
    },
  );
}

/// A synthetic local chat boundary: this test measures native provider audio,
/// not host integration, transport echo, or a live coding-agent conversation.
class _NativeProbeChatBridge implements SparkChatBridge {
  final _turns = <VoiceTurn>[];
  @override
  SparkChatObservation? current(String chatId) => SparkChatObservation(
    snapshot: const HarnessSnapshot(
      phase: ConnectionPhase.live,
      readOnly: false,
      title: 'Synthetic native probe',
    ),
    voiceTurns: List.unmodifiable(_turns),
  );

  @override
  Stream<SparkChatObservation> observe(String chatId) => const Stream.empty();

  @override
  Future<List<SparkChatChoice>> listChats() async => const [
    SparkChatChoice(
      id: 'synthetic-native-chat',
      label: 'Synthetic native probe',
      canSend: true,
      isLive: true,
    ),
  ];

  @override
  Future<void> saveTurn(String chatId, VoiceTurn turn) async {
    _turns.removeWhere((old) => old.id == turn.id);
    _turns.add(turn);
  }

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
  Future<SparkChatSendResult> sendOnce(
    String chatId,
    String text, {
    required String requestId,
  }) async => const SparkChatSendResult(SparkSendOutcome.rejected);
}

Future<_RuntimeConfig> _readRuntimeConfig() async {
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    _ipcPort,
  ).timeout(const Duration(seconds: 5));
  try {
    final bytes = <int>[];
    await for (final chunk in socket.timeout(const Duration(seconds: 5))) {
      bytes.addAll(chunk);
      if (bytes.length > 16 * 1024) {
        throw const FormatException('Runtime configuration was too large.');
      }
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map ||
        decoded['brokerUrl'] is! String ||
        decoded['token'] is! String ||
        decoded['muteTiming'] is! String) {
      throw const FormatException('Runtime configuration was invalid.');
    }
    final brokerUrl = (decoded['brokerUrl'] as String).trim();
    final token = (decoded['token'] as String).trim();
    final muteTiming = switch (decoded['muteTiming']) {
      'before-connection' => _MuteTiming.beforeConnection,
      'after-connection' => _MuteTiming.afterConnection,
      _ => throw const FormatException('Runtime mute timing was invalid.'),
    };
    if (brokerUrl.isEmpty || token.isEmpty) {
      throw const FormatException('Runtime configuration was incomplete.');
    }
    return _RuntimeConfig(
      SparkSettings(
        brokerUrl: brokerUrl,
        allowInsecureHttp: decoded['allowInsecureHttp'] == true,
      ),
      token,
      muteTiming,
    );
  } finally {
    socket.destroy();
  }
}

Future<void> _stopAndVerifyReleased(
  SparkController controller,
  MethodChannelVoiceSession session,
) async {
  await controller.stop().timeout(const Duration(seconds: 10));
  expect(controller.snapshot.phase, SparkPhase.idle);
  expect(controller.snapshot.micEnabled, isFalse);
  expect(controller.snapshot.inputLevel, 0);
  expect(controller.snapshot.outputLevel, 0);
  await expectLater(
    session.sendText('post-stop lifecycle probe'),
    throwsA(
      isA<PlatformException>().having(
        (error) => error.code,
        'code',
        'not_started',
      ),
    ),
  );
}

Future<T> _awaitWithPumps<T>(
  WidgetTester tester,
  Future<T> future, {
  required Duration timeout,
  required String label,
}) async {
  var completed = false;
  Object? failure;
  StackTrace? failureTrace;
  T? value;
  future.then(
    (result) {
      value = result;
      completed = true;
    },
    onError: (Object error, StackTrace trace) {
      failure = error;
      failureTrace = trace;
      completed = true;
    },
  );
  await _pumpUntil(tester, () => completed, timeout: timeout, label: label);
  if (failure != null) Error.throwWithStackTrace(failure!, failureTrace!);
  return value as T;
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required Duration timeout,
  required String label,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(condition(), isTrue, reason: 'Timed out waiting for $label.');
}

enum _MuteTiming { beforeConnection, afterConnection }

final class _RuntimeConfig {
  const _RuntimeConfig(this.settings, this.token, this.muteTiming);
  final SparkSettings settings;
  final String token;
  final _MuteTiming muteTiming;
}

final class _MemorySparkSettingsStore implements SparkSettingsStore {
  _MemorySparkSettingsStore(this._settings, this._token);
  SparkSettings _settings;
  String? _token;

  @override
  Future<StoredSparkSettings> load() async => StoredSparkSettings(
    settings: _settings,
    hasBrokerToken: _token?.isNotEmpty == true,
  );

  @override
  Future<String?> readBrokerToken() async => _token;

  @override
  Future<void> save(SparkSettings settings, {String? brokerToken}) async {
    _settings = settings;
    if (brokerToken != null) _token = brokerToken.trim();
  }
}
