import 'models.dart';

// MIT-licensed OMP Iskra prompt adaptation. Original source hashes are recorded
// alongside the corresponding defaults and Markdown assets.
String _withUserName(String text, String userName) =>
    text.replaceAll('{{userName}}', userName.trim());

/// Render complete instructions before appending an already-budgeted prose-only
/// history slice. The caller budgets the entire result, never truncating prompts.
String composeSparkInstructions(
  SparkSettings settings, {
  String recentConversation = '',
}) {
  final instructions = _withUserName(
    settings.selectedPreset.instructions,
    settings.userName,
  );
  final addition = _withUserName(settings.contextAddition, settings.userName);
  final parts = [instructions, addition];
  if (recentConversation.trim().isNotEmpty) {
    parts.add('<context>\n$recentConversation\n</context>');
  }
  return parts.join('\n\n');
}

String renderSparkMainAgentDirective(SparkSettings settings) =>
    _withUserName(settings.mainAgentDirective, settings.userName);

String renderSparkFinalMessage(SparkSettings settings, String message) =>
    _withUserName(
      settings.agentFinalMessage,
      settings.userName,
    ).replaceAll('{{message}}', message);
