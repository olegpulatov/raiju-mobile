import 'dart:async';

import '../companion_controller.dart';
import '../harness/harness.dart';
import '../storage/voice_transcript.dart';
import 'chat_bridge.dart';
import 'models.dart';

/// Existing collab send path only: no queue, remote abort, or automatic retry.
class CompanionSparkChatBridge implements SparkChatBridge {
  CompanionSparkChatBridge(this._controller);
  final CompanionController _controller;
  final Set<String> _attemptedRequestIds = <String>{};

  @override
  Future<List<SparkChatChoice>> listChats() async {
    await _controller.initialize();
    return _controller.chats
        .map((thread) {
          final snapshot = thread.snapshot;
          return SparkChatChoice(
            id: thread.id,
            label: thread.title,
            canSend:
                snapshot.phase == ConnectionPhase.live && !snapshot.readOnly,
            isLive: snapshot.phase == ConnectionPhase.live,
          );
        })
        .toList(growable: false);
  }

  @override
  SparkChatObservation? current(String chatId) {
    final thread = _controller.chat(chatId);
    return thread == null
        ? null
        : SparkChatObservation(
            snapshot: thread.snapshot,
            voiceTurns: thread.voiceTurns,
          );
  }

  @override
  Stream<SparkChatObservation> observe(String chatId) {
    late StreamController<SparkChatObservation> stream;
    void changed() {
      final observation = current(chatId);
      if (stream.isClosed) return;
      if (observation == null) {
        _controller.removeListener(changed);
        unawaited(stream.close());
      } else {
        stream.add(observation);
      }
    }

    stream = StreamController<SparkChatObservation>(
      onListen: () {
        _controller.addListener(changed);
        changed();
      },
      onCancel: () => _controller.removeListener(changed),
    );
    return stream.stream;
  }

  @override
  Future<void> saveTurn(String chatId, VoiceTurn turn) async {
    _controller.upsertVoiceTurn(chatId, turn);
    await _controller.flush();
  }

  @override
  Future<void> flush(String chatId) => _controller.flush();

  @override
  void activateDirective(String chatId, String directive) =>
      _controller.activateVoiceDirective(chatId, directive);

  @override
  void setPromptPreparer(
    String chatId,
    Future<String> Function(String text)? prepare,
  ) => _controller.setPromptPreparer(chatId, prepare);
  @override
  void setPromptDeliveryObserver(
    String chatId,
    void Function(String actualText, bool localSent)? observer,
  ) => _controller.setPromptDeliveryObserver(chatId, observer);

  @override
  Future<SparkChatSendResult> sendOnce(
    String chatId,
    String text, {
    required String requestId,
  }) async {
    final thread = _controller.chat(chatId);
    if (thread == null) {
      return const SparkChatSendResult(
        SparkSendOutcome.rejected,
        message: 'The bound chat is no longer open.',
      );
    }
    if (thread.snapshot.phase != ConnectionPhase.live ||
        thread.snapshot.readOnly) {
      return const SparkChatSendResult(
        SparkSendOutcome.rejected,
        message: 'The bound chat cannot send now.',
      );
    }
    if (!_attemptedRequestIds.add(requestId)) {
      return const SparkChatSendResult(
        SparkSendOutcome.rejected,
        message: 'This delegation was already attempted.',
      );
    }
    try {
      final sentText = await _controller.sendPrompt(
        chatId,
        text,
        fromComposer: false,
      );
      // Socket completion is not host consumption; wait for exact observed echo.
      return SparkChatSendResult(
        SparkSendOutcome.uncertain,
        sentText: sentText,
      );
    } on PromptBusyException {
      // sendPrompt rejected before its socket write; this is definitely
      // unsent and may be explicitly retried with this same request ID.
      _attemptedRequestIds.remove(requestId);
      return const SparkChatSendResult(
        SparkSendOutcome.rejected,
        message: 'Another prompt is in flight; no delegation was sent.',
      );
    } catch (_) {
      return const SparkChatSendResult(
        SparkSendOutcome.uncertain,
        message: 'Host delivery could not be confirmed.',
      );
    }
  }
}
