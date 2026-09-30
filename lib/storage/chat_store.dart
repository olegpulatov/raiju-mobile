import '../harness/harness.dart';
import 'voice_transcript.dart';

/// A sanitized, bounded snapshot retained for immediate offline display.
class StoredSnapshot {
  const StoredSnapshot({
    required this.title,
    required this.endpoint,
    required this.model,
    required this.messages,
    required this.readOnly,
    this.rawEntries = const [],
    this.sessionStartedAt,
  });

  final String title;
  final String endpoint;

  /// Host session creation time, when the header supplied a valid timestamp.
  final DateTime? sessionStartedAt;
  final String model;
  final List<ChatMessage> messages;
  final bool readOnly;
  final List<Map<String, Object?>> rawEntries;
}

/// Everything needed to restore one chat. [link] is a credential and must only
/// be handled by an encrypted store.
class StoredChat {
  const StoredChat({
    required this.id,
    required this.link,
    required this.label,
    required this.draft,
    required this.reconnect,
    required this.snapshot,
    this.createdAt,
    this.localLabel,
    this.voiceTurns = const [],
  });

  final String id;
  final String link;
  final String label;
  final String draft;
  final bool reconnect;

  /// Original connection time, persisted independently of cached messages.
  final DateTime? createdAt;

  /// Null means an older payload; controller infers whether label was local.
  final bool? localLabel;
  final StoredSnapshot snapshot;
  final List<VoiceTurn> voiceTurns;
}

abstract interface class ChatStore {
  Future<List<StoredChat>> load();
  Future<void> save(List<StoredChat> chats);
}

enum ChatStoreFailure { corrupt, keyUnavailable, capacity, io }

class ChatStoreException implements Exception {
  const ChatStoreException(this.failure, this.message, [this.cause]);

  final ChatStoreFailure failure;
  final String message;
  final Object? cause;

  @override
  String toString() => message;
}
