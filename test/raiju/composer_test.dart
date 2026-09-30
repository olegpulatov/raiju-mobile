import 'dart:async';

import 'package:buzz/companion_controller.dart';
import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channel_detail_page.dart';
import 'package:buzz/features/channels/compose_bar.dart';
import 'package:buzz/features/channels/emoji_picker.dart';
import 'package:buzz/features/channels/send_message_provider.dart';
import 'package:buzz/harness/harness.dart';
import 'package:buzz/raiju/companion_provider.dart';
import 'package:buzz/shared/custom_emoji/custom_emoji_provider.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:buzz/spark/spark.dart';
import 'package:buzz/storage/chat_store.dart';
import 'package:buzz/storage/voice_transcript.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'send facade delegates plain text and rejects Buzz-only payloads',
    () async {
      final calls = <(String, String)>[];
      final send = SendMessage.companion(
        (id, text) async => calls.add((id, text)),
      );

      await send(channelId: 'chat-1', content: 'hello');
      expect(calls, <(String, String)>[('chat-1', 'hello')]);
      await expectLater(
        send(channelId: 'chat-1', content: 'x', parentEventId: 'thread'),
        throwsUnsupportedError,
      );
      await expectLater(
        send(
          channelId: 'chat-1',
          content: 'x',
          mediaTags: const [
            <String>['imeta'],
          ],
        ),
        throwsUnsupportedError,
      );
      await expectLater(
        send(
          channelId: 'chat-1',
          content: 'x',
          mentionPubkeys: const ['nostr'],
        ),
        throwsUnsupportedError,
      );
    },
  );

  testWidgets('original composer edits, persists draft, and sends once', (
    tester,
  ) async {
    final fixture = await _Fixture.live();
    await tester.pumpWidget(fixture.app());

    await tester.tap(find.text('Message…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('raiju-composer-input')),
      'draft text',
    );
    await tester.pump();
    expect(fixture.controller.chat(fixture.id)!.draft, 'draft text');

    await tester.tap(find.byKey(const ValueKey('raiju-send')));
    await tester.pump();
    expect(fixture.client.prompts, const ['draft text']);
    expect(fixture.controller.chat(fixture.id)!.draft, isEmpty);
  });

  testWidgets(
    'bound live Spark composer sends voice once and awaits delegation',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = await _Fixture.live();
      final session = _VoiceSession();
      final spark = SparkController(
        session: session,
        credentials: _Credentials(),
        store: _SparkStore(),
        chatBridge: CompanionSparkChatBridge(fixture.controller),
      );
      await spark.start(chatId: fixture.id);
      session.emit({'type': 'connected'});
      await tester.pumpWidget(fixture.detailApp(spark));
      await tester.pump(const Duration(milliseconds: 30));
      expect(spark.snapshot.phase, isNot(SparkPhase.connecting));

      await tester.tap(find.text('Message…'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.enterText(
        find.byKey(const ValueKey('raiju-composer-input')),
        'Inspect the parser',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(fixture.controller.chat(fixture.id)!.snapshot.canSend, isTrue);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('raiju-send')))
            .onPressed,
        isNotNull,
      );
      tester
          .widget<IconButton>(find.byKey(const ValueKey('raiju-send')))
          .onPressed!();
      await tester.pump(const Duration(milliseconds: 30));

      expect(session.sent, ['Inspect the parser']);
      expect(fixture.client.prompts, isEmpty);
      expect(fixture.controller.chat(fixture.id)!.draft, isEmpty);
      expect(
        fixture.controller
            .chat(fixture.id)!
            .voiceTurns
            .where((turn) => turn.origin == VoiceTurnOrigin.typedUser)
            .map((turn) => turn.text),
        ['Inspect the parser'],
      );
      expect(find.text('Inspect the parser'), findsOneWidget);

      session.emit({
        'type': 'delegation',
        'id': 'typed-request',
        'text': 'Inspect the parser',
      });
      await tester.pump(const Duration(milliseconds: 30));
      expect(fixture.client.prompts, hasLength(1));
      expect(fixture.client.prompts.single, contains('Inspect the parser'));
      expect(session.sent, ['Inspect the parser']);
    },
  );

  testWidgets('failed bound Spark send keeps composer draft', (tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = await _Fixture.live();
    final session = _VoiceSession()..failSend = true;
    final spark = SparkController(
      session: session,
      credentials: _Credentials(),
      store: _SparkStore(),
      chatBridge: CompanionSparkChatBridge(fixture.controller),
    );
    await spark.start(chatId: fixture.id);
    session.emit({'type': 'connected'});
    await tester.pumpWidget(fixture.detailApp(spark));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.text('Message…'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(
      find.byKey(const ValueKey('raiju-composer-input')),
      'keep voice draft',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final send = tester
        .widget<IconButton>(find.byKey(const ValueKey('raiju-send')))
        .onPressed;
    expect(send, isNotNull);
    send!();
    await tester.pump(const Duration(milliseconds: 30));
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('raiju-composer-input')))
          .controller!
          .text,
      'keep voice draft',
    );
    expect(fixture.controller.chat(fixture.id)!.draft, 'keep voice draft');
    expect(fixture.client.prompts, isEmpty);
    expect(fixture.controller.chat(fixture.id)!.voiceTurns, isEmpty);
  });

  testWidgets('saved companion draft hydrates with selection intact', (
    tester,
  ) async {
    final fixture = await _Fixture.live();
    fixture.controller.updateDraft(fixture.id, 'restored draft');
    await tester.pumpWidget(fixture.app());
    await tester.tap(find.text('restored draft'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('raiju-composer-input')),
    );
    expect(field.controller!.text, 'restored draft');
    expect(field.controller!.selection.baseOffset, 'restored draft'.length);
  });

  testWidgets('failed remote send preserves editor and persistent draft', (
    tester,
  ) async {
    final fixture = await _Fixture.live(failSend: true);
    await tester.pumpWidget(fixture.app());
    await tester.tap(find.text('Message…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('raiju-composer-input')),
      'keep this',
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('raiju-send')));
    await tester.pump();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('raiju-composer-input')),
    );
    expect(field.controller!.text, 'keep this');
    expect(fixture.controller.chat(fixture.id)!.draft, 'keep this');
    expect(fixture.client.prompts, isEmpty);
  });

  testWidgets(
    'read-only chat keeps dock visible but disables editor and send',
    (tester) async {
      final fixture = await _Fixture.live(readOnly: true);
      await tester.pumpWidget(fixture.app());

      final send = tester.widget<IconButton>(
        find.byKey(const ValueKey('raiju-send')),
      );
      expect(send.onPressed, isNull);
      await tester.tap(find.text('Message…'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('raiju-composer-input')), findsNothing);
    },
  );

  testWidgets('attachment and voice surfaces explain unavailable backend', (
    tester,
  ) async {
    final fixture = await _Fixture.live();
    await tester.pumpWidget(fixture.app());

    await tester.tap(find.byTooltip('Add attachment').hitTestable());
    await tester.pump();
    expect(find.text('Voice note'), findsOneWidget);
    await tester.tap(find.text('Voice note'));
    await tester.pump();
    expect(
      find.text(
        'Attachments and voice notes are not available for OMP chats yet.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('local emoji picker never reads Buzz custom emoji provider', (
    tester,
  ) async {
    final fixture = await _Fixture.live();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          customEmojiListProvider.overrideWith(
            (ref) => throw StateError('Buzz emoji provider was activated'),
          ),
          savedPrefsProvider.overrideWithValue(preferences),
        ],
        child: fixture.app(),
      ),
    );
    await tester.tap(find.text('Message…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(LucideIcons.smilePlus).hitTestable());
    await tester.pump();
    expect(find.byType(EmojiPickerSheet), findsOneWidget);
  });
}

class _Fixture {
  _Fixture(this.controller, this.client, this.id);

  final CompanionController controller;
  final _Client client;
  final String id;

  static Future<_Fixture> live({
    bool readOnly = false,
    bool failSend = false,
  }) async {
    final client = _Client(readOnly: readOnly, failSend: failSend);
    final controller = CompanionController(
      clientFactory: () => client,
      store: _Store(),
      writeDebounce: Duration.zero,
    );
    await controller.initialize();
    final thread = await controller.join('synthetic-test-capability');
    return _Fixture(controller, client, thread.id);
  }

  Widget app() {
    final send = SendMessage.companion(controller.sendPrompt);
    return ProviderScope(
      overrides: [
        companionControllerProvider.overrideWith((ref) => controller),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ComposeBar(
            channelId: id,
            companionMode: true,
            onSend: (content, mentions, {mediaTags = const []}) => send(
              channelId: id,
              content: content,
              mentionPubkeys: mentions,
              mediaTags: mediaTags,
            ),
          ),
        ),
      ),
    );
  }

  Widget detailApp(SparkController spark) => ProviderScope(
    overrides: [
      companionControllerProvider.overrideWith((ref) => controller),
      sparkControllerProvider.overrideWith((ref) => spark),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: ChannelDetailPage(
        channel: Channel(
          id: id,
          name: 'Test chat',
          channelType: 'dm',
          visibility: 'private',
          description: '',
          createdBy: 'local',
          createdAt: DateTime.utc(2026),
          memberCount: 2,
          isMember: true,
        ),
      ),
    ),
  );
}

class _Store implements ChatStore {
  List<StoredChat> records = const [];

  @override
  Future<List<StoredChat>> load() async => records;

  @override
  Future<void> save(List<StoredChat> chats) async {
    records = List<StoredChat>.of(chats);
  }
}

class _Client implements HarnessClient {
  _Client({required bool readOnly, this.failSend = false})
    : _snapshot = HarnessSnapshot(
        phase: ConnectionPhase.live,
        readOnly: readOnly,
        title: 'Test chat',
      );

  final bool failSend;

  HarnessSnapshot _snapshot;
  final _changes = StreamController<HarnessSnapshot>.broadcast();
  final List<String> prompts = [];

  @override
  HarnessSnapshot get snapshot => _snapshot;

  @override
  Stream<HarnessSnapshot> get changes => _changes.stream;

  @override
  Future<void> connect(String input, {String displayName = 'raiju'}) async {}

  @override
  Future<void> sendPrompt(String text) async {
    if (!_snapshot.canSend) throw const HarnessException('read-only');
    if (failSend) throw const HarnessException('synthetic send failure');
    prompts.add(text);
  }

  @override
  Future<void> abort() async {}

  @override
  Future<void> respond(int requestId, String? value) async {}

  @override
  Future<void> disconnect() async {
    _snapshot = const HarnessSnapshot(phase: ConnectionPhase.disconnected);
    _changes.add(_snapshot);
  }

  @override
  Future<void> dispose() async => _changes.close();
}

class _VoiceSession implements VoiceSession {
  final _events = StreamController<Map<String, Object?>>.broadcast();
  final sent = <String>[];
  bool failSend = false;

  void emit(Map<String, Object?> event) => _events.add(event);

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> start({
    required String accessToken,
    String? accountId,
    required String instructions,
    required String voice,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> sendText(
    String text, {
    String? delegationId,
    String channel = 'speakable',
  }) async {
    if (failSend) throw StateError('synthetic voice send failure');
    sent.add(text);
  }

  @override
  Future<void> dispose() => _events.close();
}

class _Credentials implements SparkCredentialSource {
  @override
  Future<SparkCredentialResult> acquire(
    SparkSettings settings,
    String brokerToken,
  ) async => const SparkCredentialResult(
    choices: [SparkCredentialChoice(id: 'one', label: 'One')],
    credential: SparkCredential(
      id: 'one',
      accessToken: 'synthetic-access',
      expiresAtMs: 9999999999999,
    ),
  );
}

class _SparkStore implements SparkSettingsStore {
  @override
  Future<StoredSparkSettings> load() async => const StoredSparkSettings(
    settings: SparkSettings(),
    hasBrokerToken: true,
  );

  @override
  Future<String?> readBrokerToken() async => 'synthetic-broker-token';

  @override
  Future<void> save(SparkSettings settings, {String? brokerToken}) async {}
}
