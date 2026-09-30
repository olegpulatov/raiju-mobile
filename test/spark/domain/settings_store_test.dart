import 'dart:convert';
import 'package:buzz/spark/spark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'settings and token survive store recreation without transcripts',
    () async {
      final storage = _Storage();
      final first = SecureSparkSettingsStore(storage: storage);
      await first.save(
        const SparkSettings(
          brokerUrl: 'https://broker.example',
          voice: 'maple',
          hideThinking: false,
          announceTerminalReplies: false,
        ),
        brokerToken: 'synthetic-broker-token',
      );
      final second = SecureSparkSettingsStore(storage: storage);
      final restored = await second.load();
      expect(restored.settings.voice, 'maple');
      expect(restored.settings.hideThinking, isFalse);
      expect(restored.settings.announceTerminalReplies, isFalse);
      expect(restored.hasBrokerToken, isTrue);
      expect(await second.readBrokerToken(), 'synthetic-broker-token');
      await second.save(
        restored.settings.copyWith(
          hideThinking: true,
          announceTerminalReplies: true,
        ),
      );
      expect(await second.readBrokerToken(), 'synthetic-broker-token');
      expect(storage.values.keys, everyElement(startsWith('raiju.spark.')));
    },
  );

  test('corrupt settings fail visibly and remain untouched', () async {
    final storage = _Storage()..values['raiju.spark.protected.v1'] = '{broken';
    final store = SecureSparkSettingsStore(storage: storage);
    await expectLater(store.load(), throwsA(isA<SparkStoreException>()));
    expect(storage.values['raiju.spark.protected.v1'], '{broken');
  });

  test('semantic corruption latches and blocks overwrite', () async {
    final invalid = const SparkSettings().toJson()
      ..['promptPresets'] = <Object?>[];
    final encoded = jsonEncode({
      'version': 1,
      'settings': invalid,
      'brokerToken': 'synthetic-broker-token',
    });
    final storage = _Storage()..values['raiju.spark.protected.v1'] = encoded;
    final store = SecureSparkSettingsStore(storage: storage);
    await expectLater(store.load(), throwsA(isA<SparkStoreException>()));
    await expectLater(
      store.save(const SparkSettings()),
      throwsA(isA<SparkStoreException>()),
    );
    expect(storage.values['raiju.spark.protected.v1'], encoded);
  });

  test('save-first recreation cannot overwrite semantic corruption', () async {
    final invalid = const SparkSettings().toJson()
      ..['selectedPresetId'] = 'missing';
    final encoded = jsonEncode({'version': 1, 'settings': invalid});
    final storage = _Storage()..values['raiju.spark.protected.v1'] = encoded;
    final recreated = SecureSparkSettingsStore(storage: storage);
    await expectLater(
      recreated.save(const SparkSettings()),
      throwsA(isA<SparkStoreException>()),
    );
    expect(storage.values['raiju.spark.protected.v1'], encoded);
  });

  test(
    'new prompts name and tool preference survive protected recreation',
    () async {
      final storage = _Storage();
      final store = SecureSparkSettingsStore(storage: storage);
      await store.save(
        const SparkSettings(
          userName: 'Nina',
          contextAddition: 'shared context',
          mainAgentDirective: 'two models',
          agentFinalMessage: 'Reply: {{message}}',
          toolVisibility: SparkToolVisibility.show,
          hideThinking: false,
          announceTerminalReplies: false,
        ),
      );
      final restored = (await SecureSparkSettingsStore(
        storage: storage,
      ).load()).settings;
      expect(restored.userName, 'Nina');
      expect(restored.contextAddition, 'shared context');
      expect(restored.mainAgentDirective, 'two models');
      expect(restored.agentFinalMessage, 'Reply: {{message}}');
      expect(restored.toolVisibility, SparkToolVisibility.show);
      expect(restored.hideThinking, isFalse);
      expect(restored.announceTerminalReplies, isFalse);
    },
  );

  test(
    'only the exact old default preset migrates; edits are retained',
    () async {
      final legacy = const SparkSettings().toJson()
        ..remove('contextAddition')
        ..remove('mainAgentDirective')
        ..remove('agentFinalMessage')
        ..remove('toolVisibility')
        ..remove('hideThinking')
        ..remove('announceTerminalReplies')
        ..remove('userName')
        ..['handoffInstructions'] = sparkLegacyDefaultHandoffInstructions
        ..['promptPresets'] = [
          const SparkPromptPreset(
            id: 'spark-default',
            name: 'Spark',
            instructions: sparkLegacyDefaultInstructions,
          ).toJson(),
          const SparkPromptPreset(
            id: 'custom',
            name: 'Edited',
            instructions: '$sparkLegacyDefaultInstructions edited',
          ).toJson(),
        ];
      final storage = _Storage()
        ..values['raiju.spark.protected.v1'] = jsonEncode({
          'version': 1,
          'settings': legacy,
        });
      final restored = (await SecureSparkSettingsStore(
        storage: storage,
      ).load()).settings;
      expect(
        restored.promptPresets.first.instructions,
        sparkDefaultInstructions,
      );
      expect(
        restored.promptPresets.last.instructions,
        '$sparkLegacyDefaultInstructions edited',
      );
      expect(restored.toolVisibility, SparkToolVisibility.hideInVoice);
      expect(restored.hideThinking, isTrue);
      expect(restored.announceTerminalReplies, isTrue);
      expect(restored.userName, 'Oleg');
      expect(restored.contextAddition, sparkDefaultContextAddition);
      expect(
        jsonDecode(
          storage.values['raiju.spark.protected.v1']!,
        )['settings']['promptPresets'][0]['instructions'],
        sparkLegacyDefaultInstructions,
      );
    },
  );

  test(
    'missing preference keys default on without rewriting the old record',
    () async {
      final old = const SparkSettings().toJson()
        ..remove('hideThinking')
        ..remove('announceTerminalReplies');
      final encoded = jsonEncode({'version': 1, 'settings': old});
      final storage = _Storage()..values['raiju.spark.protected.v1'] = encoded;
      final store = SecureSparkSettingsStore(storage: storage);
      final restored = (await store.load()).settings;
      expect(restored.hideThinking, isTrue);
      expect(restored.announceTerminalReplies, isTrue);
      expect(storage.values['raiju.spark.protected.v1'], encoded);
      await store.save(restored.copyWith(hideThinking: false));
      final reloaded = (await SecureSparkSettingsStore(
        storage: storage,
      ).load()).settings;
      expect(reloaded.hideThinking, isFalse);
      expect(reloaded.announceTerminalReplies, isTrue);
    },
  );

  test('invalid preference type cannot erase protected settings', () async {
    final invalid = const SparkSettings().toJson()..['hideThinking'] = 'false';
    final encoded = jsonEncode({'version': 1, 'settings': invalid});
    final storage = _Storage()..values['raiju.spark.protected.v1'] = encoded;
    final store = SecureSparkSettingsStore(storage: storage);
    await expectLater(store.load(), throwsA(isA<SparkStoreException>()));
    await expectLater(
      store.save(const SparkSettings()),
      throwsA(isA<SparkStoreException>()),
    );
    expect(storage.values['raiju.spark.protected.v1'], encoded);
  });

  test('renamed old default retains its user-edited name and instructions', () {
    final record = const SparkSettings().toJson()
      ..['promptPresets'] = [
        const SparkPromptPreset(
          id: 'spark-default',
          name: 'My own preset',
          instructions: sparkLegacyDefaultInstructions,
        ).toJson(),
      ];
    final restored = SparkSettings.fromJson(record);
    expect(restored.selectedPreset.name, 'My own preset');
    expect(
      restored.selectedPreset.instructions,
      sparkLegacyDefaultInstructions,
    );
  });

  test(
    'edited legacy handoff stays stored but is never promoted to directive',
    () {
      final record = const SparkSettings().toJson()
        ..['handoffInstructions'] = 'Wait for explicit user approval';
      final restored = SparkSettings.fromJson(record);
      expect(restored.mainAgentDirective, sparkDefaultMainAgentDirective);
      expect(
        restored.legacyHandoffInstructions,
        'Wait for explicit user approval',
      );
      expect(
        SparkSettings.fromJson(restored.toJson()).legacyHandoffInstructions,
        'Wait for explicit user approval',
      );
    },
  );
}

class _Storage implements SparkProtectedStorage {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
