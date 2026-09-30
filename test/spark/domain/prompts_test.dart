import 'package:buzz/spark/models.dart';
import 'package:buzz/spark/prompts.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('shipped prompt assets match editable defaults exactly', () async {
    final defaults = {
      'spark-live-instructions.md': sparkDefaultInstructions,
      'spark-context-addition.md': sparkDefaultContextAddition,
      'spark-main-agent-directive.md': sparkDefaultMainAgentDirective,
      'spark-agent-final-message.md': sparkDefaultAgentFinalMessage,
    };
    for (final entry in defaults.entries) {
      final asset = await rootBundle.loadString(
        'lib/spark/prompts/${entry.key}',
      );
      // First line is the MIT adaptation/provenance notice, not instructions.
      expect(asset.substring(asset.indexOf('\n') + 1).trimRight(), entry.value);
    }
  });

  test(
    'prompts render edited name, additions, directive and final wrapper',
    () {
      const settings = SparkSettings(
        userName: 'Nina',
        contextAddition: 'Shared history belongs to {{userName}}.',
        mainAgentDirective: 'Speak directly to {{userName}}.',
        agentFinalMessage: '"Agent Final Message":\n\n{{message}}',
      );
      final instructions = composeSparkInstructions(
        settings,
        recentConversation: 'User: hello\nAssistant: hi',
      );
      expect(instructions, contains('assistant working with Nina.'));
      expect(instructions, contains('Shared history belongs to Nina.'));
      expect(instructions, endsWith('User: hello\nAssistant: hi\n</context>'));
      expect(instructions, isNot(contains('{{userName}}')));
      expect(
        renderSparkMainAgentDirective(settings),
        'Speak directly to Nina.',
      );
      expect(
        renderSparkFinalMessage(settings, 'Work finished.'),
        '"Agent Final Message":\n\nWork finished.',
      );
      expect(composeSparkInstructions(settings), isNot(contains('<context>')));
    },
  );
}
