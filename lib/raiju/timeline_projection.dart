import '../spark/context.dart';
import '../spark/models.dart';
import '../storage/voice_transcript.dart';
import '../features/channels/timeline_message.dart';
import '../harness/harness.dart';
import '../storage/encrypted_file_chat_store.dart';

/// Keeps host history authoritative and voice turns in a separate local overlay.
/// Uses durable host/display anchors and local sequence order. Turns whose
/// anchors were evicted precede retained history; clocks never prove delivery.
List<TimelineMessage> projectTimelineMessages(
  Iterable<ChatMessage> messages, {
  Iterable<VoiceTurn> voiceTurns = const [],
  SparkToolVisibility toolVisibility = SparkToolVisibility.show,
  bool isVoiceBoundAndActive = false,
  bool hideThinking = true,
}) {
  final hideTools =
      toolVisibility == SparkToolVisibility.hide ||
      (toolVisibility == SparkToolVisibility.hideInVoice &&
          isVoiceBoundAndActive);
  final byId = <String, ChatMessage>{};
  final order = <String>[];
  var anonymousIndex = 0;
  for (final message in messages) {
    final messageIdentifier = message.id.trim();
    final id = messageIdentifier.isEmpty
        ? 'omp-message-${anonymousIndex++}'
        : messageIdentifier;
    if (!byId.containsKey(id)) order.add(id);
    byId[id] = message;
  }

  final turns = voiceTurns.toList()
    ..sort((left, right) => left.sequence.compareTo(right.sequence));
  final echoes = <String, List<VoiceTurn>>{};
  final beforeEcho = <String, List<VoiceTurn>>{};
  final after = <String, List<VoiceTurn>>{};
  final prefix = <VoiceTurn>[];
  final knownEntries = order.toSet();
  final hostIndex = <String, int>{
    for (var index = 0; index < order.length; index++) order[index]: index,
  };
  VoiceTurn? latestEchoedUser;
  for (final turn in turns) {
    // Empty request reservations remain in echo provenance after a late
    // source alias, but never become a transcript bubble.
    if (turn.text.trim().isEmpty &&
        turn.routingPurpose != VoiceTurnPurpose.request) {
      continue;
    }
    final echo = turn.hostEntryId;
    if ((turn.origin == VoiceTurnOrigin.user ||
            turn.origin == VoiceTurnOrigin.typedUser &&
                turn.routingPurpose != VoiceTurnPurpose.request) &&
        (echo == null || !knownEntries.contains(echo))) {
      latestEchoedUser = null;
    }
    if (echo != null && knownEntries.contains(echo)) {
      echoes.putIfAbsent(echo, () => []).add(turn);
      if (turn.origin == VoiceTurnOrigin.user ||
          turn.origin == VoiceTurnOrigin.typedUser &&
              turn.routingPurpose != VoiceTurnPurpose.request) {
        latestEchoedUser = turn;
      }
    }
    final rawAnchor = turn.precedingHostEntryId;
    final userEcho = latestEchoedUser?.hostEntryId;
    final displayAnchor = rawAnchor != null && knownEntries.contains(rawAnchor)
        ? rawAnchor
        : turn.precedingRenderedEntryId;
    if (turn.origin == VoiceTurnOrigin.spark &&
        (turn.routingPurpose == VoiceTurnPurpose.acknowledgement ||
            turn.routingPurpose == VoiceTurnPurpose.dialogue) &&
        turn.delivery == VoiceDelivery.pending &&
        userEcho != null &&
        hostIndex.containsKey(userEcho) &&
        (displayAnchor == null ||
            (hostIndex[displayAnchor] ?? -1) <= hostIndex[userEcho]!)) {
      // Event identity and local sequence outrank an old rendered anchor.
      // This prose was omitted from the host package, not from local chat.
      beforeEcho.putIfAbsent(userEcho, () => []).add(turn);
    } else if (displayAnchor != null && knownEntries.contains(displayAnchor)) {
      after.putIfAbsent(displayAnchor, () => []).add(turn);
    } else if (rawAnchor == null &&
        turn.precedingRenderedEntryId == null &&
        echo != null &&
        knownEntries.contains(echo)) {
      beforeEcho.putIfAbsent(echo, () => []).add(turn);
    } else {
      prefix.add(turn);
    }
  }
  final echoedPrompts = <String, String>{};
  for (final entry in echoes.entries) {
    final message = byId[entry.key]!;
    if (message.source?['customType'] != 'collab-prompt' &&
        message.source?['role'] != 'user' &&
        !(message.source == null &&
            (message.origin == ChatMessageOrigin.collabUser ||
                message.origin == ChatMessageOrigin.remoteUser))) {
      continue;
    }
    final anchored = entry.value;
    final durableRemainder =
        message.source == null &&
            anchored.every(
              (turn) =>
                  turn.delivery == VoiceDelivery.delivered &&
                  turn.echoRemainder != null &&
                  turn.echoRemainder == anchored.first.echoRemainder,
            )
        ? anchored.first.echoRemainder
        : null;
    final cached = message.prose ?? message.text;
    final remainder =
        durableRemainder ??
        (message.source == null &&
                cached.length >= EncryptedFileChatStore.maxMessageCharacters
            ? null
            : sparkVoiceEchoRemainder(
                message.source == null
                    ? cached
                    : sparkSourceProse(message.source?['content']),
                anchored,
              ));
    if (remainder != null) {
      echoedPrompts[entry.key] = remainder.trim();
    }
  }
  final fallbackTimestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final oldestHostTimestamp = byId.values
      .map((message) => message.timestamp)
      .whereType<DateTime>()
      .map((timestamp) => timestamp.millisecondsSinceEpoch ~/ 1000)
      .fold<int>(
        fallbackTimestamp,
        (oldest, timestamp) => timestamp < oldest ? timestamp : oldest,
      );
  final result = <TimelineMessage>[
    for (var index = 0; index < prefix.length; index++)
      if (_visibleVoice(prefix[index]))
        _projectVoice(
          prefix[index],
          oldestHostTimestamp - prefix.length + index,
        ),
  ];
  for (var index = 0; index < order.length; index++) {
    final id = order[index];
    final remote = byId[id]!;
    final timestamp = remote.timestamp == null
        ? fallbackTimestamp + index
        : remote.timestamp!.millisecondsSinceEpoch ~/ 1000;
    for (final turn in beforeEcho[id] ?? const <VoiceTurn>[]) {
      if (_visibleVoice(turn)) result.add(_projectVoice(turn, timestamp));
    }
    final echoRemainder = echoedPrompts[id];
    if (echoRemainder != '' &&
        !(hideTools && remote.role == MessageRole.tool)) {
      final text =
          echoRemainder ??
          (hideTools && remote.role == MessageRole.assistant
              ? remote.prose ??
                    (remote.source == null && remote.origin == null
                        ? remote.text
                        : '')
              : remote.text);
      if (!(hideTools &&
          remote.role == MessageRole.assistant &&
          text.trim().isEmpty)) {
        result.add(
          _project(
            remote,
            id,
            timestamp,
            text: text,
            hideThinking: hideThinking,
            hideTools: hideTools,
            origin:
                echoRemainder != null &&
                    echoes[id]!.any((turn) => !turn.typedEcho)
                ? TimelinePresentationRole.spark
                : null,
          ),
        );
      }
    }
    for (final turn in after[id] ?? const <VoiceTurn>[]) {
      if (_visibleVoice(turn)) result.add(_projectVoice(turn, timestamp));
    }
  }
  return result;
}

bool _visibleVoice(VoiceTurn turn) =>
    turn.routingPurpose != VoiceTurnPurpose.request ||
    (turn.routingSourceTurnId == null && turn.text.trim().isNotEmpty);

TimelineMessage _projectVoice(VoiceTurn turn, int fallbackTimestamp) {
  final (role, author) = switch (turn.origin) {
    VoiceTurnOrigin.user => (
      TimelinePresentationRole.recognizedSpeech,
      'You · voice',
    ),
    VoiceTurnOrigin.typedUser => (TimelinePresentationRole.local, 'You'),
    VoiceTurnOrigin.spark => (TimelinePresentationRole.spark, 'Spark'),
  };
  return TimelineMessage(
    id: 'spark:${turn.id}',
    pubkey: turn.origin == VoiceTurnOrigin.user ? 'voice-user' : role.name,
    createdAt: fallbackTimestamp,
    displayCreatedAt: turn.createdAt == null
        ? null
        : turn.createdAt!.millisecondsSinceEpoch ~/ 1000,
    content: turn.text,
    presentationRole: role,
    presentationAuthor: turn.routingPurpose == VoiceTurnPurpose.request
        ? 'You · Spark request'
        : author,
  );
}

TimelineMessage _project(
  ChatMessage message,
  String id,
  int fallbackTimestamp, {
  required String text,
  required bool hideTools,
  required bool hideThinking,
  TimelinePresentationRole? origin,
}) {
  final role =
      origin ??
      switch (message.role) {
        MessageRole.user => TimelinePresentationRole.local,
        MessageRole.assistant => TimelinePresentationRole.assistant,
        MessageRole.tool || MessageRole.system => TimelinePresentationRole.tool,
      };
  final fallbackAuthor = switch (role) {
    TimelinePresentationRole.local => 'You',
    TimelinePresentationRole.assistant => 'Assistant',
    TimelinePresentationRole.tool => 'Tool',
    TimelinePresentationRole.recognizedSpeech => 'You · voice',
    TimelinePresentationRole.spark => 'Spark',
  };
  return TimelineMessage(
    id: id,
    pubkey: role.name,
    createdAt: fallbackTimestamp,
    content: text,
    presentationRole: role,
    presentationAuthor: origin == TimelinePresentationRole.spark
        ? 'Spark'
        : message.author?.trim().isNotEmpty == true
        ? message.author!.trim()
        : fallbackAuthor,
    isStreaming: message.isStreaming,
    thinking: hideThinking ? '' : message.thinking,
    isError: message.isError,
  );
}
