import '../harness/harness.dart';
import '../storage/voice_transcript.dart';
import 'models.dart';

enum SparkSendOutcome { accepted, rejected, uncertain }

class SparkChatSendResult {
  const SparkChatSendResult(this.outcome, {this.message, this.sentText});
  final SparkSendOutcome outcome;
  final String? message;

  /// Exact actual collab prompt (including the first-send directive decorator).
  final String? sentText;
}

class SparkChatObservation {
  const SparkChatObservation({
    required this.snapshot,
    required this.voiceTurns,
  });
  final HarnessSnapshot snapshot;
  final List<VoiceTurn> voiceTurns;
}

abstract interface class SparkChatBridge {
  Future<List<SparkChatChoice>> listChats();
  Stream<SparkChatObservation> observe(String chatId);
  SparkChatObservation? current(String chatId);
  Future<void> saveTurn(String chatId, VoiceTurn turn);
  Future<void> flush(String chatId);
  void activateDirective(String chatId, String directive);
  void setPromptPreparer(
    String chatId,
    Future<String> Function(String text)? prepare,
  );
  void setPromptDeliveryObserver(
    String chatId,
    void Function(String actualText, bool localSent)? observer,
  );
  Future<SparkChatSendResult> sendOnce(
    String chatId,
    String text, {
    required String requestId,
  });
}

class UnavailableSparkChatBridge implements SparkChatBridge {
  const UnavailableSparkChatBridge();
  @override
  Future<List<SparkChatChoice>> listChats() async => const [];
  @override
  Stream<SparkChatObservation> observe(String chatId) => const Stream.empty();
  @override
  SparkChatObservation? current(String chatId) => null;
  @override
  Future<void> saveTurn(String chatId, VoiceTurn turn) async =>
      throw StateError('Main-agent chat is unavailable.');
  @override
  Future<void> flush(String chatId) async =>
      throw StateError('Main-agent chat is unavailable.');
  @override
  void activateDirective(String chatId, String directive) {}
  @override
  void setPromptPreparer(
    String chatId,
    Future<String> Function(String text)? prepare,
  ) {}
  @override
  void setPromptDeliveryObserver(
    String chatId,
    void Function(String actualText, bool localSent)? observer,
  ) {}
  @override
  Future<SparkChatSendResult> sendOnce(
    String chatId,
    String text, {
    required String requestId,
  }) async => const SparkChatSendResult(
    SparkSendOutcome.rejected,
    message: 'Main-agent chat is unavailable.',
  );
}
