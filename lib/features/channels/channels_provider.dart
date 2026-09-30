// MODIFIED FOR RAIJU: this upstream Buzz seam now projects local OMP chats and
// must never start the retained relay, account, push, or Nostr services.
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../companion_controller.dart';
import '../../raiju/companion_provider.dart';
import 'channel.dart';
import 'channel_management_provider.dart' show ChannelMember;
import 'unread_badge/observed_unread_event.dart';

/// Presentation identities used by the retained Buzz channel widgets.
///
/// These are UI roles, not Nostr public keys or emulated protocol events.
const localChannelParticipantId = 'local';
const assistantChannelParticipantId = 'assistant';

/// Maps one persisted OMP session into the original private-DM presentation.
Channel channelFromChatThread(ChatThread thread) {
  final messages = thread.snapshot.messages;
  final lastTimestamp = messages
      .map((message) => message.timestamp)
      .whereType<DateTime>()
      .fold<DateTime?>(null, (latest, value) {
        if (latest == null || value.isAfter(latest)) return value;
        return latest;
      });
  final title = thread.title.trim().isEmpty
      ? 'OMP session'
      : thread.title.trim();

  return Channel(
    id: thread.id,
    name: title,
    channelType: 'dm',
    visibility: 'private',
    description: thread.snapshot.model.trim().isEmpty
        ? 'Connected OMP companion session'
        : 'OMP companion · ${thread.snapshot.model.trim()}',
    createdBy: localChannelParticipantId,
    createdAt: thread.createdAt,
    memberCount: 2,
    lastMessageAt: lastTimestamp,
    participants: ['You', title],
    participantPubkeys: const [
      localChannelParticipantId,
      assistantChannelParticipantId,
    ],
    isMember: true,
  );
}

/// Describes the retained, currently inactive Buzz channel directory surface.
enum ChannelDirectoryLoadStatus { idle, loading, loaded, error }

class ChannelDirectoryLoadState {
  final String? scope;
  final ChannelDirectoryLoadStatus status;

  const ChannelDirectoryLoadState({required this.scope, required this.status});
  const ChannelDirectoryLoadState.idle()
    : scope = null,
      status = ChannelDirectoryLoadStatus.idle;
}

String channelDirectoryScope(String relayBaseUrl, String? pubkey) =>
    '$relayBaseUrl:${pubkey?.toLowerCase() ?? ''}';

class ChannelDirectoryLoadNotifier extends Notifier<ChannelDirectoryLoadState> {
  @override
  ChannelDirectoryLoadState build() => const ChannelDirectoryLoadState.idle();

  bool isLoading(String scope) =>
      state.scope == scope &&
      state.status == ChannelDirectoryLoadStatus.loading;
  void markLoading(String scope) => state = ChannelDirectoryLoadState(
    scope: scope,
    status: ChannelDirectoryLoadStatus.loading,
  );
  void markIdle(String scope) => state = ChannelDirectoryLoadState(
    scope: scope,
    status: ChannelDirectoryLoadStatus.idle,
  );
  void markLoaded(String scope) => state = ChannelDirectoryLoadState(
    scope: scope,
    status: ChannelDirectoryLoadStatus.loaded,
  );
  void markError(String scope) => state = ChannelDirectoryLoadState(
    scope: scope,
    status: ChannelDirectoryLoadStatus.error,
  );
}

final channelDirectoryLoadStatusProvider =
    NotifierProvider<ChannelDirectoryLoadNotifier, ChannelDirectoryLoadState>(
      ChannelDirectoryLoadNotifier.new,
    );

/// Compatibility adapter retaining Buzz's AsyncNotifier public surface.
class ChannelsNotifier extends AsyncNotifier<List<Channel>> {
  bool _hasLoaded = false;

  List<ChannelMember> cachedMembersForChannel(String channelId) => const [];
  Map<String, int> get latestObservedByChannel => const {};
  Map<String, Map<String, ObservedUnreadEvent>>
  get observedUnreadEventsByChannel => const {};
  Set<String> get hiddenDmIds => const {};
  bool get hasLoaded => _hasLoaded;

  @override
  Future<List<Channel>> build() async {
    final controller = ref.watch(companionControllerProvider);
    if (controller.isLoading) await controller.initialize();
    final chats = controller.chats;
    final storageError = controller.storageError;
    if (storageError != null && chats.isEmpty) throw StateError(storageError);
    _hasLoaded = true;
    return chats.map(channelFromChatThread).toList(growable: false);
  }

  Future<void> refresh({bool fetchDirectory = false}) async {
    final controller = ref.read(companionControllerProvider);
    state = const AsyncLoading();
    try {
      await controller.initialize();
      final chats = controller.chats;
      final storageError = controller.storageError;
      if (storageError != null && chats.isEmpty) throw StateError(storageError);
      _hasLoaded = true;
      state = AsyncData(
        chats.map(channelFromChatThread).toList(growable: false),
      );
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
    }
  }

  void clearObservedUnreadForChannel(String channelId) {}
  void clearObservedUnreadCoveredByRead(String channelId, int readAt) {}

  /// Retained directory UI is intentionally inactive for OMP sessions.
  Future<void> ensureDirectoryLoaded() async {
    ref
        .read(channelDirectoryLoadStatusProvider.notifier)
        .markLoaded('raiju-local');
  }

  Future<void> retryDirectory() => ensureDirectoryLoaded();
}

final channelsProvider = AsyncNotifierProvider<ChannelsNotifier, List<Channel>>(
  ChannelsNotifier.new,
);
