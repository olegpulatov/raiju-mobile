import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';

// MODIFIED FOR RAIJU: active sends use the OMP companion controller. The
// legacy constructor remains solely for source-compatible inactive Buzz tests.
import '../../companion_controller.dart';
import '../../harness/harness.dart';
import '../../raiju/companion_provider.dart';

import '../../shared/relay/relay.dart';
import '../channels/channel_management_provider.dart';
import '../../shared/profile/user_profile.dart';
import 'channel.dart';
import 'local_message_send_animation_provider.dart';
import 'message_mention_pubkeys.dart';

/// Compatibility send facade for the preserved Buzz composer.
class SendMessage {
  final SignedEventRelay? _signedEventRelay;
  final Future<List<ChannelMember>> Function(String channelId)? _fetchMembers;
  final Map<String, UserProfile> Function()? _readUserCache;
  final void Function(String channelId, NostrEvent event)? _addLocalMessage;
  final void Function(String channelId, String eventId)?
  _markLocalMessageForAnimation;
  final void Function(String channelId, String eventId)? _completeLocalMessage;
  final void Function(String channelId, String eventId)? _removeLocalMessage;
  final bool Function()? _isDeliveryValid;
  final Future<void> Function(String channelId, String content)? _companionSend;

  SendMessage({
    required SignedEventRelay signedEventRelay,
    required Future<List<ChannelMember>> Function(String channelId)
    fetchMembers,
    required Map<String, UserProfile> Function() readUserCache,
    required void Function(String channelId, NostrEvent event) addLocalMessage,
    void Function(String channelId, String eventId)?
    markLocalMessageForAnimation,
    required void Function(String channelId, String eventId)
    completeLocalMessage,
    required void Function(String channelId, String eventId) removeLocalMessage,
    bool Function()? isDeliveryValid,
  }) : _signedEventRelay = signedEventRelay,
       _fetchMembers = fetchMembers,
       _readUserCache = readUserCache,
       _addLocalMessage = addLocalMessage,
       _markLocalMessageForAnimation =
           markLocalMessageForAnimation ?? ((_, _) {}),
       _completeLocalMessage = completeLocalMessage,
       _removeLocalMessage = removeLocalMessage,
       _isDeliveryValid = isDeliveryValid,
       _companionSend = null;

  SendMessage.companion(
    Future<void> Function(String channelId, String content) send,
  ) : _companionSend = send,
      _signedEventRelay = null,
      _fetchMembers = null,
      _readUserCache = null,
      _addLocalMessage = null,
      _markLocalMessageForAnimation = null,
      _completeLocalMessage = null,
      _removeLocalMessage = null,
      _isDeliveryValid = null;

  /// Send a text message to a channel.
  ///
  /// For thread replies, pass [parentEventId] and optionally [rootEventId].
  /// If [rootEventId] is null it defaults to [parentEventId] (direct reply to
  /// thread head). Tags are built to match the desktop's `buildReplyTags`
  /// convention with `root` / `reply` markers. Pass [mediaTags] to append
  /// relay-validated `imeta` tags and NIP-30 `emoji` tags.
  Future<void> call({
    required String channelId,
    required String content,
    String? parentEventId,
    String? rootEventId,
    List<String>? mentionPubkeys,
    Channel? channel,
    List<List<String>> mediaTags = const [],
  }) async {
    final companionSend = _companionSend;
    if (companionSend != null) {
      if (parentEventId != null || rootEventId != null) {
        throw UnsupportedError(
          'Thread replies are not available in OMP chats.',
        );
      }
      if (mediaTags.isNotEmpty) {
        throw UnsupportedError(
          'Media attachments are not available in OMP chats.',
        );
      }
      if (mentionPubkeys?.isNotEmpty == true) {
        throw UnsupportedError('Unavailable yet');
      }
      await companionSend(channelId, content);
      return;
    }
    _ensureDeliveryValid();
    // Use explicitly passed pubkeys, or resolve @mentions against
    // channel members to avoid matching the wrong user.
    final explicitMentions =
        mentionPubkeys ?? await _resolveMentions(content, channelId);
    final authorPubkey = _signedEventRelay!.pubkey;
    final dmRecipientPubkeys = channel?.isDm == true
        ? await _fetchDmRecipientPubkeys(channelId, channel!, authorPubkey)
        : null;
    final resolvedMentions = dmRecipientPubkeys != null
        ? messageMentionPubkeys(
            channel: channel!,
            senderPubkey: authorPubkey,
            explicitMentions: explicitMentions,
            dmRecipientPubkeys: dmRecipientPubkeys,
          )
        : explicitMentions;

    // Normalize mentions: lowercase, deduplicate, exclude self (matching
    // the desktop's normalizeMentionPubkeys).
    final selfLower = authorPubkey?.toLowerCase();
    final seenMentions = <String>{?selfLower};
    final normalizedMentions = <String>[
      for (final pk in resolvedMentions)
        if (seenMentions.add(pk.toLowerCase())) pk,
    ];

    final tags = <List<String>>[
      ['h', channelId],
      if (parentEventId != null) ..._buildReplyTags(parentEventId, rootEventId),
      for (final pk in normalizedMentions) ['p', pk],
      ...mediaTags,
    ];

    _ensureDeliveryValid();
    NostrEvent? localMessage;
    try {
      await _signedEventRelay.submit(
        kind: EventKind.streamMessage,
        content: content,
        tags: tags,
        onSigned: (event) {
          localMessage = event;
          _markLocalMessageForAnimation!(channelId, event.id);
          _addLocalMessage!(channelId, event);
        },
      );
      final event = localMessage;
      if (event != null) _completeLocalMessage!(channelId, event.id);
    } catch (_) {
      final event = localMessage;
      if (event != null) _removeLocalMessage!(channelId, event.id);
      rethrow;
    }
  }

  /// Resolve every identity that is actually a current member of this DM.
  ///
  /// Membership is authoritative for delivery. The channel metadata's `p`
  /// tags can lag membership changes, so they are only used when the membership
  /// snapshot is unavailable.
  Future<Set<String>> _fetchDmRecipientPubkeys(
    String channelId,
    Channel channel,
    String? authorPubkey,
  ) async {
    List<ChannelMember>? members;
    try {
      members = await _fetchMembers!(channelId);
    } catch (_) {
      // Fall back to metadata below so an unavailable membership query does
      // not block ordinary DM sends.
    }

    final author = authorPubkey?.toLowerCase();
    final participants = members != null && members.isNotEmpty
        ? members.map((member) => member.pubkey)
        : channel.participantPubkeys;
    return {
      for (final participant in participants)
        if (participant.trim().isNotEmpty &&
            participant.toLowerCase() != author)
          participant.toLowerCase(),
    };
  }

  void _ensureDeliveryValid() {
    if (_isDeliveryValid?.call() == false) {
      throw StateError(
        'Message delivery cancelled because the active community changed',
      );
    }
  }

  /// Resolve @mentions to pubkeys, scoped to channel members.
  ///
  /// Fetches channel members from the relay and matches @names only
  /// against members of that channel. Falls back to the full user cache
  /// if the member fetch fails.
  Future<List<String>> _resolveMentions(
    String content,
    String channelId,
  ) async {
    final mentionPattern = RegExp(r'@(\w+)');
    final matches = mentionPattern.allMatches(content);
    if (matches.isEmpty) return const [];

    // Try to get channel member pubkeys for scoped resolution.
    Set<String>? memberPubkeys;
    try {
      final members = await _fetchMembers!(channelId);
      memberPubkeys = {for (final m in members) m.pubkey.toLowerCase()};
    } catch (_) {
      // Non-fatal — fall through to unscoped cache lookup.
    }

    final cache = _readUserCache!();
    final pubkeys = <String>{};

    for (final match in matches) {
      final name = match.group(1)?.toLowerCase();
      if (name == null || name.isEmpty) continue;

      for (final profile in cache.values) {
        final displayName = profile.displayName?.toLowerCase();
        if (displayName == null) continue;

        // Match against full display name or first word.
        final firstName = displayName.split(RegExp(r'\s+')).first;
        if (displayName != name && firstName != name) continue;

        // If we have channel members, only match members of this channel.
        if (memberPubkeys != null &&
            !memberPubkeys.contains(profile.pubkey.toLowerCase())) {
          continue;
        }

        pubkeys.add(profile.pubkey);
        break;
      }
    }

    return pubkeys.toList();
  }

  /// Build `e`-tags for a thread reply, matching the desktop convention:
  /// - Direct reply to thread head: `["e", id, "", "reply"]`
  /// - Nested reply: `["e", rootId, "", "root"]` + `["e", parentId, "", "reply"]`
  static List<List<String>> _buildReplyTags(
    String parentEventId,
    String? rootEventId,
  ) {
    final root = rootEventId ?? parentEventId;
    if (parentEventId == root) {
      return [
        ['e', root, '', 'reply'],
      ];
    }
    return [
      ['e', root, '', 'root'],
      ['e', parentEventId, '', 'reply'],
    ];
  }
}

final sendMessageProvider = Provider<SendMessage>((ref) {
  final controller = ref.read(companionControllerProvider);
  final confirmationTracker = _CompanionSendConfirmationTracker(
    controller: controller,
    markConfirmed: (channelId, messageId) {
      ref
          .read(localMessageSendAnimationProvider(channelId).notifier)
          .mark(messageId);
    },
  );
  ref.onDispose(confirmationTracker.dispose);
  return SendMessage.companion(confirmationTracker.send);
});

/// Matches a submitted prompt to the first subsequently observed remote row.
///
/// The harness deliberately has no protocol ACK. A successful socket write is
/// therefore not enough to animate: the server-issued message ID must appear
/// in the live snapshot. Pending observations are abandoned on failure,
/// disconnect, chat removal, timeout, or provider disposal.
class _CompanionSendConfirmationTracker {
  _CompanionSendConfirmationTracker({
    required this.controller,
    required this.markConfirmed,
  });

  final CompanionController controller;
  final void Function(String channelId, String messageId) markConfirmed;
  static const _confirmationWindow = Duration(seconds: 30);
  final Set<_PendingCompanionSend> _pending = {};
  final Set<String> _claimedMessageIds = {};
  bool _listening = false;
  bool _disposed = false;

  Future<void> send(String channelId, String content) async {
    final thread = controller.chat(channelId);
    if (thread == null) {
      throw StateError('This OMP chat is no longer available.');
    }
    if (!thread.snapshot.canSend) {
      throw StateError('This OMP chat is read-only or offline.');
    }

    final prompt = content.trim();
    if (prompt.isEmpty) {
      await controller.sendPrompt(channelId, content);
      return;
    }
    final pending = _PendingCompanionSend(
      channelId: channelId,
      thread: thread,
      prompt: prompt,
      startedAt: DateTime.now(),
      existingMessageIds: {
        for (final message in thread.snapshot.messages)
          if (message.id.trim().isNotEmpty) message.id,
      },
    );
    _pending.add(pending);
    _startListening();
    try {
      await controller.sendPrompt(channelId, content);
    } catch (_) {
      _remove(pending);
      rethrow;
    }
    if (_disposed || !_pending.contains(pending)) return;

    pending.accepted = true;
    pending.timer = Timer(_confirmationWindow, () => _remove(pending));
    _scan(pending);
  }

  void _startListening() {
    if (_listening || _disposed) return;
    controller.addListener(_onControllerChanged);
    _listening = true;
  }

  void _onControllerChanged() {
    for (final pending in List<_PendingCompanionSend>.of(_pending)) {
      _scan(pending);
    }
  }

  void _scan(_PendingCompanionSend pending) {
    final current = controller.chat(pending.channelId);
    if (current != pending.thread ||
        current?.snapshot.phase != ConnectionPhase.live) {
      _remove(pending);
      return;
    }
    if (!pending.accepted) return;

    for (final message in current!.snapshot.messages) {
      final id = message.id.trim();
      final claimKey = '${pending.channelId}\u0000$id';
      if (id.isEmpty ||
          pending.existingMessageIds.contains(id) ||
          _claimedMessageIds.contains(claimKey) ||
          message.role != MessageRole.user ||
          message.text.trim() != pending.prompt ||
          !_isLocalPresentationAuthor(message.author) ||
          _predatesSend(message.timestamp, pending.startedAt)) {
        continue;
      }
      _claimedMessageIds.add(claimKey);
      _remove(pending);
      if (!_disposed) markConfirmed(pending.channelId, id);
      return;
    }
  }

  bool _isLocalPresentationAuthor(String? author) =>
      author?.trim().toLowerCase() == 'raiju';

  bool _predatesSend(DateTime? timestamp, DateTime startedAt) {
    if (timestamp == null) return false;
    // Allow ordinary host/client clock granularity without treating genuinely
    // old history loaded after submission as a confirmation.
    return timestamp.isBefore(startedAt.subtract(const Duration(seconds: 5)));
  }

  void _remove(_PendingCompanionSend pending) {
    if (!_pending.remove(pending)) return;
    pending.timer?.cancel();
    if (_pending.isEmpty && _listening) {
      controller.removeListener(_onControllerChanged);
      _listening = false;
      _claimedMessageIds.clear();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final pending in _pending) {
      pending.timer?.cancel();
    }
    _pending.clear();
    _claimedMessageIds.clear();
    if (_listening) {
      controller.removeListener(_onControllerChanged);
      _listening = false;
    }
  }
}

class _PendingCompanionSend {
  _PendingCompanionSend({
    required this.channelId,
    required this.thread,
    required this.prompt,
    required this.startedAt,
    required this.existingMessageIds,
  });

  final String channelId;
  final ChatThread thread;
  final String prompt;
  final DateTime startedAt;
  final Set<String> existingMessageIds;
  bool accepted = false;
  Timer? timer;
}
