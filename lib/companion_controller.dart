import 'dart:async';

import 'package:flutter/foundation.dart';

import 'harness/collab_link.dart';
import 'harness/harness.dart';
import 'harness/ompd_connection.dart';
import 'storage/chat_store.dart';
import 'harness/voice_directive.dart';
import 'storage/voice_transcript.dart';

/// One locally saved remote chat.
class ChatThread {
  ChatThread._({
    required this.id,
    required String input,
    required this.client,
    required HarnessSnapshot snapshot,
    required String label,
    required DateTime createdAt,
    required bool localLabel,
    required String draft,
    required bool reconnect,
    required bool saved,
    required List<VoiceTurn> voiceTurns,
    this.relayUnverified = false,
  }) : _input = input,
       _snapshot = snapshot,
       _label = label,
       _localLabel = localLabel,
       _createdAt = createdAt,
       _draft = draft,
       _reconnect = reconnect,
       _saved = saved,
       _hostStartedAt = snapshot.sessionStartedAt,
       _acceptHostStart = !saved,
       _voiceTurns = List.of(voiceTurns);

  final String id;
  final String _input;
  final bool relayUnverified;
  final HarnessClient client;
  StreamSubscription<HarnessSnapshot>? _subscription;
  HarnessSnapshot _snapshot;
  final String _label;
  final bool _localLabel;
  DateTime? _hostStartedAt;
  bool _acceptHostStart;
  final DateTime _createdAt;
  String _draft;
  int _draftRevision = 0;
  bool _reconnect;
  bool _saved;
  final List<VoiceTurn> _voiceTurns;
  String? _voiceDirective;
  Future<String> Function(String text)? _promptPreparer;
  String? _lastDirectiveBoundary;
  bool _directiveSentSinceBoundary = false;
  void Function(String actualText, bool localSent)? _promptDeliveryObserver;
  bool _promptInFlight = false;
  bool _needsDirectiveRecheck = false;
  String? _promptTrackingError;
  bool _deleting = false;
  bool _connecting = false;
  bool _acceptChanges = true;
  int _generation = 0;

  HarnessSnapshot get snapshot => _snapshot;
  bool get isDaemon => OmpdConnection.isOmpd(_input);
  String get title {
    final label = _label.trim();
    if (_localLabel && !_genericSessionTitle(label)) return label;
    final remote = _snapshot.title.trim();
    if (!_genericSessionTitle(remote)) return remote;
    final date = createdAt.toLocal();
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${pad(date.year % 100)}-${pad(date.month)}-${pad(date.day)} '
        '${pad(date.hour)} (OMP chat)';
  }

  DateTime get createdAt => _hostStartedAt ?? _createdAt;
  String get draft => _draft;
  List<VoiceTurn> get voiceTurns => List.unmodifiable(_voiceTurns);
  String? get promptTrackingError => _promptTrackingError;
}

/// Cancels only one pending local join, never the remote worker.
final class ChatJoinCancellation {
  bool _cancelled = false;
  bool _claimed = false;
  void Function()? _onCancel;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel?.call();
  }
}

/// Session collection independent of widget navigation and protocol details.
class CompanionController extends ChangeNotifier {
  CompanionController({
    required HarnessClientFactory clientFactory,
    required ChatStore store,
    HarnessClient Function(String input)? connectionClientFactory,
    String Function(String)? joinInputResolver,
    Duration writeDebounce = const Duration(milliseconds: 400),
  }) : _clientFactory = clientFactory,
       _connectionClientFactory = connectionClientFactory,
       _joinInputResolver = joinInputResolver,
       _store = store,
       _writeDebounce = writeDebounce;

  final HarnessClientFactory _clientFactory;
  final HarnessClient Function(String input)? _connectionClientFactory;
  final String Function(String)? _joinInputResolver;
  final ChatStore _store;
  final Duration _writeDebounce;
  final List<ChatThread> _chats = [];
  int _nextId = 0;
  int _revision = 0;
  bool _dirty = false;
  bool _disposed = false;
  bool _storageReady = false;
  bool _isLoading = true;
  String? _storageError;
  Timer? _writeTimer;
  Future<void>? _initialization;
  Future<void>? _persisting;

  List<ChatThread> get chats => List.unmodifiable(_chats);
  bool get hasLiveConnection =>
      _chats.any((chat) => chat.snapshot.phase == ConnectionPhase.live);
  bool get isLoading => _isLoading;
  String? get storageError => _storageError;

  /// Last endpoint comes only from the encrypted saved connection, not config.
  OmpdEndpoint? get lastOmpdEndpoint {
    for (final thread in _chats.reversed) {
      if (!thread._saved || !OmpdConnection.isOmpd(thread._input)) continue;
      return OmpdConnection.parse(thread._input).endpoint;
    }
    return null;
  }

  HarnessClient _clientFor(String input) =>
      _connectionClientFactory?.call(input) ?? _clientFactory();

  ChatThread? chat(String id) {
    for (final thread in _chats) {
      if (thread.id == id && !thread._deleting) return thread;
    }
    return null;
  }

  /// Restores local state first. Reconnects are then started without delaying
  /// completion, so callers can show cached chats immediately.
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      final saved = await _store.load();
      if (_disposed) return;
      var needsCreationMigration = false;
      final seenIds = <String>{};
      for (final item in saved) {
        if (item.id.isEmpty || !seenIds.add(item.id)) {
          throw const ChatStoreException(
            ChatStoreFailure.corrupt,
            'Saved chats contain invalid identifiers.',
          );
        }
        final numericId = int.tryParse(item.id);
        if (numericId != null && numericId > _nextId) _nextId = numericId;
        var resolvedInput = item.link;
        var relayUnverified = false;
        if (isBareCollabCode(item.link)) {
          try {
            final endpoint = validateCollabRelay(item.snapshot.endpoint);
            resolvedInput = pinBareCollabLink(
              item.link,
              defaultRelay: endpoint,
            );
            if (parseCollabLink(resolvedInput).safeEndpoint != endpoint) {
              relayUnverified = true;
            } else {
              needsCreationMigration = true;
            }
          } on CollabLinkException {
            relayUnverified = true;
          }
        }
        final client = _clientFor(resolvedInput);
        final thread = ChatThread._(
          id: item.id,
          input: resolvedInput,
          relayUnverified: relayUnverified,
          client: client,
          createdAt:
              item.createdAt ??
              item.snapshot.sessionStartedAt ??
              DateTime.now(),
          // A legacy label differing from a real host title may be a local
          // override. If the host title is blank/generic, the label can instead
          // be an automatic stale copy left behind after a title clear.
          localLabel:
              item.localLabel ??
              (!_genericSessionTitle(item.snapshot.title) &&
                  !_genericSessionTitle(item.label) &&
                  item.label.trim() != item.snapshot.title.trim()),
          label: item.label,
          draft: item.draft,
          reconnect: item.reconnect,
          saved: true,
          voiceTurns: item.voiceTurns,
          snapshot: HarnessSnapshot(
            phase: relayUnverified
                ? ConnectionPhase.error
                : ConnectionPhase.disconnected,
            title: item.snapshot.title,
            sessionStartedAt: item.snapshot.sessionStartedAt,
            sessionId: OmpdConnection.isOmpd(resolvedInput)
                ? OmpdConnection.parse(resolvedInput).sessionId
                : null,
            endpoint: item.snapshot.endpoint,
            model: item.snapshot.model,
            messages: item.snapshot.messages,
            error: relayUnverified
                ? 'Saved code has no verified relay. Rejoin with a full QR link.'
                : null,
            rawEntries: item.snapshot.rawEntries,
            readOnly: item.snapshot.readOnly,
          ),
        );
        _attach(thread);
        if (item.createdAt == null || item.localLabel == null) {
          needsCreationMigration = true;
        }
        _chats.add(thread);
      }
      _storageReady = true;
      _storageError = null;
      if (needsCreationMigration) {
        _markDirty(debounce: false);
        unawaited(_persistNow().catchError((_) {}));
      }
    } catch (error) {
      _storageReady = false;
      for (final thread in _chats) {
        unawaited(thread._subscription?.cancel());
        unawaited(thread.client.dispose());
      }
      _chats.clear();
      _setStorageError(error);
    } finally {
      if (!_disposed) {
        _isLoading = false;
        _notify();
      }
    }
    if (!_storageReady || _disposed) return;
    for (final thread in List<ChatThread>.of(_chats)) {
      if (thread._reconnect && !thread.relayUnverified) {
        unawaited(_connect(thread).catchError((_) {}));
      }
    }
  }

  Future<ChatThread> join(
    String input, {
    ChatJoinCancellation? cancellation,
  }) async {
    if (cancellation != null) {
      if (cancellation._claimed) {
        throw const HarnessException(
          'This connection request is no longer active.',
        );
      }
      cancellation._claimed = true;
    }
    await initialize();
    if (cancellation?.isCancelled ?? false) {
      throw const HarnessException('Connection cancelled.');
    }
    if (_disposed) throw const HarnessException('App has closed.');
    if (!_storageReady) {
      throw const HarnessException(
        'Saved chats are unavailable. Resolve the storage error first.',
      );
    }
    final normalized = input.trim();
    if (normalized.isEmpty) {
      throw const HarnessException('Paste an OMP join link or token first.');
    }
    if (_chats.where((thread) => thread._saved).length >= 100) {
      throw const HarnessException(
        'Up to 100 chats can be saved on this device.',
      );
    }
    final resolved = _joinInputResolver?.call(normalized) ?? normalized;
    final client = _clientFor(resolved);
    final thread = ChatThread._(
      id: '${++_nextId}',
      input: resolved,
      client: client,
      snapshot: client.snapshot,
      createdAt: DateTime.now(),
      localLabel: false,
      label: '',
      draft: '',
      reconnect: true,
      saved: false,
      voiceTurns: const [],
    );
    _attach(thread);
    _chats.add(thread);
    if (cancellation != null) {
      cancellation._onCancel = () {
        if (!_chats.remove(thread)) return;
        thread._generation++;
        thread._acceptChanges = false;
        final wasSaved = thread._saved;
        thread._saved = false;
        // Dispose immediately: a late status response must not send attach.
        unawaited(thread._subscription?.cancel().catchError((_) {}));
        unawaited(thread.client.dispose().catchError((_) {}));
        if (wasSaved) {
          _markDirty(debounce: false);
          unawaited(_persistNow().catchError((_) {}));
        }
        _notify();
      };
    }
    _notify();
    try {
      if (cancellation?.isCancelled ?? false) {
        cancellation?._onCancel?.call();
        throw const HarnessException('Connection cancelled.');
      }
      await _connect(thread);
      if (_disposed || !_chats.contains(thread) || thread._deleting) {
        throw const HarnessException('Connection cancelled.');
      }
      thread._saved = true;
      _markDirty(debounce: false);
      await _persistNow();
      if (_disposed || !_chats.contains(thread) || thread._deleting) {
        throw const HarnessException('Connection cancelled.');
      }
      return thread;
    } catch (_) {
      thread._saved = false;
      if (_chats.remove(thread)) {
        thread._generation++;
        final cleanup = <Future<void>>[
          if (thread._subscription case final subscription?)
            subscription.cancel(),
          thread.client.dispose(),
        ];
        try {
          await Future.wait(cleanup);
        } catch (_) {
          // Preserve the connection failure while still awaiting all cleanup.
        }
        _notify();
      }
      rethrow;
    } finally {
      cancellation?._onCancel = null;
    }
  }

  Future<void> reconnect(String id) async {
    await initialize();
    final thread = _requireChat(id);
    if (thread.relayUnverified) {
      throw const HarnessException(
        'Saved code has no verified relay. Rejoin with a full QR link.',
      );
    }
    final previousIntent = thread._reconnect;
    final actionGeneration = ++thread._generation;
    thread._reconnect = true;
    _markDirty(debounce: false);
    try {
      await _persistNow();
    } catch (_) {
      thread._reconnect = previousIntent;
      _markDirty();
      rethrow;
    }
    if (!_isCurrent(thread, actionGeneration) || !thread._reconnect) return;
    await _connect(thread);
  }

  Future<void> _connect(ChatThread thread) async {
    final generation = ++thread._generation;
    thread._acceptChanges = true;
    thread._connecting = true;
    try {
      await thread.client.connect(thread._input);
      if (!_isCurrent(thread, generation)) return;
      if (thread._acceptHostStart) {
        thread._hostStartedAt ??= thread.client.snapshot.sessionStartedAt;
        thread._acceptHostStart = false;
      }
      // connect() completes after the initial snapshot is ready.
      // A live title (even blank) is authoritative; any other phase is not.
      final connected = thread.client.snapshot;
      thread._snapshot = connected.phase == ConnectionPhase.live
          ? connected
          : _snapshotWithMessages(
              connected,
              connected.messages,
              connected.rawEntries,
              pendingTitle: thread._snapshot.title,
            );
      if (thread._saved) _markDirty();
      _notify();
    } catch (_) {
      if (_isCurrent(thread, generation)) {
        final latest = _snapshotWithMessages(
          thread.client.snapshot,
          thread._snapshot.messages,
          thread._snapshot.rawEntries,
        );
        thread._snapshot = _failedSnapshot(thread, latest);
        if (thread._saved) _markDirty();
        _notify();
      }
      rethrow;
    } finally {
      if (_isCurrent(thread, generation)) thread._connecting = false;
    }
  }

  /// Installs a preparation hook for actual outgoing prompts only. The hook
  /// may include finalized local voice dialogue; activation never sends a run.
  void setPromptPreparer(
    String id,
    Future<String> Function(String text)? prepare,
  ) {
    _requireChat(id)._promptPreparer = prepare;
  }

  /// localSent reports only socket-write completion, not host consumption.
  void setPromptDeliveryObserver(
    String id,
    void Function(String actualText, bool localSent)? observer,
  ) {
    _requireChat(id)._promptDeliveryObserver = observer;
  }

  void clearPromptTrackingError(String id) {
    final thread = _requireChat(id);
    if (thread._promptTrackingError == null) return;
    thread._promptTrackingError = null;
    _notify();
  }

  void activateVoiceDirective(String id, String directive) {
    _requireChat(id)._voiceDirective = directive;
  }

  /// Returns the exact payload submitted to collab, for observed echo matching.
  /// Socket completion is not a host consumption acknowledgement.
  Future<String> sendPrompt(
    String id,
    String text, {
    bool fromComposer = true,
  }) async {
    final thread = _requireChat(id);
    if (thread._promptInFlight) {
      throw const PromptBusyException();
    }
    thread._promptInFlight = true;
    try {
      return await _sendPrepared(thread, text, fromComposer: fromComposer);
    } finally {
      thread._promptInFlight = false;
    }
  }

  Future<String> _sendPrepared(
    ChatThread thread,
    String text, {
    required bool fromComposer,
  }) async {
    final prompt = text.trim();
    if (prompt.isEmpty) return '';
    final draftRevision = thread._draftRevision;
    final prepared =
        (fromComposer
                ? await thread._promptPreparer?.call(prompt) ?? prompt
                : prompt)
            .trim();
    if (prepared.isEmpty) return '';
    if (chat(thread.id) != thread) {
      throw const HarnessException('Chat is no longer open.');
    }
    final directive = thread._voiceDirective;
    String? boundary;
    for (final entry in thread.snapshot.rawEntries) {
      if (entry['type'] == 'compaction' && entry['id'] is String) {
        boundary = entry['id'] as String;
      }
    }
    if (boundary != thread._lastDirectiveBoundary) {
      thread._lastDirectiveBoundary = boundary;
      thread._directiveSentSinceBoundary = false;
    }
    final addDirective =
        directive != null &&
        directive.trim().isNotEmpty &&
        !VoiceDirective.isPresent(thread.snapshot.rawEntries) &&
        !thread._directiveSentSinceBoundary &&
        !prepared.contains(VoiceDirective.start);
    final payload = addDirective
        ? VoiceDirective.decorate(prepared, directive)
        : prepared;
    try {
      await thread.client.sendPrompt(payload);
    } catch (_) {
      if (fromComposer) _notifyPromptDelivery(thread, payload, false);
      rethrow;
    }
    if (addDirective) thread._directiveSentSinceBoundary = true;
    if (fromComposer) _notifyPromptDelivery(thread, payload, true);
    if (fromComposer &&
        chat(thread.id) == thread &&
        thread._draftRevision == draftRevision) {
      updateDraft(thread.id, '');
    }
    return payload;
  }

  void _notifyPromptDelivery(
    ChatThread thread,
    String payload,
    bool localSent,
  ) {
    try {
      thread._promptDeliveryObserver?.call(payload, localSent);
    } catch (_) {
      // An observer failure cannot turn an already transmitted prompt into a
      // safely retryable send. Surface the local tracking failure separately.
      thread._promptTrackingError =
          'Local prompt tracking failed. Inspect the host history before retrying.';
      _notify();
    }
  }

  Future<void> abort(String id) => _requireChat(id).client.abort();
  Future<void> respond(String id, int requestId, String? value) =>
      _requireChat(id).client.respond(requestId, value);

  Future<void> disconnect(String id) async {
    await initialize();
    final thread = _requireChat(id);
    final previousIntent = thread._reconnect;
    thread._reconnect = false;
    final actionGeneration = ++thread._generation;
    thread._connecting = false;
    thread._acceptChanges = false;
    _markDirty(debounce: false);
    try {
      await _persistNow();
    } catch (_) {
      thread._reconnect = previousIntent;
      thread._acceptChanges = true;
      _markDirty();
      rethrow;
    }
    if (!_isCurrent(thread, actionGeneration) || thread._reconnect) return;
    await thread.client.disconnect();
    if (_disposed || thread._deleting || !_chats.contains(thread)) return;
    thread._snapshot = thread.client.snapshot;
    _markDirty();
    _notify();
  }

  void updateDraft(String id, String text) {
    final thread = _requireChat(id);
    if (thread._draft == text) return;
    thread._draft = text;
    thread._draftRevision++;
    _markDirty();
    _notify();
  }

  /// Stable per-chat upsert; never trims undelegated dialogue to fit the
  /// bounded remote cache. Flush to await encrypted durable commit.
  void upsertVoiceTurn(String id, VoiceTurn turn) {
    final thread = _requireChat(id);
    if (turn.id.isEmpty || turn.sequence < 0) {
      throw const HarnessException('Invalid local voice turn.');
    }
    final index = thread._voiceTurns.indexWhere(
      (existing) => existing.id == turn.id,
    );
    if (index < 0 && thread._voiceTurns.length >= maxStoredVoiceTurnsPerChat) {
      throw const ChatStoreException(
        ChatStoreFailure.capacity,
        'Voice dialogue has reached the protected local storage limit for this chat.',
      );
    }
    if (index < 0) {
      if (thread._voiceTurns.any(
        (existing) => existing.sequence == turn.sequence,
      )) {
        throw const HarnessException('Duplicate local voice sequence.');
      }
      thread._voiceTurns.add(turn);
      thread._voiceTurns.sort((a, b) => a.sequence.compareTo(b.sequence));
    } else {
      if (thread._voiceTurns[index].sequence != turn.sequence) {
        throw const HarnessException('Local voice identity changed sequence.');
      }
      thread._voiceTurns[index] = turn;
    }
    _markDirty();
    _notify();
  }

  /// Delete this chat locally after a durable encrypted-store commit. Does
  /// not abort or erase the remote host session.
  Future<void> forget(String id) => remove(id);

  /// Forgets both the visible chat and its encrypted credential. The in-memory
  /// thread is retained if the durable removal fails.
  Future<void> remove(String id) async {
    await initialize();
    final thread = _requireChat(id);
    thread._deleting = true;
    thread._generation++;
    thread._acceptChanges = false;
    _markDirty(debounce: false);
    try {
      await _persistNow();
    } catch (_) {
      thread._deleting = false;
      thread._acceptChanges = true;
      _markDirty();
      rethrow;
    }
    _chats.remove(thread);
    _notify();
    // Deletion is already committed; a transport teardown failure must not
    // report that the local credential/transcript is still present.
    try {
      await thread._subscription?.cancel();
    } catch (_) {
      // Continue releasing the client after a listener teardown failure.
    }
    try {
      await thread.client.dispose();
    } catch (_) {
      // The encrypted local deletion remains authoritative.
    }
  }

  /// Commits pending draft/transcript changes. Call before app suspension.
  Future<void> flush() async {
    await initialize();
    _writeTimer?.cancel();
    _writeTimer = null;
    await _persistNow();
  }

  void _attach(ChatThread thread) {
    thread._subscription = thread.client.changes.listen((snapshot) {
      if (_disposed ||
          thread._deleting ||
          !thread._acceptChanges ||
          !_chats.contains(thread)) {
        return;
      }
      final client = thread.client;
      final controlLost =
          client is OmpdControlStatus &&
          (client as OmpdControlStatus).controlLost;
      final ownershipLost =
          thread._reconnect &&
          OmpdConnection.isOmpd(thread._input) &&
          (controlLost ||
              (thread._snapshot.phase == ConnectionPhase.live &&
                  !thread._snapshot.readOnly &&
                  snapshot.phase == ConnectionPhase.live &&
                  snapshot.readOnly));
      if (ownershipLost) {
        // Persist ownership loss even when bootstrap cannot complete. Never
        // silently reclaim write control after an app restart.
        thread._reconnect = false;
      }
      if (snapshot.phase == ConnectionPhase.syncing ||
          snapshot.phase == ConnectionPhase.reconnecting) {
        thread._needsDirectiveRecheck = true;
      } else if (snapshot.phase == ConnectionPhase.live &&
          thread._needsDirectiveRecheck) {
        thread._needsDirectiveRecheck = false;
        if (!VoiceDirective.isPresent(snapshot.rawEntries)) {
          thread._directiveSentSinceBoundary = false;
        }
      }
      if (thread._acceptHostStart) {
        thread._hostStartedAt ??= snapshot.sessionStartedAt;
      }
      // Only a live snapshot confirms a rename or clear. Connecting, syncing,
      // and failed attempts may carry a transport default rather than a host
      // title; keep the last confirmed title, including an empty one.
      final pendingTitle = snapshot.phase == ConnectionPhase.live
          ? null
          : thread._snapshot.title;
      if (thread._connecting && snapshot.phase != ConnectionPhase.live) {
        thread._snapshot = _snapshotWithMessages(
          snapshot,
          thread._snapshot.messages.isEmpty
              ? snapshot.messages
              : thread._snapshot.messages,
          thread._snapshot.rawEntries,
          pendingTitle: pendingTitle,
        );
      } else if (pendingTitle != null) {
        thread._snapshot = _snapshotWithMessages(
          snapshot,
          snapshot.messages,
          snapshot.rawEntries,
          pendingTitle: pendingTitle,
        );
      } else {
        thread._snapshot = snapshot;
      }
      // A host rename must not replace a saved local label.
      if (thread._saved) {
        _markDirty(debounce: !ownershipLost);
        if (ownershipLost) {
          // Reconnect intent controls remote ownership; do not defer this
          // safety change with ordinary draft/history writes.
          unawaited(_persistNow().catchError((_) {}));
        }
      }
      _notify();
    });
  }

  bool _isCurrent(ChatThread thread, int generation) =>
      !_disposed &&
      !thread._deleting &&
      _chats.contains(thread) &&
      thread._generation == generation;

  ChatThread _requireChat(String id) =>
      chat(id) ?? (throw const HarnessException('Chat is no longer open.'));

  void _markDirty({bool debounce = true}) {
    if (!_storageReady || _disposed) return;
    _dirty = true;
    _revision++;
    if (!debounce) return;
    _writeTimer?.cancel();
    _writeTimer = Timer(_writeDebounce, () {
      _writeTimer = null;
      unawaited(_persistNow().catchError((_) {}));
    });
  }

  Future<void> _persistNow() async {
    if (!_storageReady) {
      throw const ChatStoreException(
        ChatStoreFailure.keyUnavailable,
        'Saved chats are unavailable.',
      );
    }
    final active = _persisting;
    if (active != null) {
      await active;
      if (_dirty && !_disposed) await _persistNow();
      return;
    }
    final operation = _runPersistence();
    _persisting = operation;
    try {
      await operation;
    } finally {
      if (identical(_persisting, operation)) _persisting = null;
    }
    if (_dirty && !_disposed) await _persistNow();
  }

  Future<void> _runPersistence() async {
    while (_dirty && !_disposed) {
      final revision = _revision;
      final state = _storedState();
      try {
        await _store.save(state);
        if (_storageError != null) {
          _storageError = null;
          _notify();
        }
      } catch (error) {
        _setStorageError(error);
        _notify();
        rethrow;
      }
      if (_revision == revision) _dirty = false;
    }
  }

  List<StoredChat> _storedState() => _chats
      .where((thread) => thread._saved && !thread._deleting)
      .map((thread) {
        final snapshot = thread._snapshot;
        return StoredChat(
          id: thread.id,
          link: thread._input,
          label: thread._label,
          localLabel: thread._localLabel,
          createdAt: thread._createdAt,
          draft: thread._draft,
          reconnect: thread._reconnect,
          snapshot: StoredSnapshot(
            title: snapshot.title,
            sessionStartedAt: thread._hostStartedAt,
            endpoint: snapshot.endpoint,
            model: snapshot.model,
            readOnly: snapshot.readOnly,
            messages: snapshot.messages,
            rawEntries: snapshot.rawEntries,
          ),
          voiceTurns: thread._voiceTurns,
        );
      })
      .toList(growable: false);

  void _setStorageError(Object error) {
    _storageError = error is ChatStoreException
        ? error.message
        : 'Saved chats are unavailable.';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _writeTimer?.cancel();
    for (final thread in _chats) {
      thread._generation++;
      unawaited(thread._subscription?.cancel());
      unawaited(thread.client.dispose());
    }
    _chats.clear();
    super.dispose();
  }
}

HarnessSnapshot _snapshotWithMessages(
  HarnessSnapshot snapshot,
  List<ChatMessage> messages,
  List<Map<String, Object?>> priorEntries, {
  String? pendingTitle,
}) => HarnessSnapshot(
  phase: snapshot.phase,
  title: pendingTitle ?? snapshot.title,
  sessionStartedAt: snapshot.sessionStartedAt,
  sessionId: snapshot.sessionId,
  endpoint: snapshot.endpoint,
  model: snapshot.model,
  messages: messages,
  readOnly: snapshot.readOnly,
  isStreaming: snapshot.isStreaming,
  activity: snapshot.activity,
  error: snapshot.error,
  questions: snapshot.questions,
  rawEntries: snapshot.rawEntries.isEmpty ? priorEntries : snapshot.rawEntries,
  agentEvents: snapshot.agentEvents,
);

HarnessSnapshot _failedSnapshot(ChatThread thread, HarnessSnapshot latest) =>
    HarnessSnapshot(
      phase: ConnectionPhase.error,
      sessionStartedAt: latest.sessionStartedAt ?? thread._hostStartedAt,
      title: thread._snapshot.title,
      sessionId: latest.sessionId,
      endpoint: latest.endpoint.isEmpty
          ? thread._snapshot.endpoint
          : latest.endpoint,
      model: latest.model.isEmpty ? thread._snapshot.model : latest.model,
      messages: latest.messages.isEmpty
          ? thread._snapshot.messages
          : latest.messages,
      readOnly: latest.readOnly,
      error:
          latest.error ??
          'Could not reconnect. Retry when the host is available.',
      rawEntries: latest.rawEntries.isEmpty
          ? thread._snapshot.rawEntries
          : latest.rawEntries,
      agentEvents: latest.agentEvents.isEmpty
          ? thread._snapshot.agentEvents
          : latest.agentEvents,
    );

bool _genericSessionTitle(String title) {
  final normalized = title.trim().toLowerCase();
  return normalized.isEmpty ||
      normalized == 'omp chat' ||
      normalized == 'omp session' ||
      normalized == 'untitled' ||
      normalized == 'untitled session' ||
      normalized == 'new chat';
}
