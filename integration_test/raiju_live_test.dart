import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:buzz/app.dart';
import 'package:buzz/companion_controller.dart';
import 'package:buzz/harness/harness.dart';
import 'package:buzz/harness/omp_collab_client.dart';
import 'package:buzz/raiju/acceptance_probe.dart';
import 'package:buzz/raiju/companion_provider.dart';
import 'package:buzz/shared/theme/theme_provider.dart';
import 'package:buzz/spark/context.dart';
import 'package:buzz/spark/spark.dart';
import 'package:buzz/storage/encrypted_file_chat_store.dart';
import 'package:buzz/storage/voice_transcript.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _marker = String.fromEnvironment('RAIJU_LIVE_MARKER');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('private local capability opens real host and receives durable marker', (
    tester,
  ) async {
    if (_marker.isEmpty) {
      fail('RAIJU_LIVE_MARKER is required; use tool/ios_dev.dart live.');
    }
    debugPrint('raiju-live:local-capability');
    final capability = await _awaitWithPumps(
      tester,
      _readCapabilityFromTool(),
      timeout: const Duration(seconds: 10),
      label: 'private local capability',
    );
    if (capability.isEmpty) {
      fail('The private local OMP link was empty.');
    }

    debugPrint('raiju-live:secure-store');
    final preferences = await SharedPreferences.getInstance().timeout(
      const Duration(seconds: 10),
    );
    await preferences
        .setInt(acceptancePreviousProcessKey, pid)
        .timeout(const Duration(seconds: 10));
    final store = await EncryptedFileChatStore.production().timeout(
      const Duration(seconds: 20),
    );
    final controller = CompanionController(
      clientFactory: OmpCollabClient.new,
      store: store,
      writeDebounce: Duration.zero,
    );
    debugPrint('raiju-live:controller-initialize');
    await controller.initialize().timeout(const Duration(seconds: 30));
    addTearDown(() {
      debugPrint('raiju-live:controller-dispose');
      controller.dispose();
    });
    final existingChatIds = controller.chats.map((chat) => chat.id).toSet();
    final voiceSession = _LiveFixtureVoiceSession();
    final bridge = CompanionSparkChatBridge(controller);
    final spark = SparkController(
      session: voiceSession,
      credentials: const _LiveFixtureCredentials(),
      store: const _LiveFixtureSettings(),
      chatBridge: bridge,
    );
    await spark.initialize();
    addTearDown(spark.dispose);
    debugPrint('raiju-live:render');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          savedPrefsProvider.overrideWithValue(preferences),
          companionControllerProvider.overrideWith((ref) => controller),
          sparkControllerProvider.overrideWith((ref) => spark),
          sparkChatBridgeProvider.overrideWithValue(bridge),
        ],
        child: const App(),
      ),
    );
    await _pumpUntilCondition(
      tester,
      () =>
          find.byKey(const Key('connect-omp-session')).evaluate().isNotEmpty ||
          find.byTooltip('Create or start conversation').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 20),
    );
    final emptyConnect = find.byKey(const Key('connect-omp-session'));
    if (emptyConnect.evaluate().isNotEmpty) {
      await _tapWhenHittable(tester, emptyConnect);
    } else {
      await _tapWhenHittable(
        tester,
        find.byTooltip('Create or start conversation'),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const Key('quick-action-create-channel-card')),
        findsOneWidget,
      );
      await _tapWhenHittable(
        tester,
        find.byKey(const Key('quick-action-create-channel-card')),
      );
    }
    await _pumpUntil(tester, find.byKey(const ValueKey('raiju-paste-toggle')));
    await _tapWhenHittable(
      tester,
      find.byKey(const ValueKey('raiju-paste-toggle')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('raiju-join-input')),
      capability,
    );
    await _tapWhenHittable(
      tester,
      find.byKey(const ValueKey('raiju-join-submit')),
    );
    debugPrint('raiju-live:joining-host');
    await _pumpUntil(
      tester,
      find.text('Message…'),
      timeout: const Duration(seconds: 45),
    );
    await _tapWhenHittable(tester, find.text('Message…'));
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('raiju-composer-input')),
    );
    final joined = controller.chats.singleWhere(
      (chat) => !existingChatIds.contains(chat.id),
    );
    expect(joined.snapshot.canSend, isTrue);

    await tester.enterText(
      find.byKey(const ValueKey('raiju-composer-input')),
      'Reply with exactly $_marker and no other text. Do not use tools.',
    );
    await _pumpUntilCondition(tester, () {
      final send = find.byKey(const ValueKey('raiju-send'));
      return send.evaluate().isNotEmpty &&
          tester.widget<IconButton>(send).onPressed != null;
    }, timeout: const Duration(seconds: 20));
    await _tapWhenHittable(tester, find.byKey(const ValueKey('raiju-send')));
    debugPrint('raiju-live:waiting-reply');
    await _pumpUntilCondition(
      tester,
      () => joined.snapshot.messages.any(
        (message) =>
            message.role == MessageRole.assistant &&
            !message.isStreaming &&
            message.text.contains(_marker),
      ),
      timeout: const Duration(seconds: 90),
    );
    final assistantReply = joined.snapshot.messages.lastWhere(
      (message) =>
          message.role == MessageRole.assistant &&
          !message.isStreaming &&
          message.text.contains(_marker),
    );
    final assistantRow = find.byKey(
      ValueKey('message-row-${assistantReply.id}'),
    );
    expect(
      find.descendant(
        of: assistantRow,
        matching: find.textContaining(_marker, findRichText: true),
      ),
      findsWidgets,
    );
    await _pumpUntilCondition(
      tester,
      () => !joined.snapshot.isStreaming,
      timeout: const Duration(seconds: 30),
      evidence: () =>
          'Original marker reply did not reach terminal host state '
          '(streaming=${joined.snapshot.isStreaming}).',
    );
    // Real collab transport + synthetic voice engine: starting voice must
    // never create a host prompt. Only the explicit safe delegation below
    // may send a second fixture marker.
    final priorEchoIds = joined.snapshot.rawEntries
        .where(
          (entry) =>
              entry['type'] == 'custom_message' &&
              entry['customType'] == 'collab-prompt',
        )
        .map((entry) => entry['id'])
        .whereType<String>()
        .toSet();
    await _awaitWithPumps(
      tester,
      spark.start(chatId: joined.id),
      timeout: const Duration(seconds: 20),
      label: 'synthetic voice start on the connected chat',
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(voiceSession.started, isTrue);
    expect(
      joined.snapshot.rawEntries
          .where(
            (entry) =>
                entry['type'] == 'custom_message' &&
                entry['customType'] == 'collab-prompt',
          )
          .map((entry) => entry['id'])
          .whereType<String>()
          .toSet(),
      priorEchoIds,
      reason: 'Starting Spark emitted an unsolicited host prompt.',
    );
    final sparkMarker =
        'SPARK_${sha256.convert(utf8.encode(_marker)).toString().substring(0, 20)}';
    final delegationId = 'synthetic-${sparkMarker.toLowerCase()}';
    final spokenRequest = 'Synthetic spoken request for $sparkMarker';
    final spokenReply = 'Synthetic Spark acknowledgement for $sparkMarker';
    voiceSession.emit({
      'type': 'transcript',
      'role': 'user',
      'text': spokenRequest,
      'final': true,
      'id': '$delegationId-user',
    });
    voiceSession.emit({
      'type': 'transcript',
      'role': 'assistant',
      'text': spokenReply,
      'final': true,
      'id': '$delegationId-spark',
    });
    await _pumpUntilCondition(
      tester,
      () =>
          joined.voiceTurns.any((turn) => turn.text == spokenRequest) &&
          joined.voiceTurns.any((turn) => turn.text == spokenReply),
      timeout: const Duration(seconds: 20),
    );
    voiceSession.emit({
      'type': 'delegation',
      'id': delegationId,
      'text':
          'Reply with exactly $sparkMarker and no other text. Do not use tools.',
    });
    debugPrint('raiju-live:waiting-spark-host-consumption');
    await _pumpUntilCondition(
      tester,
      () {
        final turns = joined.voiceTurns
            .where(
              (turn) => turn.text == spokenRequest || turn.text == spokenReply,
            )
            .toList();
        return turns.length == 2 &&
            turns.firstWhere((turn) => turn.text == spokenRequest).delivery ==
                VoiceDelivery.delivered &&
            turns.firstWhere((turn) => turn.text == spokenRequest).hostEntryId
                is String &&
            turns.firstWhere((turn) => turn.text == spokenReply).hostEntryId ==
                null &&
            voiceSession.sent.any(
              (item) =>
                  item.delegationId == delegationId &&
                  item.channel == 'speakable' &&
                  item.text.contains(sparkMarker),
            );
      },
      timeout: const Duration(seconds: 120),
      evidence: () {
        final turns = joined.voiceTurns.where(
          (turn) => turn.text == spokenRequest || turn.text == spokenReply,
        );
        return 'Connected Spark host confirmation unavailable: '
            'turns=${turns.length} delivered=${turns.where((turn) => turn.delivery == VoiceDelivery.delivered).length} '
            'echoes=${joined.snapshot.rawEntries.where((entry) => entry['customType'] == 'collab-prompt' && !priorEchoIds.contains(entry['id'])).length} '
            'hostEvents=${joined.snapshot.agentEvents.length} '
            'speakable=${voiceSession.sent.where((item) => item.channel == 'speakable').length}.';
      },
    );
    final hostEcho = joined.voiceTurns
        .firstWhere((turn) => turn.text == spokenRequest)
        .hostEntryId!;
    expect(
      joined.voiceTurns
          .firstWhere((turn) => turn.text == spokenReply)
          .hostEntryId,
      isNull,
    );
    final echoed = joined.snapshot.rawEntries
        .where((entry) => entry['id'] == hostEcho)
        .toList();
    expect(
      echoed.length == 1 &&
          echoed.single['type'] == 'custom_message' &&
          echoed.single['customType'] == 'collab-prompt' &&
          sparkSourceProse(echoed.single['content']).contains(sparkMarker),
      isTrue,
      reason: 'Delivered turns lacked one real matching collab-prompt echo.',
    );
    expect(
      joined.snapshot.rawEntries
          .where(
            (entry) =>
                entry['type'] == 'custom_message' &&
                entry['customType'] == 'collab-prompt' &&
                !priorEchoIds.contains(entry['id']),
          )
          .length,
      1,
      reason: 'Connected voice emitted an unexpected extra host prompt.',
    );
    final echoText = sparkSourceProse(echoed.single['content']);
    expect(echoText, contains(spokenRequest));
    expect(echoText, isNot(contains(spokenReply)));
    expect(
      joined.snapshot.agentEvents.any(
        (record) =>
            (record.type == 'message_start' || record.type == 'message_end') &&
            record.event['message'] is Map &&
            (record.event['message'] as Map)['role'] == 'custom' &&
            (record.event['message'] as Map)['customType'] == 'collab-prompt' &&
            sparkSourceProse((record.event['message'] as Map)['content']) ==
                echoText,
      ),
      isTrue,
      reason: 'No real-wire matching host prompt-consumption event.',
    );
    expect(
      joined.snapshot.agentEvents.any((record) {
        if (record.type != 'agent_end' ||
            record.event['isTerminal'] == false ||
            record.event['messages'] is! List) {
          return false;
        }
        final messages = (record.event['messages'] as List)
            .whereType<Map>()
            .toList();
        return messages
                    .where(
                      (message) =>
                          message['role'] == 'custom' &&
                          message['customType'] == 'collab-prompt' &&
                          sparkSourceProse(message['content']) == echoText,
                    )
                    .length ==
                1 &&
            messages.any(
              (message) =>
                  message['role'] == 'assistant' &&
                  message['stopReason'] == 'stop' &&
                  sparkSourceProse(message['content']).contains(sparkMarker),
            );
      }),
      isTrue,
      reason: 'No terminal real-wire run owned this prompt and final marker.',
    );
    expect(
      voiceSession.sent
          .where(
            (item) =>
                item.delegationId == delegationId &&
                item.channel == 'speakable' &&
                item.text.contains(sparkMarker),
          )
          .length,
      1,
    );
    await _awaitWithPumps(
      tester,
      spark.stop(),
      timeout: const Duration(seconds: 10),
      label: 'stopping synthetic voice without aborting the host',
    );
    expect(voiceSession.stopped, isTrue);
    expect(joined.snapshot.phase, ConnectionPhase.live);
    expect(joined.snapshot.canSend, isTrue);

    const draft = 'live smoke draft (safe to discard)';
    await tester.enterText(
      find.byKey(const ValueKey('raiju-composer-input')),
      draft,
    );
    await tester.pump();
    expect(joined.draft, draft);
    // Seed only the joined test chat; these turns are never sent to OMP.
    final replyDigest = sha256.convert(utf8.encode(_marker)).toString();
    final firstSequence = joined.voiceTurns.fold<int>(
      0,
      (next, turn) => turn.sequence >= next ? turn.sequence + 1 : next,
    );
    for (final turn in acceptanceVoiceTurns(replyDigest, firstSequence)) {
      controller.upsertVoiceTurn(joined.id, turn);
    }
    final voice = inspectAcceptanceVoiceTurns(joined.voiceTurns, replyDigest);
    expect(
      voice.text && voice.origin && voice.delivery && voice.ordering,
      isTrue,
    );
    debugPrint('raiju-live:flush');
    await controller.flush().timeout(const Duration(seconds: 20));
    debugPrint('raiju-live:complete');
  });
}

Future<String> _readCapabilityFromTool() async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, 38471);
  try {
    return (await utf8.decoder.bind(socket).join()).trim();
  } finally {
    socket.destroy();
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
}) => _pumpUntilCondition(
  tester,
  () => finder.evaluate().isNotEmpty,
  timeout: timeout,
);

Future<void> _pumpUntilCondition(
  WidgetTester tester,
  bool Function() condition, {
  required Duration timeout,
  String Function()? evidence,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(
    condition(),
    isTrue,
    reason: evidence?.call() ?? 'Timed out waiting for the UI state.',
  );
}

Future<void> _tapWhenHittable(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
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

Future<T> _awaitWithPumps<T>(
  WidgetTester tester,
  Future<T> future, {
  required Duration timeout,
  required String label,
}) async {
  var completed = false;
  late T value;
  Object? error;
  StackTrace? stackTrace;
  future.then(
    (result) {
      value = result;
      completed = true;
    },
    onError: (Object caught, StackTrace caughtStack) {
      error = caught;
      stackTrace = caughtStack;
      completed = true;
    },
  );
  final deadline = DateTime.now().add(timeout);
  while (!completed && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  if (!completed) fail('Timed out waiting for $label.');
  if (error case final caught?) {
    Error.throwWithStackTrace(caught, stackTrace!);
  }
  return value;
}

/// Only the companion bridge touches the real host; this fake has no network
/// or microphone implementation and records the final voice feedback.
final class _LiveFixtureVoiceSession implements VoiceSession {
  final _events = StreamController<Map<String, Object?>>.broadcast();
  final sent = <({String text, String? delegationId, String channel})>[];
  bool started = false;
  bool stopped = false;

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  void emit(Map<String, Object?> event) => _events.add(event);

  @override
  Future<void> start({
    required String accessToken,
    String? accountId,
    required String instructions,
    required String voice,
  }) async {
    started = true;
    emit(const {'type': 'connected'});
  }

  @override
  Future<void> stop() async {
    stopped = true;
    emit(const {'type': 'closed'});
  }

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> sendText(
    String text, {
    String? delegationId,
    String channel = 'speakable',
  }) async {
    sent.add((text: text, delegationId: delegationId, channel: channel));
  }

  @override
  Future<void> dispose() async {
    if (!_events.isClosed) await _events.close();
  }
}

final class _LiveFixtureCredentials implements SparkCredentialSource {
  const _LiveFixtureCredentials();

  @override
  Future<SparkCredentialResult> acquire(
    SparkSettings settings,
    String brokerToken,
  ) async => const SparkCredentialResult(
    choices: [SparkCredentialChoice(id: 'fixture', label: 'Offline fixture')],
    credential: SparkCredential(
      id: 'fixture',
      accessToken: 'offline-fixture-only',
      expiresAtMs: 4102444800000,
    ),
  );
}

final class _LiveFixtureSettings implements SparkSettingsStore {
  const _LiveFixtureSettings();

  @override
  Future<StoredSparkSettings> load() async => const StoredSparkSettings(
    settings: SparkSettings(brokerUrl: 'https://fixture.invalid'),
    hasBrokerToken: true,
  );

  @override
  Future<String?> readBrokerToken() async => 'offline-fixture-only';

  @override
  Future<void> save(SparkSettings settings, {String? brokerToken}) async {}
}
