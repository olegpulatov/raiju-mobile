import '../harness/harness.dart';
import '../harness/voice_directive.dart';
import '../storage/voice_transcript.dart';

/// Only actual source prose, never rendered thinking/tool/status placeholders.
String sparkSourceProse(Object? content) {
  if (content is String) return content;
  if (content is! List) return '';
  return content
      .whereType<Map>()
      .where((block) => block['type'] == 'text')
      .map((block) => block['text'])
      .whereType<String>()
      .join('\n');
}

/// Actual remote input shapes from collaboration and RPC, not rendered text.
String? sparkPromptSource(Map message) =>
    message['role'] == 'user' ||
        (message['role'] == 'custom' &&
            message['customType'] == 'collab-prompt')
    ? sparkSourceProse(message['content'])
    : null;

String? sparkEntryPromptSource(Map<String, Object?> entry) {
  if (entry['type'] == 'custom_message' &&
      entry['customType'] == 'collab-prompt') {
    return sparkSourceProse(entry['content']);
  }
  final message = entry['message'];
  return entry['type'] == 'message' &&
          message is Map &&
          message['role'] == 'user'
      ? sparkSourceProse(message['content'])
      : null;
}

String sparkVoiceSpeaker(VoiceTurnOrigin origin) =>
    origin == VoiceTurnOrigin.spark ? 'Voice Assistant Spark' : 'User';

String sparkRoutingLabel(VoiceTurn turn) =>
    turn.routingPurpose == VoiceTurnPurpose.lateContext
    ? 'User (historical late context; not a new request)'
    : sparkVoiceSpeaker(turn.origin);

/// Main input is an incremental projection, not a replay of the saved chat.
/// Identity is per turn: equal human utterances are both retained.
SparkRoutingPackage sparkRoutingPackage(List<VoiceTurn> turns, String request) {
  final ordered = turns.toList()
    ..sort((a, b) => a.sequence.compareTo(b.sequence));
  final users = ordered
      .where(
        (turn) =>
            (turn.origin == VoiceTurnOrigin.user ||
                turn.origin == VoiceTurnOrigin.typedUser) &&
            turn.routingPurpose != VoiceTurnPurpose.request &&
            turn.routingPurpose != VoiceTurnPurpose.lateContext &&
            turn.delivery == VoiceDelivery.pending &&
            turn.text.trim().isNotEmpty,
      )
      .toList();
  final selected = <VoiceTurn>[];
  final meaningful = request.trim();
  if (users.isNotEmpty || meaningful.isNotEmpty) {
    final first = users.isEmpty ? 0 : users.first.sequence;
    final last = users.isEmpty ? 0 : users.last.sequence;
    final userIds = users.map((turn) => turn.id).toSet();
    final historicalIds = ordered
        .where(
          (turn) =>
              turn.routingPurpose == VoiceTurnPurpose.lateContext &&
              turn.delivery == VoiceDelivery.pending &&
              turn.text.trim().isNotEmpty,
        )
        .map((turn) => turn.id)
        .toSet();
    for (final turn in ordered) {
      if (userIds.contains(turn.id) ||
          historicalIds.contains(turn.id) ||
          (turn.sequence > first &&
              turn.sequence < last &&
              turn.origin == VoiceTurnOrigin.spark &&
              turn.routingPurpose == VoiceTurnPurpose.dialogue &&
              turn.delivery == VoiceDelivery.pending &&
              turn.text.trim().isNotEmpty)) {
        selected.add(turn);
      }
    }
  }
  final overlap = users.where((turn) => turn.text.trim() == meaningful);
  final matched = meaningful.isEmpty || overlap.isEmpty ? null : overlap.first;
  final body = [
    for (final turn in selected) '${sparkRoutingLabel(turn)}: ${turn.text}',
    if (meaningful.isNotEmpty && matched == null) meaningful,
  ].join('\n');
  return SparkRoutingPackage(body, selected, matched?.id);
}

class SparkRoutingPackage {
  const SparkRoutingPackage(this.body, this.turns, this.overlapTurnId);
  final String body;
  final List<VoiceTurn> turns;
  final String? overlapTurnId;
}

/// Removes only an exact serialized voice prefix from a confirmed echo.
/// Returns null when the persisted turns cannot explain this source prompt.
String? sparkVoiceEchoRemainder(String rawPrompt, List<VoiceTurn> anchored) {
  if (anchored.isEmpty) return null;
  final ordered = anchored.toList()
    ..sort((a, b) => a.sequence.compareTo(b.sequence));
  final reservation = ordered
      .where(
        (turn) =>
            turn.routingPurpose == VoiceTurnPurpose.request &&
            turn.routingPackageText != null,
      )
      .toList();
  if (reservation.length == 1 &&
      VoiceDirective.strip(rawPrompt) ==
          reservation.single.routingPackageText) {
    return '';
  }
  final prefix = ordered
      .map((turn) => '${sparkVoiceSpeaker(turn.origin)}: ${turn.text}')
      .join('\n');
  final prompt = VoiceDirective.strip(rawPrompt);
  if (prompt == prefix) return '';
  if (prompt.startsWith('$prefix\n')) {
    return prompt.substring(prefix.length + 1);
  }
  return null;
}

String sparkConversationContext(
  List<ChatMessage> messages,
  List<VoiceTurn> turns, {
  required int characterBudget,
}) {
  final items = <_ContextItem>[];
  final byEcho = <String, List<VoiceTurn>>{};
  for (final turn in turns) {
    if (turn.hostEntryId case final id?) (byEcho[id] ??= []).add(turn);
  }
  final byAnchor = <String?, List<VoiceTurn>>{};
  final renderedIds = messages.map((message) => message.id).toSet();
  for (final turn in turns) {
    final anchor = turn.precedingRenderedEntryId ?? turn.precedingHostEntryId;
    (byAnchor[renderedIds.contains(anchor) ? anchor : null] ??= []).add(turn);
  }
  for (final group in byAnchor.values) {
    group.sort((a, b) => a.sequence.compareTo(b.sequence));
  }
  void addTurns(String? anchor) {
    for (final turn in byAnchor.remove(anchor) ?? const <VoiceTurn>[]) {
      if (turn.text.trim().isNotEmpty &&
          !(turn.routingPurpose == VoiceTurnPurpose.request &&
              turn.routingSourceTurnId != null)) {
        items.add(
          _ContextItem(
            turn.id,
            turn.routingPurpose == VoiceTurnPurpose.request
                ? 'User request to main'
                : sparkVoiceSpeaker(turn.origin),
            turn.text.trim(),
          ),
        );
      }
    }
  }

  addTurns(null);
  for (final message in messages) {
    if (!message.isStreaming &&
        !message.isError &&
        (message.role == MessageRole.user ||
            message.role == MessageRole.assistant)) {
      // Known source must never fall back to ChatMessage.text.
      final raw =
          message.prose ??
          (message.source == null
              ? ''
              : sparkSourceProse(message.source!['content']));
      final echoTurns = byEcho[message.id] ?? const <VoiceTurn>[];
      final cachedRemainder =
          echoTurns.isNotEmpty &&
              message.source == null &&
              (message.origin == ChatMessageOrigin.collabUser ||
                  message.origin == ChatMessageOrigin.remoteUser) &&
              echoTurns.every(
                (turn) =>
                    turn.echoRemainder != null &&
                    turn.echoRemainder == echoTurns.first.echoRemainder,
              )
          ? echoTurns.first.echoRemainder
          : null;
      final remainder =
          cachedRemainder ?? sparkVoiceEchoRemainder(raw, echoTurns);
      if (remainder == null) {
        final prose = VoiceDirective.strip(raw).trim();
        if (prose.isNotEmpty) {
          items.add(
            _ContextItem(
              message.id,
              message.role == MessageRole.user ? 'User' : 'Assistant',
              prose,
            ),
          );
        }
      } else if (remainder.trim().isNotEmpty) {
        items.add(
          _ContextItem(
            message.id,
            echoTurns.every((turn) => turn.typedEcho)
                ? 'User'
                : 'Voice Assistant Spark',
            remainder.trim(),
          ),
        );
      }
    }
    addTurns(message.id);
  }
  final seen = <String>{};
  final newest = <String>[];
  var remaining = characterBudget;
  for (final item in items.reversed) {
    if (!seen.add(item.id)) continue;
    final line = '${item.label}: ${item.text}';
    if (line.length > remaining) break;
    newest.add(line);
    remaining -= line.length + 1;
  }
  return newest.reversed.join('\n');
}

class _ContextItem {
  const _ContextItem(this.id, this.label, this.text);
  final String id;
  final String label;
  final String text;
}
