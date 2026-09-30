import 'dart:async';

import 'package:raiju_mobile/features/settings/settings_page.dart';
import 'package:raiju_mobile/shared/theme/theme.dart';
import 'package:raiju_mobile/spark/spark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets('prompt edits save and secret field is obscured then cleared', (
    tester,
  ) async {
    final store = _Store();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sparkVoiceSessionProvider.overrideWithValue(_Session()),
          sparkCredentialSourceProvider.overrideWithValue(_Credentials()),
          sparkSettingsStoreProvider.overrideWithValue(store),
          sparkChatBridgeProvider.overrideWithValue(
            const UnavailableSparkChatBridge(),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: SparkSettingsEditor()),
        ),
      ),
    );
    await tester.pump();

    final secret = tester.widget<TextField>(
      find.byKey(const ValueKey('spark-broker-token')),
    );
    expect(secret.obscureText, isTrue);
    await tester.enterText(
      find.byKey(const ValueKey('spark-broker-token')),
      'synthetic-placeholder-not-a-token',
    );
    await tester.enterText(
      find.byKey(const ValueKey('spark-prompt-name')),
      'Focused companion',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final showThinking = find.byKey(const ValueKey('spark-show-thinking'));
    await tester.scrollUntilVisible(
      showThinking,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(
      tester.element(showThinking),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(showThinking);
    await tester.pumpAndSettle();
    final announce = find.byKey(
      const ValueKey('spark-announce-terminal-replies'),
    );
    await tester.scrollUntilVisible(
      announce,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(tester.element(announce), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(announce);
    await tester.pumpAndSettle();
    final toolMode = find.byKey(const ValueKey('spark-tool-visibility'));
    await tester.scrollUntilVisible(
      toolMode,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(tester.element(toolMode), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(toolMode);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show').last);
    await tester.pumpAndSettle();
    for (final (key, text) in [
      ('spark-user-name', 'Nina'),
      ('spark-context-addition', 'User-facing context addition'),
      ('spark-main-agent-directive', 'Two-model mode for Nina'),
      ('spark-agent-final-message', 'Completed: {{message}}'),
    ]) {
      final field = find.byKey(ValueKey(key));
      await tester.scrollUntilVisible(
        field,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, text);
    }
    for (
      var attempt = 0;
      attempt < 4 &&
          find.byKey(const ValueKey('spark-save-settings')).evaluate().isEmpty;
      attempt++
    ) {
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pump();
    }
    await tester.ensureVisible(
      find.byKey(const ValueKey('spark-save-settings')),
    );
    await tester.tap(find.byKey(const ValueKey('spark-save-settings')));
    await tester.pump();

    expect(store.settings?.promptPresets.single.name, 'Focused companion');
    expect(store.settings?.userName, 'Nina');
    expect(store.settings?.contextAddition, 'User-facing context addition');
    expect(store.settings?.mainAgentDirective, 'Two-model mode for Nina');
    expect(store.settings?.agentFinalMessage, 'Completed: {{message}}');
    expect(store.settings?.toolVisibility, SparkToolVisibility.show);
    expect(store.settings?.hideThinking, isFalse);
    expect(store.settings?.announceTerminalReplies, isFalse);
    final tokenField = find.byKey(const ValueKey('spark-broker-token'));
    await tester.scrollUntilVisible(
      tokenField,
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(tester.element(tokenField), alignment: 0.5);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(tokenField).controller!.text, isEmpty);
  });
  testWidgets('editor waits for protected settings before allowing edits', (
    tester,
  ) async {
    final delayed = Completer<StoredSparkSettings>();
    final store = _Store()..pendingLoad = delayed.future;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sparkVoiceSessionProvider.overrideWithValue(_Session()),
          sparkCredentialSourceProvider.overrideWithValue(_Credentials()),
          sparkSettingsStoreProvider.overrideWithValue(store),
          sparkChatBridgeProvider.overrideWithValue(
            const UnavailableSparkChatBridge(),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: SparkSettingsEditor()),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('spark-save-settings')), findsNothing);
    delayed.complete(
      const StoredSparkSettings(
        settings: SparkSettings(
          userName: 'Existing name',
          promptPresets: [
            SparkPromptPreset(
              id: 'spark-default',
              name: 'Existing preset',
              instructions: 'Existing edited instructions',
            ),
          ],
          mainAgentDirective: 'Existing directive',
          hideThinking: false,
          announceTerminalReplies: false,
        ),
        hasBrokerToken: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('spark-prompt-name')))
          .controller!
          .text,
      'Existing preset',
    );
    final save = find.byKey(const ValueKey('spark-save-settings'));
    await tester.scrollUntilVisible(
      save,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(save);
    await tester.pump();
    expect(
      store.settings?.promptPresets.single.instructions,
      'Existing edited instructions',
    );
    expect(store.settings?.userName, 'Existing name');
    expect(store.settings?.mainAgentDirective, 'Existing directive');
    expect(store.settings?.hideThinking, isFalse);
    expect(store.settings?.announceTerminalReplies, isFalse);
  });

  testWidgets('nonfatal save error does not lock the settings editor', (
    tester,
  ) async {
    final store = _Store()..failSave = true;
    final container = ProviderContainer(
      overrides: [
        sparkVoiceSessionProvider.overrideWithValue(_Session()),
        sparkCredentialSourceProvider.overrideWithValue(_Credentials()),
        sparkSettingsStoreProvider.overrideWithValue(store),
        sparkChatBridgeProvider.overrideWithValue(
          const UnavailableSparkChatBridge(),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(sparkControllerProvider);
    await controller.initialize();
    await expectLater(
      controller.saveSettings(const SparkSettings()),
      throwsA(isA<SparkStoreException>()),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: SparkSettingsEditor()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final promptName = find.byKey(const ValueKey('spark-prompt-name'));
    expect(promptName, findsOneWidget);
    await tester.enterText(promptName, 'Retry after save error');
    final save = find.byKey(const ValueKey('spark-save-settings'));
    await tester.scrollUntilVisible(
      save,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(tester.element(save), alignment: 0.5);
    await tester.pumpAndSettle();
    expect(save, findsOneWidget);
    store.failSave = false;
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(store.settings?.promptPresets.single.name, 'Retry after save error');
    expect(find.text('Spark settings saved securely.'), findsOneWidget);
  });
}

class _Session implements VoiceSession {
  final _events = StreamController<Map<String, Object?>>.broadcast();
  @override
  Stream<Map<String, Object?>> get events => _events.stream;
  @override
  Future<void> dispose() => _events.close();
  @override
  Future<void> sendText(
    String text, {
    String? delegationId,
    String channel = 'speakable',
  }) async {}
  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> start({
    required String accessToken,
    String? accountId,
    required String instructions,
    required String voice,
  }) async {}
  @override
  Future<void> stop() async {}
}

class _Credentials implements SparkCredentialSource {
  @override
  Future<SparkCredentialResult> acquire(
    SparkSettings settings,
    String brokerToken,
  ) async => const SparkCredentialResult(choices: []);
}

class _Store implements SparkSettingsStore {
  SparkSettings? settings;
  Future<StoredSparkSettings>? pendingLoad;
  bool failSave = false;
  @override
  Future<StoredSparkSettings> load() =>
      pendingLoad ??
      Future.value(
        const StoredSparkSettings(
          settings: SparkSettings(),
          hasBrokerToken: false,
        ),
      );
  @override
  Future<String?> readBrokerToken() async => null;
  @override
  Future<void> save(SparkSettings settings, {String? brokerToken}) async {
    if (failSave) {
      throw const SparkStoreException('Spark settings could not be saved.');
    }
    this.settings = settings;
  }
}
