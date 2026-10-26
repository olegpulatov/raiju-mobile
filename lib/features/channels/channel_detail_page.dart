// Modified for Raiju: local OMP controller and chat avatar preference drive
// detail behavior; retained Buzz controls remain visual-only.

import 'dart:async';
import 'dart:math' show cos, max, min, pi;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../harness/harness.dart';
import '../../raiju/chat_avatar_preference.dart';
import '../../raiju/companion_provider.dart';
import '../../raiju/timeline_projection.dart';
import '../../spark/spark.dart';
import '../../shared/custom_emoji/custom_emoji_provider.dart';
import '../../shared/animated_avatar.dart';
import '../../shared/emoji/emoji_burst.dart';
import '../../shared/huddle/huddle.dart';
import '../../shared/mentions/agent_identity_provider.dart';
import '../../shared/relay/relay.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/avatar_image.dart';
import '../../shared/widgets/buzz_loading_indicator.dart';
import '../../shared/widgets/bouncing_dots_indicator.dart';
import '../../shared/widgets/concentric_sheet_surface.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/frosted_scaffold.dart';
import '../../shared/widgets/flapping_bee.dart';
import '../../shared/widgets/keyboard_dismiss_on_drag.dart';
import '../../shared/widgets/ios_glass_navigation_button.dart';
import '../../shared/widgets/masked_avatar_badge.dart';
import '../../shared/widgets/message_author_meta.dart';
import '../../shared/widgets/modal_presentation.dart';
import '../../shared/widgets/skeleton.dart';
import '../profile/presence_cache_provider.dart';
import '../../shared/profile/user_cache_provider.dart';
import '../../shared/profile/user_profile.dart';
import 'android_ime_lift.dart';
import 'channel.dart';
import 'channel_actions_sheet.dart';
import 'channel_link_navigation.dart';
import 'agent_activity/working_bots_provider.dart';
import 'channel_management_provider.dart';
import 'channel_messages_provider.dart';
import 'channel_typing_provider.dart';
import 'channels_provider.dart';
import 'compose_bar.dart';
import 'composer_dock_size_reporter.dart';
import 'date_formatters.dart';
import 'day_divider.dart';
import 'dm_channel_labels.dart';
import 'ephemeral_channel_display.dart';
import 'emoji_picker.dart';
import 'ime_metrics_settle_observer.dart';
import 'jump_to_latest_button.dart';
import 'jump_to_latest_switcher.dart';
import 'local_message_send_animation_provider.dart';
import 'local_message_send_transition.dart';
import 'mobile_huddle_controller.dart';
import 'members_sheet.dart';
import 'message_actions.dart';
import 'message_action_backdrop_state.dart';
import 'message_long_press_region.dart';
import 'message_content.dart';
import 'reaction_row.dart';
import 'recent_emoji_provider.dart';
import 'send_message_provider.dart';
import '../profile/user_profile_sheet.dart';
import 'small_avatar.dart';
import 'sticky_date_header.dart';
import 'thread_detail_page.dart';
import 'timeline_message.dart';
import 'timeline_viewport_anchor.dart';

part 'channel_detail_page/message_list.dart';
part 'channel_detail_page/system_rows.dart';
part 'channel_detail_page/huddle_sheet.dart';
part 'channel_detail_page/huddle_call_avatar.dart';
part 'channel_detail_page/huddle_participant_cluster.dart';
part 'channel_detail_page/huddle_call_participants.dart';
part 'channel_detail_page/huddle_participant_overlay.dart';
part 'channel_detail_page/huddle_call_controls.dart';
part 'channel_detail_page/huddle_drawer.dart';
part 'channel_detail_page/huddle_reactions.dart';
part 'channel_detail_page/message_bubble.dart';
part 'channel_detail_page/banners.dart';
part 'channel_detail_page/app_bar.dart';

/// Controls how a hydrated initial thread is added to the navigation stack.
enum InitialThreadRouteBehavior {
  /// Keep the channel route beneath the thread.
  push,

  /// Replace the temporary channel route so Back returns to its origin.
  replaceCurrentRoute,
}

class ChannelDetailPage extends HookConsumerWidget {
  final Channel channel;
  final String? initialMessageId;
  final String? initialThreadRootId;

  /// How the automatically opened initial thread affects the route stack.
  final InitialThreadRouteBehavior initialThreadRouteBehavior;

  const ChannelDetailPage({
    super.key,
    required this.channel,
    this.initialMessageId,
    this.initialThreadRootId,
    this.initialThreadRouteBehavior = InitialThreadRouteBehavior.push,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final composerDockHeight = useState(0.0);
    final composerFocusNode = useFocusNode();
    final restoreComposerFocus = useRef<VoidCallback?>(null);
    final viewedChat = ref.read(viewedCompanionChatProvider.notifier);
    final detailRoute = ModalRoute.of(context);
    final isCurrentChatRoute = detailRoute?.isCurrent ?? false;
    useEffect(() {
      if (isCurrentChatRoute) {
        Future.microtask(() {
          if (viewedChat.mounted &&
              context.mounted &&
              (ModalRoute.of(context)?.isCurrent ?? false)) {
            viewedChat.state = channel.id;
          }
        });
      }
      return () {
        Future.microtask(() {
          if (viewedChat.mounted && viewedChat.state == channel.id) {
            viewedChat.state = null;
          }
        });
      };
    }, [channel.id, isCurrentChatRoute]);
    final controller = ref.watch(companionControllerProvider);
    final thread = controller.chat(channel.id);
    final snapshot = thread?.snapshot ?? const HarnessSnapshot();
    final sparkPresentation = ref.watch(
      sparkControllerProvider.select(
        (controller) => (
          controller.snapshot.boundChatId,
          controller.snapshot.phase,
          controller.settings.toolVisibility,
          controller.settings.hideThinking,
        ),
      ),
    );
    final messages = projectTimelineMessages(
      snapshot.messages,
      voiceTurns: thread?.voiceTurns ?? const [],
      toolVisibility: sparkPresentation.$3,
      hideThinking: sparkPresentation.$4,
      isVoiceBoundAndActive:
          sparkPresentation.$1 == channel.id &&
          sparkPresentation.$2 != SparkPhase.idle,
    );
    final entries = buildMainTimelineEntries(messages);
    final sendMessage = ref.read(sendMessageProvider);
    final appBarTitleContentHeight = _twoLineAppBarTitleContentHeight(
      context,
      isDm: true,
    );
    final usesNativeIosGlassBackButton =
        Navigator.canPop(context) &&
        Theme.of(context).platform == TargetPlatform.iOS;
    final subtitle = _companionSubtitle(snapshot);
    final showsComposer = thread != null;

    Future<void> runAction(
      Future<void> Function() action, {
      required String failure,
    }) async {
      try {
        await action();
      } catch (_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(failure)));
      }
    }

    final statusBanner = _CompanionStatusBanner(
      snapshot: snapshot,
      storageError: controller.storageError,
      promptTrackingError: thread?.promptTrackingError,
      chatAvailable: thread != null,
      onRetry: thread == null
          ? null
          : () => runAction(
              () => controller.reconnect(channel.id),
              failure: 'Could not reconnect. Check that the host is available.',
            ),
      onDisconnect: thread == null
          ? null
          : () => runAction(
              () => controller.disconnect(channel.id),
              failure: 'Could not disconnect this chat.',
            ),
      onStop: snapshot.isStreaming && !snapshot.readOnly
          ? () => runAction(
              () => controller.abort(channel.id),
              failure: 'Could not stop the current response.',
            )
          : null,
    );
    final questionCard = snapshot.questions.isEmpty
        ? null
        : _CompanionQuestionCard(
            question: snapshot.questions.first,
            remainingCount: snapshot.questions.length - 1,
            enabled: snapshot.canSend,
            onRespond: (value) => runAction(
              () => controller.respond(
                channel.id,
                snapshot.questions.first.id,
                value,
              ),
              failure: 'Could not send that answer. Please try again.',
            ),
          );

    void explainUnavailable(String feature) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$feature is preserved but is not available for companion chats yet.',
          ),
        ),
      );
    }

    return FrostedScaffold(
      resizeToAvoidBottomInset: !usesFixedAndroidImeViewport,
      appBar: FrostedAppBar(
        leading: usesNativeIosGlassBackButton
            ? IosGlassNavigationButton(
                key: const ValueKey('channel-ios-glass-back'),
                icon: IosGlassNavigationIcon.back,
                semanticLabel: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
                width: iosGlassChannelHeaderLeadingWidth,
                buttonCenterX: iosGlassChannelHeaderButtonCenterX,
                nativeViewSuppressed: messageActionBackdropActive,
              )
            : null,
        iconColor: context.colors.primary,
        titleContentHeight: appBarTitleContentHeight,
        titleStyle: channelTitleTextStyle,
        title: Padding(
          padding: EdgeInsets.only(
            left: usesNativeIosGlassBackButton
                ? iosGlassChannelHeaderTitleSpacing
                : 0,
          ),
          child: _DmAppBarTitle(
            channel: channel,
            currentPubkey: 'local',
            companionTitle: thread?.title ?? channel.name,
            companionSubtitle: subtitle,
            companionPhase: snapshot.phase,
          ),
        ),
        actions: [
          IconButton(
            key: const ValueKey('companion-huddle-action'),
            color: context.colors.primary,
            tooltip: 'Start Huddle',
            onPressed: () => explainUnavailable('Huddles'),
            icon: const Icon(LucideIcons.headphones, size: 22),
          ),
          IconButton(
            key: const ValueKey('companion-members-action'),
            color: context.colors.primary,
            tooltip: 'Members',
            onPressed: () => explainUnavailable('Member management'),
            icon: const Icon(LucideIcons.users, size: 22),
          ),
          IconButton(
            key: const ValueKey('companion-channel-actions'),
            color: context.colors.primary,
            tooltip: 'Channel actions',
            onPressed: () =>
                showChannelActionsSheet(
                  context: context,
                  channel: channel,
                  isUnread: false,
                  companionMode: true,
                ).then((deleted) {
                  if (deleted == true &&
                      context.mounted &&
                      detailRoute?.isCurrent == true) {
                    unawaited(Navigator.of(context).maybePop());
                  }
                }),
            icon: const Icon(LucideIcons.ellipsisVertical, size: 22),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Column(
            children: [
              Expanded(
                child: _MessageList(
                  entries: entries,
                  allMessages: messages,
                  initialMessageId: initialMessageId,
                  initialThreadRootId: null,
                  initialThreadRouteBehavior: initialThreadRouteBehavior,
                  initialOrdinaryUnreadMessageIds: const {},
                  initialOldestOrdinaryUnreadMessageId: null,
                  initialForcedUnreadMessageIds: const {},
                  hasInitialUnread: false,
                  channelId: channel.id,
                  currentPubkey: 'local',
                  isMember: snapshot.canSend,
                  isArchived: false,
                  appBarTitleContentHeight: appBarTitleContentHeight,
                  composerBottomInset: showsComposer
                      ? composerDockHeight.value
                      : 0,
                  composerFocusNode: showsComposer ? composerFocusNode : null,
                  restoreComposerFocus: showsComposer
                      ? () => restoreComposerFocus.value?.call()
                      : null,
                  companionMode: true,
                ),
              ),
              if (!showsComposer) statusBanner,
              if (!showsComposer && questionCard != null) questionCard,
            ],
          ),
          if (showsComposer)
            AndroidImeLift(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: ComposerDockSizeReporter(
                  key: const ValueKey('channel-composer-dock'),
                  onHeightChanged: (height) {
                    if ((composerDockHeight.value - height).abs() < 0.5) return;
                    composerDockHeight.value = height;
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      statusBanner,
                      ?questionCard,
                      ComposeBar(
                        channelId: channel.id,
                        focusNode: composerFocusNode,
                        onFocusRestorerChanged: (restoreFocus) =>
                            restoreComposerFocus.value = restoreFocus,
                        channelName: '',
                        companionMode: true,
                        onSend:
                            (
                              content,
                              mentionPubkeys, {
                              mediaTags = const <List<String>>[],
                            }) {
                              final spark = ref.read(sparkControllerProvider);
                              final voice = spark.snapshot;
                              if (voice.boundChatId == channel.id &&
                                  voice.phase != SparkPhase.idle &&
                                  voice.phase != SparkPhase.connecting &&
                                  voice.phase != SparkPhase.error &&
                                  mentionPubkeys.isEmpty &&
                                  mediaTags.isEmpty) {
                                return spark.sendText(content);
                              }
                              return sendMessage.call(
                                channelId: channel.id,
                                content: content,
                                mentionPubkeys: mentionPubkeys,
                                channel: channel,
                                mediaTags: mediaTags,
                              );
                            },
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _companionSubtitle(HarnessSnapshot snapshot) {
  final activity = snapshot.activity.trim();
  if (activity.isNotEmpty) return activity;
  if (snapshot.isStreaming) return 'Responding…';
  final phase = switch (snapshot.phase) {
    ConnectionPhase.disconnected => 'Disconnected',
    ConnectionPhase.connecting => 'Connecting…',
    ConnectionPhase.syncing => 'Syncing…',
    ConnectionPhase.live => snapshot.readOnly ? 'Read only' : 'Connected',
    ConnectionPhase.reconnecting => 'Reconnecting…',
    ConnectionPhase.ended => 'Session ended',
    ConnectionPhase.error => 'Connection problem',
  };
  final model = snapshot.model.trim();
  return model.isEmpty || snapshot.phase != ConnectionPhase.live
      ? phase
      : '$phase · $model';
}
