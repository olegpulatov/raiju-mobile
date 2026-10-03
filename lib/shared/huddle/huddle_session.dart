// MODIFIED FOR RAIJU: retained Huddle session state feeds its original UI but
// fails before microphone, media, credential, or network side effects.

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'huddle_auth.dart';
import 'huddle_media.dart';
import 'huddle_transport.dart';

enum HuddleSessionPhase {
  idle,
  checkingSupport,
  requestingPermission,
  preparingMedia,
  connecting,
  reconnecting,
  interrupted,
  connected,
  leaving,
  failed,
}

const _notProvided = Object();

@immutable
final class HuddleSessionState {
  final HuddleSessionPhase phase;
  final String? parentChannelId;
  final String? ephemeralChannelId;
  final String? startedEventId;
  final String? currentPubkey;
  final bool isCreator;

  /// Whether the audio relay admitted this identity during this session.
  final bool wasAdmitted;
  final bool isMuted;
  final bool isSpeakerEnabled;
  final int participantCount;
  final List<String> participantPubkeys;
  final Set<String> activeSpeakerPubkeys;
  final Map<String, double> speakerLevels;
  final int reconnectAttempt;
  final int receivedFrameCount;
  final int sentFrameCount;
  final String? issue;
  final String? error;

  /// Whether the current [HuddleSessionPhase.failed] state was caused by a
  /// denied microphone permission. On iOS a denied permission is not
  /// re-prompted, so a blind retry deterministically fails again — the UI
  /// uses this to offer an OS-settings recovery path instead of a bare retry.
  final bool microphonePermissionRequired;

  const HuddleSessionState({
    required this.phase,
    this.parentChannelId,
    this.ephemeralChannelId,
    this.startedEventId,
    this.currentPubkey,
    this.isCreator = false,
    this.wasAdmitted = false,
    this.isMuted = false,
    this.isSpeakerEnabled = false,
    this.participantCount = 0,
    this.participantPubkeys = const [],
    this.activeSpeakerPubkeys = const {},
    this.speakerLevels = const {},
    this.reconnectAttempt = 0,
    this.receivedFrameCount = 0,
    this.sentFrameCount = 0,
    this.issue,
    this.error,
    this.microphonePermissionRequired = false,
  });

  static const idle = HuddleSessionState(phase: HuddleSessionPhase.idle);

  bool get isConnected => phase == HuddleSessionPhase.connected;

  bool get isInSession => switch (phase) {
    HuddleSessionPhase.checkingSupport ||
    HuddleSessionPhase.requestingPermission ||
    HuddleSessionPhase.preparingMedia ||
    HuddleSessionPhase.connecting ||
    HuddleSessionPhase.reconnecting ||
    HuddleSessionPhase.interrupted ||
    HuddleSessionPhase.connected ||
    HuddleSessionPhase.leaving => true,
    HuddleSessionPhase.idle || HuddleSessionPhase.failed => false,
  };

  HuddleSessionState copyWith({
    HuddleSessionPhase? phase,
    Object? parentChannelId = _notProvided,
    Object? ephemeralChannelId = _notProvided,
    Object? startedEventId = _notProvided,
    Object? currentPubkey = _notProvided,
    bool? isCreator,
    bool? wasAdmitted,
    bool? isMuted,
    bool? isSpeakerEnabled,
    int? participantCount,
    List<String>? participantPubkeys,
    Set<String>? activeSpeakerPubkeys,
    Map<String, double>? speakerLevels,
    int? reconnectAttempt,
    int? receivedFrameCount,
    int? sentFrameCount,
    Object? issue = _notProvided,
    Object? error = _notProvided,
    bool? microphonePermissionRequired,
  }) => HuddleSessionState(
    phase: phase ?? this.phase,
    parentChannelId: parentChannelId == _notProvided
        ? this.parentChannelId
        : parentChannelId as String?,
    ephemeralChannelId: ephemeralChannelId == _notProvided
        ? this.ephemeralChannelId
        : ephemeralChannelId as String?,
    startedEventId: startedEventId == _notProvided
        ? this.startedEventId
        : startedEventId as String?,
    currentPubkey: currentPubkey == _notProvided
        ? this.currentPubkey
        : currentPubkey as String?,
    isCreator: isCreator ?? this.isCreator,
    wasAdmitted: wasAdmitted ?? this.wasAdmitted,
    isMuted: isMuted ?? this.isMuted,
    isSpeakerEnabled: isSpeakerEnabled ?? this.isSpeakerEnabled,
    participantCount: participantCount ?? this.participantCount,
    participantPubkeys: participantPubkeys ?? this.participantPubkeys,
    activeSpeakerPubkeys: activeSpeakerPubkeys ?? this.activeSpeakerPubkeys,
    speakerLevels: speakerLevels ?? this.speakerLevels,
    reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
    receivedFrameCount: receivedFrameCount ?? this.receivedFrameCount,
    sentFrameCount: sentFrameCount ?? this.sentFrameCount,
    issue: issue == _notProvided ? this.issue : issue as String?,
    error: error == _notProvided ? this.error : error as String?,
    microphonePermissionRequired:
        microphonePermissionRequired ?? this.microphonePermissionRequired,
  );
}

typedef HuddleMediaFactory = HuddleMedia Function();
typedef HuddleTransportFactory =
    HuddleTransportClient Function(HuddleConnectionParameters parameters);

final huddleMediaFactoryProvider = Provider<HuddleMediaFactory>(
  (_) => MethodChannelHuddleMedia.new,
);

final huddleTransportFactoryProvider = Provider<HuddleTransportFactory>(
  (_) =>
      (parameters) => HuddleTransport(parameters: parameters),
);

final huddleReconnectDelaysProvider = Provider<List<Duration>>(
  (_) => const [
    Duration.zero,
    Duration(milliseconds: 100),
    Duration(milliseconds: 250),
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 2),
  ],
);

final huddleSessionProvider =
    NotifierProvider<HuddleSessionNotifier, HuddleSessionState>(
      HuddleSessionNotifier.new,
    );

/// Owns one foreground mobile Huddle and wires native Opus media to its socket.
final class HuddleSessionNotifier extends Notifier<HuddleSessionState> {
  @override
  HuddleSessionState build() => HuddleSessionState.idle;

  Future<void> join(
    HuddleConnectionParameters parameters, {
    String? currentPubkey,
    bool isCreator = false,
    String? startedEventId,
  }) async {
    state = HuddleSessionState(
      phase: HuddleSessionPhase.failed,
      parentChannelId: parameters.parentChannelId,
      ephemeralChannelId: parameters.ephemeralChannelId,
      startedEventId: startedEventId,
      currentPubkey: currentPubkey?.toLowerCase(),
      isCreator: isCreator,
      error: 'Unavailable yet.',
    );
  }

  Future<bool> openMicrophoneSettings() async {
    final media = ref.read(huddleMediaFactoryProvider)();
    try {
      return await media.openSystemSettings();
    } finally {
      await media.dispose();
    }
  }

  Future<void> setMuted(bool muted) async {}

  Future<void> setSpeakerEnabled(bool enabled) async {}

  Future<void> leave() async {
    if (state.phase == HuddleSessionPhase.idle ||
        state.phase == HuddleSessionPhase.leaving) {
      return;
    }
    state = state.copyWith(phase: HuddleSessionPhase.leaving, error: null);
    await Future<void>.value();
    state = HuddleSessionState.idle;
  }
}
