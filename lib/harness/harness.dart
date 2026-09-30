/// UI-facing session contract. Harness protocols stay behind this boundary.
enum ConnectionPhase {
  disconnected,
  connecting,
  syncing,
  live,
  reconnecting,
  ended,
  error,
}

enum MessageRole { user, assistant, tool, system }

enum ChatMessageOrigin { remoteUser, remoteAssistant, collabUser, system, tool }

/// Received event, not a synthetic run/correlation identifier.
class AgentEvent {
  const AgentEvent({required this.sequence, required this.event});
  final int sequence;
  final Map<String, Object?> event;
  String get type => event['type'] is String ? event['type'] as String : '';
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    this.author,
    this.timestamp,
    this.isStreaming = false,
    this.thinking = '',
    this.isError = false,
    this.source,
    this.prose,
    this.origin,
  });

  final String id;
  final MessageRole role;
  final String text;
  final String? author;
  final DateTime? timestamp;
  final bool isStreaming;
  final String thinking;
  final bool isError;

  /// Original entry/message, kept distinct from presentation text.
  final Map<String, Object?>? source;

  /// Eligible source-derived user-facing prose. Null means source unknown.
  final String? prose;
  final ChatMessageOrigin? origin;
}

class QuestionOption {
  const QuestionOption(this.label, {this.description});
  final String label;
  final String? description;
}

/// Explicit host interaction, never automatically answered or approved.
class HarnessQuestion {
  const HarnessQuestion({
    required this.id,
    required this.title,
    required this.kind,
    this.options = const [],
    this.prefill = '',
    this.helpText,
    this.selectionMarker,
    this.checkedIndices = const [],
    this.markableCount,
  });

  final int id;
  final String title;
  final String kind;
  final List<QuestionOption> options;
  final String prefill;
  final String? helpText;
  final String? selectionMarker;
  final List<int> checkedIndices;
  final int? markableCount;
}

class HarnessSnapshot {
  const HarnessSnapshot({
    this.phase = ConnectionPhase.disconnected,
    this.title = 'OMP chat',
    this.sessionId,
    this.sessionStartedAt,
    this.endpoint = '',
    this.model = '',
    this.messages = const [],
    this.readOnly = true,
    this.isStreaming = false,
    this.activity = '',
    this.error,
    this.questions = const [],
    this.rawEntries = const [],
    this.agentEvents = const [],
  });

  final ConnectionPhase phase;
  final String title;

  /// Session creation time from the host header; not a message timestamp.
  final DateTime? sessionStartedAt;
  final String? sessionId;

  /// Public relay host only, never a bearer link or a room secret.
  final String endpoint;
  final String model;
  final List<ChatMessage> messages;
  final bool readOnly;
  final bool isStreaming;
  final String activity;

  /// Sanitized, actionable user-facing failure. Never include credentials.
  final String? error;
  final List<HarnessQuestion> questions;

  /// Original host records, including entries not rendered in the timeline.
  final List<Map<String, Object?>> rawEntries;

  /// Ordered live events as received; sequences are local, never host run IDs.
  final List<AgentEvent> agentEvents;

  bool get canSend => phase == ConnectionPhase.live && !readOnly;
}

class HarnessException implements Exception {
  const HarnessException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Nothing reached the socket; unlike a transport failure this is safe to
/// retry explicitly after the competing prompt settles.
class PromptBusyException extends HarnessException {
  const PromptBusyException() : super('Another prompt is still being sent.');
}

/// A connection to one remote session. No login or account is required.
abstract interface class HarnessClient {
  HarnessSnapshot get snapshot;
  Stream<HarnessSnapshot> get changes;

  /// Completes after the initial snapshot is ready, or fails with a safe error.
  Future<void> connect(String input, {String displayName = 'raiju'});

  /// Sends once. It must never queue or replay a prompt across reconnects.
  Future<void> sendPrompt(String text);
  Future<void> abort();
  Future<void> respond(int requestId, String? value);
  Future<void> disconnect();
  Future<void> dispose();
}

typedef HarnessClientFactory = HarnessClient Function();
