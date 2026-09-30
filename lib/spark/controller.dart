import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../harness/harness.dart';
import '../harness/voice_directive.dart';
import '../storage/voice_transcript.dart';
import 'chat_bridge.dart';
import 'context.dart';
import 'credential_broker.dart';
import 'models.dart';
import 'prompts.dart';
import 'settings_store.dart';
import 'transcript_reducer.dart';
import 'voice_session.dart';

class SparkController extends ChangeNotifier {
  SparkController({
    required VoiceSession session,
    required SparkCredentialSource credentials,
    required SparkSettingsStore store,
    required this.chatBridge,
    SparkTranscriptReducer? transcriptReducer,
  }) : _session = session,
       _credentials = credentials,
       _store = store,
       _transcripts = transcriptReducer ?? SparkTranscriptReducer();

  final VoiceSession _session;
  final SparkCredentialSource _credentials;
  final SparkSettingsStore _store;
  final SparkTranscriptReducer _transcripts;
  final SparkChatBridge chatBridge;
  SparkSettings _settings = const SparkSettings();
  SparkSnapshot _snapshot = const SparkSnapshot();
  List<SparkCredentialChoice> _eligibleCredentials = const [];
  bool _hasBrokerToken = false;
  bool _settingsLoaded = false;
  bool _disposed = false;
  int _generation = 0;
  int _request = 0;
  int _voiceSequence = 0;
  Future<void>? _initialization;
  StreamSubscription<Map<String, Object?>>? _events;
  StreamSubscription<SparkChatObservation>? _chatEvents;
  SparkCancellation? _startCancellation;
  final Map<Future<void>, String> _pendingWrites = {};
  final Set<String> _delegationIds = {};
  final List<_PendingIntent> _unsentIntents = [];
  int? _drainingIntentGeneration;
  final Set<String> _typedTurnIds = {};
  final Map<String, VoiceTurn> _finalTurns = {};
  final Map<String, VoiceTurn> _unsavedFinals = {};
  final Map<String, String> _turnChats = {};
  final Map<String, _Delegation> _delegations = {};
  final List<_TypedExposure> _typedExposures = [];
  String? _activeRequest;
  final Set<String> _uncertainChats = {};
  String? _boundChat;
  int _externalEventFloor = 0;
  int _externalProcessedSequence = 0;
  int _externalRunEpoch = 0;
  bool _afterDelegation = false;
  bool _afterMainResult = false;
  final Set<String> _claimedLateSources = {};
  final Set<String> _sourceBoundaryFailures = {};
  final Set<String> _terminalFingerprints = {};
  final List<String> _terminalFingerprintOrder = [];
  final Map<String, VoiceTurnPurpose> _assistantTurnPurposes = {};

  SparkSettings get settings => _settings;
  bool get settingsLoaded => _settingsLoaded;
  SparkSnapshot get snapshot => _snapshot;
  bool get hasBrokerToken => _hasBrokerToken;
  List<SparkCredentialChoice> get eligibleCredentials =>
      immutableList(_eligibleCredentials);
  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    try {
      final saved = await _store.load();
      _validateSettings(saved.settings);
      if (_disposed) return;
      _settings = saved.settings;
      _hasBrokerToken = saved.hasBrokerToken;
      _settingsLoaded = true;
      _snapshot = _snapshot.copyWith(clearError: true);
    } on SparkStoreException catch (error) {
      _fail(error.message);
    } catch (_) {
      _fail('Spark settings are unavailable.');
    }
    _notify();
  }

  Future<void> saveSettings(SparkSettings value, {String? brokerToken}) async {
    _validateSettings(value);
    try {
      await _store.save(value, brokerToken: brokerToken);
      if (_disposed) return;
      if (!_settings.announceTerminalReplies && value.announceTerminalReplies) {
        final events = _boundChat == null
            ? const <AgentEvent>[]
            : chatBridge.current(_boundChat!)?.snapshot.agentEvents ??
                  const <AgentEvent>[];
        for (final event in events) {
          if (event.sequence > _externalEventFloor) {
            _externalEventFloor = event.sequence;
          }
        }
      }
      _settings = value;
      if (brokerToken != null) _hasBrokerToken = brokerToken.trim().isNotEmpty;
      _snapshot = _snapshot.copyWith(clearError: true);
      _notify();
    } on SparkStoreException catch (error) {
      _setNonfatalError(error.message);
      rethrow;
    } catch (_) {
      const error = SparkStoreException('Spark settings could not be saved.');
      _setNonfatalError(error.message);
      throw error;
    }
  }

  Future<void> start({String? chatId}) async {
    if (_snapshot.phase == SparkPhase.connecting ||
        _snapshot.phase == SparkPhase.listening ||
        _snapshot.phase == SparkPhase.working ||
        _snapshot.phase == SparkPhase.speaking ||
        _snapshot.phase == SparkPhase.muted) {
      return;
    }
    final generation = ++_generation;
    _startCancellation?.cancel();
    final cancellation = SparkCancellation();
    _startCancellation = cancellation;
    await initialize();
    if (!_current(generation)) return;
    await _events?.cancel();
    await _chatEvents?.cancel();
    if (!_current(generation)) return;
    final target = chatId?.trim();
    if (target == null || target.isEmpty) {
      _fail('Open the intended main-agent chat before starting Spark.');
      throw StateError('Spark needs the intended active chat.');
    }
    final observation = chatBridge.current(target);
    if (observation == null ||
        observation.snapshot.phase != ConnectionPhase.live ||
        observation.snapshot.readOnly) {
      _fail('The intended main-agent chat must be connected and writable.');
      throw StateError('The bound chat is not writable.');
    }
    _boundChat = target;
    _voiceSequence = observation.voiceTurns.fold(
      0,
      (int max, turn) => turn.sequence > max ? turn.sequence : max,
    );
    _delegationIds.clear();
    _unsentIntents.clear();
    _drainingIntentGeneration = null;
    _typedTurnIds.clear();
    _delegations.clear();
    _typedExposures.clear();
    _terminalFingerprints.clear();
    _terminalFingerprintOrder.clear();
    _activeRequest = null;
    _transcripts.resetSession();
    _assistantTurnPurposes.clear();
    _afterDelegation = false;
    _afterMainResult = false;
    _externalEventFloor = observation.snapshot.agentEvents.fold(
      0,
      (int max, event) => event.sequence > max ? event.sequence : max,
    );
    _externalProcessedSequence = _externalEventFloor;
    _externalRunEpoch = 0;
    _claimedLateSources.clear();
    _sourceBoundaryFailures.clear();
    _snapshot = _snapshot.copyWith(
      phase: SparkPhase.connecting,
      micEnabled: false,
      transcript: const [],
      boundChatId: target,
      integrationStatus: 'Connected to ${observation.snapshot.title}',
      clearError: true,
    );
    _notify();
    try {
      // A restarted native voice session cannot emit the old session's final.
      // Close unresolved fallbacks durably before new speech can be observed.
      await _closeAwaitingSource(generation);
      if (!_current(generation)) return;
      final token = await _store.readBrokerToken();
      if (!_current(generation)) return;
      if (token == null || token.isEmpty) {
        throw const SparkBrokerException(
          'Save a broker token before starting Spark.',
        );
      }
      final result = _credentials is CancellableSparkCredentialSource
          ? await _credentials.acquireCancellable(
              _settings,
              token,
              cancellation,
            )
          : await _credentials.acquire(_settings, token);
      if (!_current(generation)) return;
      _eligibleCredentials = result.choices;
      final credential = result.credential;
      if (credential == null) {
        throw const SparkBrokerException(
          'Choose which ChatGPT account Spark should use.',
        );
      }
      final contextBudget = _startupContextBudget();
      chatBridge.activateDirective(
        target,
        renderSparkMainAgentDirective(_settings),
      );
      chatBridge.setPromptPreparer(
        target,
        (text) => _prepareTypedPrompt(target, text),
      );
      chatBridge.setPromptDeliveryObserver(target, (text, localSent) {
        if (_current(generation)) {
          _onTypedSend(target, text, localSent, generation);
        }
      });
      // Only events after the actual subscription boundary are new voice
      // observations; token acquisition may have taken arbitrarily long.
      final liveEvents = chatBridge.current(target)?.snapshot.agentEvents;
      _externalEventFloor = liveEvents == null
          ? _externalEventFloor
          : liveEvents.fold<int>(
              0,
              (max, event) => event.sequence > max ? event.sequence : max,
            );
      _externalProcessedSequence = _externalEventFloor;
      _chatEvents = chatBridge
          .observe(target)
          .listen(
            (observation) {
              if (_current(generation)) _onChat(observation, generation);
            },
            onDone: () {
              if (_current(generation) && _boundChat == target) {
                unawaited(stop());
              }
            },
          );
      _events = _session.events.listen(
        (event) {
          if (_current(generation)) _onEvent(event, generation);
        },
        onError: (_) {
          if (_current(generation)) {
            _closeForFailure('Spark voice connection failed.');
          }
        },
      );
      final context = sparkConversationContext(
        observation.snapshot.messages,
        observation.voiceTurns,
        characterBudget: contextBudget,
      );
      final instructions = composeSparkInstructions(
        _settings,
        recentConversation: context,
      );
      if (instructions.length + renderSparkFinalMessage(_settings, '').length >
          5300 * 4) {
        throw const SparkBrokerException(
          'Spark instructions exceed the shared startup budget.',
        );
      }
      final sessionCredential = credential.accessToken;
      await _session.start(
        accessToken: sessionCredential,
        accountId: credential.accountId,
        instructions: instructions,
        voice: _settings.voice,
      );
    } on SparkBrokerException catch (error) {
      if (_current(generation)) {
        await _cleanupFailedStart(generation);
        _fail(error.message);
      }
      rethrow;
    } on MissingPluginException {
      const error = SparkBrokerException(
        'Spark live voice is not supported on this platform.',
      );
      if (_current(generation)) {
        await _cleanupFailedStart(generation);
        _fail(error.message);
      }
      throw error;
    } catch (_) {
      if (_current(generation)) {
        await _cleanupFailedStart(generation);
        _fail('Spark could not start.');
      }
      rethrow;
    } finally {
      if (identical(_startCancellation, cancellation)) {
        _startCancellation = null;
      }
    }
  }

  int _startupContextBudget() {
    // The actual tokenizer is not exposed to mobile: a conservative character
    // envelope reserves the complete persona, addition, final wrapper and
    // context delimiters before allocating any chronological history.
    const totalCharacters = 5300 * 4;
    final fixed =
        composeSparkInstructions(_settings, recentConversation: 'x').length -
        1 +
        renderSparkFinalMessage(_settings, '').length;
    if (fixed > totalCharacters) {
      throw const SparkBrokerException(
        'Spark instructions exceed the shared startup budget.',
      );
    }
    return totalCharacters - fixed;
  }

  void _clearChatHooks() {
    _unsentIntents.clear();
    final chat = _boundChat;
    _boundChat = null;
    if (chat == null) return;
    try {
      chatBridge.setPromptPreparer(chat, null);
    } catch (_) {}
    try {
      chatBridge.setPromptDeliveryObserver(chat, null);
    } catch (_) {}
    try {
      chatBridge.activateDirective(chat, '');
    } catch (_) {}
  }

  Future<void> _cleanupFailedStart(int generation) async {
    if (!_current(generation)) return;
    ++_generation;
    final chat = _boundChat;
    _clearChatHooks();
    try {
      await _events?.cancel();
    } catch (_) {}
    _events = null;
    try {
      await _chatEvents?.cancel();
    } catch (_) {}
    _chatEvents = null;
    try {
      await _session.stop();
    } catch (_) {}
    if (chat != null) {
      try {
        await _flushFinalsForChat(chat);
      } catch (_) {
        _setNonfatalError('Could not save Spark conversation locally.');
      }
    }
  }

  Future<void> stop() async {
    final generation = ++_generation;
    _startCancellation?.cancel();
    _startCancellation = null;
    final chat = _boundChat;
    _clearChatHooks();
    // Release the native voice connection before waiting for encrypted writes.
    Future<void> voiceStop;
    try {
      voiceStop = _session.stop();
    } catch (_) {
      voiceStop = Future<void>.value();
    }
    try {
      await _events?.cancel();
    } catch (_) {}
    _events = null;
    try {
      await _chatEvents?.cancel();
    } catch (_) {}
    _chatEvents = null;
    try {
      await voiceStop;
    } catch (_) {
      /* Never abort remote work. */
    }
    String? saveError;
    if (chat != null) {
      try {
        await _flushFinalsForChat(chat);
      } catch (_) {
        saveError = 'Could not save Spark conversation locally.';
      }
    }
    if (_current(generation)) {
      _snapshot = _snapshot.copyWith(
        phase: SparkPhase.idle,
        micEnabled: false,
        inputLevel: 0,
        outputLevel: 0,
        error: saveError,
        clearError: saveError == null,
        clearBoundChatId: true,
        clearIntegrationStatus: true,
      );
      _notify();
    }
  }

  Future<void> setMicEnabled(bool enabled) async {
    if (_snapshot.phase == SparkPhase.idle ||
        _snapshot.phase == SparkPhase.connecting ||
        _snapshot.phase == SparkPhase.error) {
      throw StateError('Spark is not ready.');
    }
    final generation = _generation;
    try {
      await _session.setMuted(!enabled);
      if (!_current(generation)) return;
      _snapshot = _snapshot.copyWith(
        micEnabled: enabled,
        phase: enabled ? SparkPhase.listening : SparkPhase.muted,
        clearError: true,
      );
      _notify();
    } catch (_) {
      const error = SparkBrokerException(
        'The Spark microphone setting could not be changed.',
      );
      if (_current(generation)) _closeForFailure(error.message);
      throw error;
    }
  }

  Future<void> sendText(String text) async {
    final value = text.trim();
    if (value.isEmpty) return;
    if (value.length > 12000) {
      throw ArgumentError('Spark messages are limited to 12000 characters.');
    }
    if (_snapshot.phase == SparkPhase.idle ||
        _snapshot.phase == SparkPhase.connecting ||
        _snapshot.phase == SparkPhase.error) {
      throw StateError('Spark is not ready for text.');
    }
    final generation = _generation;
    try {
      await _session.sendText(value);
      if (!_current(generation)) return;
      final typedId = 'typed-local-$generation-${++_request}';
      _typedTurnIds.add(typedId);
      final transcript = _transcripts.appendFinal(
        _snapshot.transcript,
        id: typedId,
        role: SparkTranscriptRole.user,
        text: value,
      );
      _snapshot = _snapshot.copyWith(
        transcript: transcript,
        phase: _snapshot.micEnabled ? SparkPhase.working : SparkPhase.muted,
        clearError: true,
      );
      _persistFinals(transcript, generation);
      _notify();
    } catch (_) {
      const error = SparkBrokerException(
        'The message was not accepted by Spark.',
      );
      if (_current(generation)) _setNonfatalError(error.message);
      throw error;
    }
  }

  Future<String> _prepareTypedPrompt(String chat, String text) async {
    final observation = chatBridge.current(chat);
    if (observation == null) return text;
    final package = sparkRoutingPackage(observation.voiceTurns, text);
    final pending = package.turns;
    if (pending.isEmpty) return text;
    final dialogue = pending
        .map((turn) => '${sparkRoutingLabel(turn)}: ${turn.text}')
        .join('\n');
    final prepared = '$dialogue\n$text';
    final exposure = _TypedExposure(
      prepared,
      pending.map((turn) => turn.id).toList(),
      observation.snapshot.rawEntries
          .map((entry) => entry['id'])
          .whereType<String>()
          .toSet(),
      observation.snapshot.agentEvents.fold(
        0,
        (int max, event) => event.sequence > max ? event.sequence : max,
      ),
    );
    // Composer must not write a prompt until its bundled voice turns survive
    // restart as uncertain; only a consumed matching echo marks delivered.
    try {
      for (final turn in pending) {
        await chatBridge.saveTurn(
          chat,
          turn.copyWith(delivery: VoiceDelivery.uncertain),
        );
      }
    } catch (_) {
      // No socket attempt has occurred, including when an upsert succeeded
      // in memory but its durable flush failed.
      await _restoreKnownNotSent(chat, pending);
      rethrow;
    }
    if (_boundChat != chat) {
      await _restoreKnownNotSent(chat, pending);
      return text;
    }
    _typedExposures.add(exposure);
    return prepared;
  }

  void _onTypedSend(
    String chat,
    String actualText,
    bool localSent,
    int generation,
  ) {
    final matches = _typedExposures
        .where((item) => VoiceDirective.strip(actualText) == item.prepared)
        .toList();
    if (matches.length != 1 || localSent) return;
    // The pre-send barrier already persisted uncertain. A failed socket write
    // cannot establish whether the host consumed anything.
    _uncertainChats.add(chat);
    _setNonfatalError(
      'Typed prompt delivery is uncertain; voice dialogue will not be retried.',
    );
  }

  void _onEvent(Map<String, Object?> event, int generation) {
    switch (event['type']) {
      case 'connected':
        _snapshot = _snapshot.copyWith(
          phase: SparkPhase.listening,
          micEnabled: true,
          clearError: true,
        );
      case 'closed':
        unawaited(stop());
        return;
      case 'error':
        _closeForFailure('Spark voice connection failed.');
        return;
      case 'transcript':
        final transcript = _transcripts.reduce(_snapshot.transcript, event);
        final phase = event['role'] == 'assistant'
            ? (event['final'] == true
                  ? SparkPhase.listening
                  : SparkPhase.speaking)
            : (event['final'] == true ? SparkPhase.working : _snapshot.phase);
        _snapshot = _snapshot.copyWith(
          transcript: transcript,
          phase: _snapshot.micEnabled ? phase : SparkPhase.muted,
        );
        if (event['role'] == 'assistant' && event['final'] == false) {
          for (final item in transcript.where(
            (entry) =>
                entry.role == SparkTranscriptRole.assistant && !entry.isFinal,
          )) {
            _assistantTurnPurposes.putIfAbsent(item.id, _assistantPurpose);
          }
        }
        _persistFinals(transcript, generation);
        if (event['role'] == 'user' && event['final'] == true) {
          _afterDelegation = false;
          _afterMainResult = false;
        }
        _drainIntents();
      case 'delegation':
        final id = event['id'];
        if (id is String && id.isNotEmpty && _delegationIds.add(id)) {
          // A new request closes the earlier unresolved association even
          // when its uncertain send prevents this one from draining.
          _scheduleSourceClosure(generation);
          final chat = _boundChat;
          if (chat != null) {
            _unsentIntents.add(
              _PendingIntent(
                id,
                event['text'] is String ? event['text'] as String : '',
                generation,
                chat,
                waitForUserFinal: _transcripts.hasActiveUserTurn,
              ),
            );
            _drainIntents();
          }
        }
      case 'levels':
        _snapshot = _snapshot.copyWith(
          inputLevel: _level(event['input']),
          outputLevel: _level(event['output']),
          levelRevision: _snapshot.levelRevision + 1,
        );
    }
    _notify();
  }

  void _scheduleSourceClosure(int generation) {
    final chat = _boundChat;
    if (chat == null) return;
    final unresolved =
        chatBridge
            .current(chat)
            ?.voiceTurns
            .where(
              (turn) =>
                  turn.routingAwaitingSource &&
                  !_claimedLateSources.contains(turn.id),
            )
            .toList() ??
        <VoiceTurn>[];
    if (unresolved.isEmpty) return;
    for (final turn in unresolved) {
      _claimedLateSources.add(turn.id);
    }
    late final Future<void> closure;
    closure = _closeAwaitingSource(generation)
        .catchError((Object _) {
          _sourceBoundaryFailures.add(chat);
        })
        .whenComplete(() => _pendingWrites.remove(closure));
    _pendingWrites[closure] = chat;
  }

  VoiceTurnPurpose _assistantPurpose() => _afterMainResult
      ? VoiceTurnPurpose.resultFeedback
      : _afterDelegation
      ? VoiceTurnPurpose.acknowledgement
      : VoiceTurnPurpose.dialogue;

  Future<void> _closeAwaitingSource(int generation) async {
    final chat = _boundChat;
    if (chat == null) return;
    final turns = chatBridge.current(chat)?.voiceTurns ?? const <VoiceTurn>[];
    for (final turn in turns.where((turn) => turn.routingAwaitingSource)) {
      _claimedLateSources.add(turn.id); // Fence before asynchronous storage.
      try {
        await chatBridge.saveTurn(
          chat,
          turn.copyWith(routingAwaitingSource: false),
        );
        _claimedLateSources.remove(turn.id);
      } catch (_) {
        if (_current(generation)) {
          _setNonfatalError('Could not save voice source boundary.');
        }
        rethrow;
      }
    }
  }

  void _persistFinals(List<SparkTranscriptEntry> entries, int generation) {
    final chat = _boundChat;
    if (chat == null) return;
    for (final entry in entries) {
      if (!entry.isFinal || entry.text.isEmpty) continue;
      final key = '$generation:${entry.role.name}:${entry.id}';
      if (_finalTurns.containsKey(key)) continue;
      final observation = chatBridge.current(chat);
      final raw =
          observation?.snapshot.rawEntries ?? const <Map<String, Object?>>[];
      final anchor = raw.isEmpty ? null : raw.last['id'];
      final durableIds = raw
          .map((entry) => entry['id'])
          .whereType<String>()
          .toSet();
      final renderable =
          observation?.snapshot.messages
              .where((message) => durableIds.contains(message.id))
              .toList() ??
          const <ChatMessage>[];
      final predecessor = renderable.isEmpty ? null : renderable.last.id;
      final turn = VoiceTurn(
        id: 'voice:$chat:${_voiceSequence + 1}',
        sequence: ++_voiceSequence,
        origin: entry.role == SparkTranscriptRole.assistant
            ? VoiceTurnOrigin.spark
            : _typedTurnIds.contains(entry.id)
            ? VoiceTurnOrigin.typedUser
            : VoiceTurnOrigin.user,
        createdAt: DateTime.now().toUtc(),
        text: entry.text,
        precedingHostEntryId: anchor is String ? anchor : null,
        precedingRenderedEntryId: predecessor,
        routingPurpose: entry.role == SparkTranscriptRole.assistant
            ? _assistantTurnPurposes.remove(entry.id) ?? _assistantPurpose()
            : VoiceTurnPurpose.dialogue,
      );
      if (entry.role == SparkTranscriptRole.user &&
          !_typedTurnIds.contains(entry.id)) {
        final unresolved =
            observation?.voiceTurns
                .where(
                  (item) =>
                      item.routingAwaitingSource &&
                      !_claimedLateSources.contains(item.id),
                )
                .toList() ??
            <VoiceTurn>[];
        if (unresolved.isNotEmpty) {
          final reservation = unresolved.last;
          _claimedLateSources.add(reservation.id);
          final matches = entry.text.trim() == reservation.routingRequestText;
          final associated = matches
              ? turn.copyWith(
                  delivery: reservation.delivery,
                  hostEntryId: reservation.hostEntryId,
                  echoRemainder: reservation.echoRemainder,
                  routingRequestId: reservation.routingRequestId,
                )
              : turn.copyWith(routingPurpose: VoiceTurnPurpose.lateContext);
          _finalTurns[key] = associated;
          _unsavedFinals[associated.id] = associated;
          _turnChats[associated.id] = chat;
          late final Future<void> lateWrite;
          lateWrite =
              () async {
                    await chatBridge.saveTurn(chat, associated);
                    await chatBridge.saveTurn(
                      chat,
                      reservation.copyWith(
                        text: matches ? '' : reservation.text,
                        routingSourceTurnId: matches ? associated.id : null,
                        routingAwaitingSource: false,
                      ),
                    );
                  }()
                  .then(
                    (_) {
                      _unsavedFinals.remove(associated.id);
                      _claimedLateSources.remove(reservation.id);
                      if (_current(generation)) _drainIntents();
                    },
                    onError: (Object _) {
                      if (_current(generation)) {
                        _setNonfatalError('Could not save late voice source.');
                      }
                    },
                  )
                  .whenComplete(() => _pendingWrites.remove(lateWrite));
          _pendingWrites[lateWrite] = chat;
          continue;
        }
      }
      _finalTurns[key] = turn;
      _unsavedFinals[turn.id] = turn;
      _turnChats[turn.id] = chat;
      late final Future<void> write;
      write = chatBridge
          .saveTurn(chat, turn)
          .then(
            (_) {
              _unsavedFinals.remove(turn.id);
              if (_current(generation) && _boundChat == chat) {
                _drainIntents();
              }
            },
            onError: (Object _) {
              if (_current(generation)) {
                _setNonfatalError('Could not save Spark conversation locally.');
              }
            },
          )
          .whenComplete(() => _pendingWrites.remove(write));
      _pendingWrites[write] = chat;
    }
  }

  Future<void> _restoreKnownNotSent(String chat, List<VoiceTurn> turns) async {
    for (final turn in turns) {
      try {
        await chatBridge.saveTurn(
          chat,
          turn.copyWith(delivery: VoiceDelivery.pending),
        );
      } catch (_) {
        if (!_disposed) {
          _setNonfatalError(
            'Could not restore dialogue after a known unsent prompt.',
          );
        }
      }
    }
  }

  Future<void> _removeUnsentReservation(String chat, VoiceTurn turn) async {
    try {
      await chatBridge.saveTurn(
        chat,
        turn.copyWith(
          text: '',
          delivery: VoiceDelivery.delivered,
          routingAwaitingSource: false,
        ),
      );
    } catch (_) {
      _setNonfatalError('Could not clear an unsent request reservation.');
    }
  }

  void _drainIntents() {
    if (_drainingIntentGeneration != null ||
        _activeRequest != null ||
        _unsentIntents.isEmpty) {
      return;
    }
    final intent = _unsentIntents.first;
    if (!_current(intent.generation) || _boundChat != intent.chatId) {
      _unsentIntents.clear();
      return;
    }
    if (intent.waitForUserFinal && _transcripts.hasActiveUserTurn) return;
    final observation = chatBridge.current(intent.chatId);
    if (observation == null ||
        _uncertainChats.contains(intent.chatId) ||
        observation.voiceTurns.any(
          (turn) => turn.delivery == VoiceDelivery.uncertain,
        )) {
      return;
    }
    _drainingIntentGeneration = intent.generation;
    unawaited(() async {
      try {
        await _delegate(intent.id, intent.text, intent.generation);
      } catch (_) {
        if (_current(intent.generation)) {
          _setNonfatalError('Spark could not prepare the bound chat request.');
        }
      } finally {
        if (_drainingIntentGeneration == intent.generation) {
          _drainingIntentGeneration = null;
        }
        if (_current(intent.generation) &&
            _boundChat == intent.chatId &&
            !_unsentIntents.contains(intent) &&
            _activeRequest == null) {
          _drainIntents();
        }
      }
    }());
  }

  Future<void> _flushFinalsForChat(String chat) async {
    await Future.wait(
      _pendingWrites.entries
          .where((entry) => entry.value == chat)
          .map((entry) => entry.key)
          .toList(),
    );
    for (final stale
        in _unsavedFinals.values
            .where((turn) => _turnChats[turn.id] == chat)
            .toList()) {
      final current = chatBridge.current(chat)?.voiceTurns;
      VoiceTurn? latest;
      for (final turn in current ?? const <VoiceTurn>[]) {
        if (turn.id == stale.id) {
          latest = turn;
          break;
        }
      }
      if (latest != null && latest.delivery != VoiceDelivery.pending) {
        _unsavedFinals.remove(stale.id);
        continue;
      }
      await chatBridge.saveTurn(chat, latest ?? stale);
      _unsavedFinals.remove(stale.id);
    }
    await chatBridge.flush(chat);
  }

  Future<void> _delegate(String id, String request, int generation) async {
    final chat = _boundChat;
    if (chat == null) return;
    // A write that failed to become durable must block transmission.
    try {
      await _flushFinalsForChat(chat);
      await _closeAwaitingSource(generation);
      await chatBridge.flush(chat);
    } catch (_) {
      if (_current(generation)) {
        _setNonfatalError('Could not save Spark conversation locally.');
      }
      return;
    }
    if (_sourceBoundaryFailures.contains(chat)) {
      _setNonfatalError('Could not save voice source boundary.');
      return;
    }
    if (!_current(generation)) return;
    final observation = chatBridge.current(chat);
    if (observation == null) return;
    if (_uncertainChats.contains(chat) ||
        observation.voiceTurns.any(
          (turn) => turn.delivery == VoiceDelivery.uncertain,
        )) {
      _setNonfatalError(
        'Earlier host delivery is uncertain. No automatic retry.',
      );
      return;
    }
    if (_activeRequest != null) {
      _setNonfatalError(
        'A previous Spark delegation is awaiting host confirmation.',
      );
      return;
    }
    final package = sparkRoutingPackage(observation.voiceTurns, request);
    final body = package.body;
    if (body.isEmpty) {
      _unsentIntents.removeWhere((pending) => pending.id == id);
      return;
    }
    final raw = observation.snapshot.rawEntries;
    final anchor = raw.isEmpty ? null : raw.last['id'];
    final source = package.overlapTurnId;
    final meaningful = request.trim();
    // The durable synthetic reservation represents a user-derived request,
    // not an observed human utterance or a second Spark transcript turn.
    final reservation = VoiceTurn(
      id: 'routing:$chat:${_voiceSequence + 1}',
      sequence: ++_voiceSequence,
      origin: VoiceTurnOrigin.typedUser,
      text: source == null ? meaningful : '',
      createdAt: DateTime.now().toUtc(),
      delivery: VoiceDelivery.uncertain,
      precedingHostEntryId: anchor is String ? anchor : null,
      routingPurpose: VoiceTurnPurpose.request,
      routingRequestId: id,
      routingRequestText: meaningful,
      routingPackageText: body,
      routingSourceTurnId: source,
      routingAwaitingSource: source == null && meaningful.isNotEmpty,
    );
    final handoff = _Delegation(
      id: id,
      body: body,
      reservationId: reservation.id,
      eventFloor: observation.snapshot.agentEvents.fold(
        0,
        (int max, event) => event.sequence > max ? event.sequence : max,
      ),
      entryIds: raw.map((entry) => entry['id']).whereType<String>().toSet(),
      turnIds: package.turns.map((turn) => turn.id).toList(),
    );
    _delegations[id] = handoff;
    _activeRequest = id;
    _snapshot = _snapshot.copyWith(
      integrationStatus: 'Sending to the bound chat…',
    );
    _notify();
    // Durably quarantine the entire batch BEFORE any network write. A socket
    // completion is not an ACK and may outlive this voice process.
    final included = package.turns;
    try {
      for (final turn in included) {
        await chatBridge.saveTurn(
          chat,
          turn.copyWith(delivery: VoiceDelivery.uncertain),
        );
      }
      await chatBridge.saveTurn(chat, reservation);
    } catch (_) {
      _activeRequest = null;
      await _restoreKnownNotSent(chat, included);
      await _removeUnsentReservation(chat, reservation);
      if (_current(generation)) {
        _setNonfatalError('Could not save delegation status before sending.');
      }
      return;
    }
    if (!_current(generation) || _boundChat != chat) {
      await _restoreKnownNotSent(chat, included);
      await _removeUnsentReservation(chat, reservation);
      return;
    }
    _unsentIntents.removeWhere((pending) => pending.id == id);
    _afterDelegation = true;
    SparkChatSendResult result;
    try {
      result = await chatBridge.sendOnce(chat, body, requestId: 'spark:$id');
    } catch (_) {
      _uncertainChats.add(chat);
      _activeRequest = null;
      if (_current(generation)) {
        _setNonfatalError('Delegation delivery could not be confirmed.');
      }
      return;
    }
    if (!_current(generation)) return;
    handoff.sentText = result.sentText;
    _snapshot = _snapshot.copyWith(
      integrationStatus: result.outcome == SparkSendOutcome.rejected
          ? 'The bound chat rejected the request; dialogue remains pending.'
          : 'Awaiting matching host prompt consumption…',
    );
    if (result.outcome == SparkSendOutcome.rejected) {
      _activeRequest = null;
      await _restoreKnownNotSent(chat, included);
      await _removeUnsentReservation(chat, reservation);
    } else if (result.sentText == null) {
      _uncertainChats.add(chat);
      _activeRequest = null;
    }
    _onChat(chatBridge.current(chat) ?? observation, generation);
    _notify();
  }

  void _onChat(SparkChatObservation observation, int generation) {
    final chat = _boundChat;
    if (chat == null) return;
    for (final handoff in _delegations.values) {
      final sent = handoff.sentText;
      if (sent == null) continue;
      for (final record in observation.snapshot.agentEvents) {
        if (record.sequence <= handoff.eventFloor ||
            record.sequence <= handoff.processedSequence) {
          continue;
        }
        handoff.processedSequence = record.sequence;
        final event = record.event;
        final type = record.type;
        final message = event['message'];
        if (type == 'agent_start' && handoff.consumed) {
          // Without a run ID, pause live commentary. A later exact terminal
          // payload may still prove the final belongs to this delegation.
          handoff.commentaryBlocked = true;
        }
        if ((type == 'message_start' || type == 'message_end') &&
            message is Map) {
          final isCollab =
              message['role'] == 'custom' &&
              message['customType'] == 'collab-prompt';
          if (isCollab && sparkSourceProse(message['content']) == sent) {
            if (!handoff.consumed) handoff.consumed = true;
          }
          if (type == 'message_end' &&
              handoff.consumed &&
              !handoff.finished &&
              !handoff.commentaryBlocked &&
              identical(
                _delegations.values
                    .where((item) => item.consumed && !item.finished)
                    .last,
                handoff,
              ) &&
              message['role'] == 'assistant' &&
              message['stopReason'] == 'toolUse') {
            handoff.toolUse = true;
            final prose = VoiceDirective.strip(
              sparkSourceProse(message['content']),
            );
            if (prose.isNotEmpty) handoff.commentary.add(prose);
            _emitCommentary(handoff, generation);
          }
        }
        if (type == 'agent_end' &&
            event['isTerminal'] != false &&
            !handoff.finished) {
          final runMessages =
              (event['messages'] is List ? event['messages'] as List : const [])
                  .whereType<Map>()
                  .toList();
          final matches = <int>[];
          for (var i = 0; i < runMessages.length; i++) {
            final input = runMessages[i];
            if (input['role'] == 'custom' &&
                input['customType'] == 'collab-prompt' &&
                sparkSourceProse(input['content']) == sent) {
              matches.add(i);
            }
          }
          if (matches.length != 1) continue;
          handoff.consumed = true;
          // A later terminal/host user input is not a typed steer.
          if (runMessages.lastIndexWhere((item) => item['role'] == 'user') >
              matches.single) {
            handoff.finished = true;
            handoff.terminalSequence = record.sequence;
            continue;
          }
          // A typed steer in this run is valid. A later matched delegation,
          // however, owns the eventual speech for this terminal run.
          final matching = _delegations.values
              .where(
                (candidate) =>
                    !candidate.finished &&
                    candidate.sentText != null &&
                    runMessages.any(
                      (input) =>
                          input['role'] == 'custom' &&
                          input['customType'] == 'collab-prompt' &&
                          sparkSourceProse(input['content']) ==
                              candidate.sentText,
                    ),
              )
              .toList();
          if (matching
                  .where((candidate) => candidate.sentText == sent)
                  .length !=
              1) {
            for (final candidate in matching.where(
              (candidate) => candidate.sentText == sent,
            )) {
              candidate.ambiguous = true;
              candidate.finished = true;
              candidate.terminalSequence = record.sequence;
            }
            continue;
          }
          if (matching.isEmpty || !identical(matching.last, handoff)) {
            handoff.finished = true;
            handoff.terminalSequence = record.sequence;
            continue;
          }
          for (final earlier in _delegations.values) {
            if (identical(earlier, handoff)) break;
            if (earlier.consumed) {
              earlier.finished = true;
              earlier.terminalSequence = record.sequence;
            }
          }
          handoff.finished = true;
          handoff.terminalSequence = record.sequence;
          // An observed terminal completion closes the no-partial fallback.
          // The host cannot prove a later same-text utterance was that source.
          _scheduleSourceClosure(generation);
          handoff.finalText = _terminalFinal(runMessages, matches.single);
          _speakIfReady(handoff, generation);
        }
      }
      if (handoff.consumed && !handoff.echoSaved && !handoff.persistingEcho) {
        final echo = _matchingEcho(
          observation.snapshot.rawEntries,
          sent,
          handoff.entryIds,
        );
        if (echo != null) {
          handoff.persistingEcho = true;
          unawaited(
            _markDelivered(chat, observation, handoff, echo, generation),
          );
        }
      }
    }
    for (final typed in _typedExposures.toList()) {
      final consumed = observation.snapshot.agentEvents.any((record) {
        if (record.sequence <= typed.eventFloor) return false;
        if (record.type == 'message_start' || record.type == 'message_end') {
          final message = record.event['message'];
          return message is Map &&
              message['role'] == 'custom' &&
              message['customType'] == 'collab-prompt' &&
              VoiceDirective.strip(sparkSourceProse(message['content'])) ==
                  typed.prepared;
        }
        if (record.type != 'agent_end') return false;
        final runMessages = record.event['messages'];
        return runMessages is List &&
            runMessages
                    .whereType<Map>()
                    .where(
                      (message) =>
                          message['role'] == 'custom' &&
                          message['customType'] == 'collab-prompt' &&
                          VoiceDirective.strip(
                                sparkSourceProse(message['content']),
                              ) ==
                              typed.prepared,
                    )
                    .length ==
                1;
      });
      final echoes = observation.snapshot.rawEntries
          .where(
            (entry) =>
                entry['type'] == 'custom_message' &&
                entry['customType'] == 'collab-prompt' &&
                entry['id'] is String &&
                !typed.priorIds.contains(entry['id']) &&
                VoiceDirective.strip(sparkSourceProse(entry['content'])) ==
                    typed.prepared,
          )
          .toList();
      if (consumed && echoes.length == 1 && !typed.persisting) {
        typed.persisting = true;
        unawaited(
          _markTypedDelivered(
            chat,
            observation,
            typed,
            echoes.single['id'] as String,
            generation,
          ),
        );
      }
    }
    _observeExternalTerminals(observation, generation);
  }

  void _observeExternalTerminals(
    SparkChatObservation observation,
    int generation,
  ) {
    for (final record in observation.snapshot.agentEvents) {
      if (record.sequence <= _externalEventFloor ||
          record.sequence <= _externalProcessedSequence) {
        continue;
      }
      _externalProcessedSequence = record.sequence;
      if (record.type == 'agent_start') {
        _externalRunEpoch++;
        continue;
      }
      if (record.type != 'agent_end' || record.event['isTerminal'] == false) {
        continue;
      }
      final fingerprint =
          '$_externalRunEpoch:${jsonEncode(record.event['messages'])}';
      if (!_terminalFingerprints.add(fingerprint)) continue;
      _terminalFingerprintOrder.add(fingerprint);
      if (_terminalFingerprintOrder.length > 64) {
        _terminalFingerprints.remove(_terminalFingerprintOrder.removeAt(0));
      }
      if (!_settings.announceTerminalReplies) continue;
      final messages =
          (record.event['messages'] is List
                  ? record.event['messages'] as List
                  : const [])
              .whereType<Map>()
              .toList();
      final latestInput = messages.lastIndexWhere(
        (message) =>
            message['role'] == 'user' ||
            (message['role'] == 'custom' &&
                message['customType'] == 'collab-prompt'),
      );
      if (latestInput < 0) continue; // No positive external input provenance.
      final input = messages[latestInput];
      final customSource =
          input['role'] == 'custom' && input['customType'] == 'collab-prompt'
          ? sparkSourceProse(input['content'])
          : null;
      final packageText = customSource == null
          ? null
          : VoiceDirective.strip(customSource);
      // A socket failure can leave sentText unknown, and restart loses the
      // in-memory handoff. The encrypted uncertain reservation still fences
      // this exact package without claiming an unrelated later user input.
      if (packageText != null &&
          observation.voiceTurns.any(
            (turn) =>
                turn.routingPurpose == VoiceTurnPurpose.request &&
                turn.delivery == VoiceDelivery.uncertain &&
                turn.routingPackageText == packageText,
          )) {
        continue;
      }
      final ownEchoIds = observation.voiceTurns
          .where(
            (turn) =>
                turn.routingPurpose == VoiceTurnPurpose.request &&
                turn.delivery == VoiceDelivery.delivered &&
                turn.routingPackageText == packageText &&
                turn.hostEntryId != null,
          )
          .map((turn) => turn.hostEntryId)
          .toSet();
      if (customSource != null && ownEchoIds.isNotEmpty) {
        final freshEcho = observation.snapshot.rawEntries.any(
          (entry) =>
              entry['type'] == 'custom_message' &&
              entry['customType'] == 'collab-prompt' &&
              entry['id'] is String &&
              !ownEchoIds.contains(entry['id']) &&
              sparkSourceProse(entry['content']) == customSource,
        );
        final completed = _delegations.values
            .where(
              (item) =>
                  item.finished &&
                  item.echoSaved &&
                  item.sentText == customSource,
            )
            .toList();
        final floor = completed.isEmpty
            ? _externalEventFloor
            : completed
                  .map((item) => item.terminalSequence)
                  .reduce((a, b) => a > b ? a : b);
        final nextRun = observation.snapshot.agentEvents.any(
          (event) =>
              event.type == 'agent_start' &&
              event.sequence > floor &&
              event.sequence < record.sequence,
        );
        if (!freshEcho || !nextRun) continue;
      }
      final hasOurEarlierPrompt = messages
          .take(latestInput)
          .any(
            (message) => _delegations.values.any(
              (handoff) =>
                  handoff.sentText != null &&
                  message['role'] == 'custom' &&
                  message['customType'] == 'collab-prompt' &&
                  sparkSourceProse(message['content']) == handoff.sentText &&
                  (!handoff.finished ||
                      !handoff.echoSaved ||
                      handoff.terminalSequence == record.sequence),
            ),
          );
      // A later ordinary user prompt is external; an unidentifiable custom
      // steer following our request remains with the delegated run.
      if ((hasOurEarlierPrompt && input['role'] != 'user') ||
          _delegations.values.any(
            (handoff) =>
                handoff.sentText != null &&
                (!handoff.finished ||
                    !handoff.echoSaved ||
                    handoff.terminalSequence == record.sequence) &&
                customSource == handoff.sentText,
          )) {
        continue;
      }
      // Unknown-source terminal data must not bypass an unresolved local
      // delegation. A distinct custom prompt visible in raw host history is
      // positive evidence of external input even when work interleaves.
      if (_activeRequest != null ||
          _delegations.values.any(
            (item) => !item.echoSaved && !item.finished,
          )) {
        // A later ordinary user input is positively separate from our custom
        // prompt. A custom input needs its own observed raw host entry.
        if (input['role'] != 'user' &&
            (customSource == null ||
                !observation.snapshot.rawEntries.any(
                  (entry) =>
                      entry['type'] == 'custom_message' &&
                      entry['customType'] == 'collab-prompt' &&
                      sparkSourceProse(entry['content']) == customSource &&
                      !_delegations.values.any(
                        (item) =>
                            item.sentText == customSource &&
                            (!item.finished || !item.echoSaved),
                      ),
                ))) {
          continue;
        }
      }
      final text = _terminalFinal(messages, latestInput);
      if (text == null) continue;
      _afterMainResult = true;
      unawaited(_speakExternalFinal(text, generation));
    }
  }

  Future<void> _speakExternalFinal(String text, int generation) async {
    if (!_current(generation)) return;
    try {
      await _session.sendText(text, channel: 'speakable');
    } catch (_) {
      if (_current(generation)) {
        _setNonfatalError(
          'The external agent reply could not be shared with Spark.',
        );
      }
    }
  }

  void _emitCommentary(_Delegation handoff, int generation) {
    if (!handoff.echoSaved) return;
    while (handoff.spokenCommentary < handoff.commentary.length) {
      final note = handoff.commentary[handoff.spokenCommentary++];
      unawaited(_speakCommentary(handoff.id, note, generation));
    }
  }

  void _speakIfReady(_Delegation handoff, int generation) {
    final text = handoff.finalText;
    if (text == null || !handoff.echoSaved || handoff.spoken) return;
    handoff.spoken = true;
    _afterMainResult = true;
    _emitCommentary(handoff, generation);
    unawaited(_speakFinal(handoff.id, text, generation));
  }

  Future<void> _speakCommentary(
    String delegationId,
    String text,
    int generation,
  ) async {
    if (!_current(generation)) return;
    try {
      await _session.sendText(
        text,
        delegationId: delegationId,
        channel: 'commentary',
      );
    } catch (_) {
      if (_current(generation)) {
        _setNonfatalError('Agent commentary could not be shared with Spark.');
      }
    }
  }

  String? _matchingEcho(
    List<Map<String, Object?>> entries,
    String text,
    Set<String> priorIds,
  ) {
    final matches = entries
        .where(
          (entry) =>
              entry['type'] == 'custom_message' &&
              entry['customType'] == 'collab-prompt' &&
              entry['id'] is String &&
              !priorIds.contains(entry['id']) &&
              sparkSourceProse(entry['content']) == text,
        )
        .toList();
    return matches.length == 1 ? matches.single['id'] as String : null;
  }

  Future<void> _markDelivered(
    String chat,
    SparkChatObservation observation,
    _Delegation handoff,
    String echo,
    int generation,
  ) async {
    try {
      final included =
          (chatBridge.current(chat)?.voiceTurns ?? observation.voiceTurns)
              .where(
                (turn) =>
                    handoff.turnIds.contains(turn.id) ||
                    turn.id == handoff.reservationId ||
                    (turn.routingRequestId == handoff.id &&
                        turn.routingPurpose != VoiceTurnPurpose.request),
              )
              .toList();
      // Only the durable package can explain a request echo after late aliasing.
      final remainder =
          VoiceDirective.strip(handoff.sentText ?? '') == handoff.body
          ? ''
          : null;
      for (final turn in included) {
        final latest =
            chatBridge
                .current(chat)
                ?.voiceTurns
                .where((candidate) => candidate.id == turn.id)
                .firstOrNull ??
            turn;
        await chatBridge.saveTurn(
          chat,
          latest.copyWith(
            delivery: VoiceDelivery.delivered,
            hostEntryId: echo,
            echoRemainder: remainder,
            routingAwaitingSource: handoff.finished
                ? false
                : latest.routingAwaitingSource,
          ),
        );
      }
      if (!_current(generation)) return;
      handoff.echoSaved = true;
      if (_activeRequest == handoff.id) _activeRequest = null;
      _snapshot = _snapshot.copyWith(
        integrationStatus: 'The bound agent is working…',
      );
      _emitCommentary(handoff, generation);
      _speakIfReady(handoff, generation);
      _notify();
      _drainIntents();
    } catch (_) {
      if (_current(generation)) {
        _setNonfatalError(
          'Host consumed the prompt, but delivery could not be saved.',
        );
      }
    } finally {
      handoff.persistingEcho = false;
    }
  }

  Future<void> _markTypedDelivered(
    String chat,
    SparkChatObservation observation,
    _TypedExposure typed,
    String echoId,
    int generation,
  ) async {
    try {
      final included = observation.voiceTurns
          .where((turn) => typed.turnIds.contains(turn.id))
          .toList();
      final remainder = sparkVoiceEchoRemainder(typed.prepared, included);
      for (final turn in included) {
        await chatBridge.saveTurn(
          chat,
          turn.copyWith(
            delivery: VoiceDelivery.delivered,
            hostEntryId: echoId,
            typedEcho: true,
            echoRemainder: remainder,
          ),
        );
      }
      if (_current(generation) && _boundChat == chat) {
        _typedExposures.remove(typed);
        _drainIntents();
      }
    } catch (_) {
      if (_current(generation)) {
        _setNonfatalError(
          'Host consumed the typed prompt, but delivery could not be saved.',
        );
      }
    } finally {
      typed.persisting = false;
    }
  }

  String? _terminalFinal(List<Map> messages, int matchingPromptIndex) {
    // Do not reach back across the matched input or past a later failure.
    for (var i = messages.length - 1; i > matchingPromptIndex; i--) {
      final item = messages[i];
      if (item['role'] != 'assistant') continue;
      if (item['stopReason'] != 'stop') return null;
      final text = VoiceDirective.strip(sparkSourceProse(item['content']));
      return text.isEmpty ? null : renderSparkFinalMessage(_settings, text);
    }
    return null;
  }

  Future<void> _speakFinal(
    String delegationId,
    String text,
    int generation,
  ) async {
    if (!_current(generation)) return;
    try {
      await _session.sendText(
        text,
        delegationId: delegationId,
        channel: 'speakable',
      );
    } catch (_) {
      if (_current(generation)) {
        _setNonfatalError('The agent reply could not be shared with Spark.');
      }
    }
  }

  void _closeForFailure(String message) {
    if (_disposed) return;
    ++_generation;
    _startCancellation?.cancel();
    _startCancellation = null;
    final subscription = _events;
    _events = null;
    final chatSubscription = _chatEvents;
    _chatEvents = null;
    final chat = _boundChat;
    _clearChatHooks();
    _snapshot = _snapshot.copyWith(
      phase: SparkPhase.error,
      micEnabled: false,
      inputLevel: 0,
      outputLevel: 0,
      error: message,
      clearBoundChatId: true,
    );
    _notify();
    unawaited(() async {
      try {
        await subscription?.cancel();
      } catch (_) {}
      try {
        await chatSubscription?.cancel();
      } catch (_) {}
      try {
        await _session.stop();
      } catch (_) {}
      if (chat != null) {
        try {
          await _flushFinalsForChat(chat);
        } catch (_) {
          // Keep the voice failure visible even if local recovery also fails.
        }
      }
    }());
  }

  double _level(Object? value) => value is num && value.isFinite
      ? value.toDouble().clamp(0.0, 1.0).toDouble()
      : 0;
  bool _current(int generation) => !_disposed && generation == _generation;
  void _validateSettings(SparkSettings value) {
    try {
      validateSparkSettings(value);
    } on FormatException {
      throw ArgumentError('Spark settings are incomplete.');
    }
  }

  void _setNonfatalError(String message) {
    _snapshot = _snapshot.copyWith(error: message);
    _notify();
  }

  void _fail(String message) {
    _snapshot = _snapshot.copyWith(
      phase: SparkPhase.error,
      micEnabled: false,
      error: message,
    );
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    _startCancellation?.cancel();
    _clearChatHooks();
    unawaited(_events?.cancel());
    unawaited(_chatEvents?.cancel());
    unawaited(_session.dispose());
    super.dispose();
  }
}

class _PendingIntent {
  const _PendingIntent(
    this.id,
    this.text,
    this.generation,
    this.chatId, {
    this.waitForUserFinal = false,
  });
  final String id;
  final String text;
  final int generation;
  final String chatId;
  final bool waitForUserFinal;
}

class _Delegation {
  _Delegation({
    required this.id,
    required this.body,
    required this.turnIds,
    required this.reservationId,
    required this.eventFloor,
    required this.entryIds,
  });
  final String id;
  final String body;
  final String reservationId;
  final List<String> turnIds;
  final int eventFloor;
  final Set<String> entryIds;
  int processedSequence = 0;
  String? sentText;
  bool consumed = false;
  bool ambiguous = false;
  bool echoSaved = false;
  bool persistingEcho = false;
  String? finalText;
  bool spoken = false;
  bool toolUse = false;
  bool commentaryBlocked = false;
  final List<String> commentary = [];
  int spokenCommentary = 0;
  bool finished = false;
  int terminalSequence = 0;
}

class _TypedExposure {
  _TypedExposure(this.prepared, this.turnIds, this.priorIds, this.eventFloor);
  final String prepared;
  final List<String> turnIds;
  final Set<String> priorIds;
  final int eventFloor;
  bool persisting = false;
}
