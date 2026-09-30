import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/clipboard_utils.dart';
import '../../raiju/companion_provider.dart';
import '../../shared/mentions/agent_identity_provider.dart';
import '../../spark/spark.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/app_list.dart';
import '../../shared/widgets/app_list_card.dart';
import '../../shared/widgets/avatar_image.dart';
import '../../shared/widgets/buzz_action_tile.dart';
import '../../shared/widgets/buzz_loading_indicator.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/frosted_scaffold.dart';
import '../../shared/widgets/ios_glass_navigation_button.dart';
import '../../shared/widgets/lucide_star_icon.dart';
import '../../shared/widgets/modal_presentation.dart';
import '../../shared/widgets/sheet_divider.dart';
import 'channel.dart';
import 'add_members_sheet.dart';
import 'channel_management_provider.dart';
import 'channel_mutes/channel_mutes_provider.dart';
import 'channel_sections/channel_sections_provider.dart';
import 'channel_stars/channel_stars_provider.dart';
import 'channels_provider.dart';
import 'manage_channel_sheet.dart';
import 'members_sheet.dart';
import '../../shared/profile/user_cache_provider.dart';
import '../../shared/read_state/read_state_provider.dart';
import '../../shared/read_state/read_state_time.dart';

part 'channel_details_page.dart';

/// Opens the mobile channel actions sheet and returns whether its parent page
/// should close after a successful lifecycle action.
Future<bool?> showChannelActionsSheet({
  required BuildContext context,
  required Channel channel,
  required bool isUnread,
  VoidCallback? onMarkRead,
  String? sectionId,
  bool companionMode = false,
}) async {
  ModalRoute<bool>? sheetRoute;
  Future<bool>? deletion;
  final sheetResult = await showBuzzModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(
      maxWidth: 640,
      maxHeight: MediaQuery.sizeOf(context).height * 0.7,
    ),
    builder: (sheetContext) {
      sheetRoute ??= ModalRoute.of(sheetContext);
      return ChannelActionsSheet(
        channel: channel,
        isUnread: isUnread,
        onMarkRead: onMarkRead,
        sectionId: sectionId,
        companionMode: companionMode,
        onDeleteStarted: (pending) => deletion = pending,
      );
    },
  );
  // Navigator.pop resolves the modal future at the start of its reverse
  // transition. The parent detail must not decide whether it is current until
  // the sheet has actually left the navigator.
  await sheetRoute?.completed;
  // Flutter's sheet drag handle can pop imperatively while a write is pending.
  // Keep the durable outcome alive after the modal route itself has closed.
  final pending = deletion;
  return pending == null ? sheetResult : await pending;
}

/// Mobile action sheet for channel-level read, organization, and lifecycle
/// operations.
class ChannelActionsSheet extends HookConsumerWidget {
  const ChannelActionsSheet({
    super.key,
    required this.channel,
    required this.isUnread,
    this.onMarkRead,
    this.sectionId,
    this.companionMode = false,
    this.onDeleteStarted,
  });

  final Channel channel;
  final bool isUnread;
  final VoidCallback? onMarkRead;
  final String? sectionId;
  final bool companionMode;

  /// Keeps the confirmed deletion result alive if the sheet is swipe-dismissed.
  final ValueChanged<Future<bool>>? onDeleteStarted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final displayedChannel = useState(channel);
    final currentChannel = displayedChannel.value;
    final companionController = companionMode
        ? ref.watch(companionControllerProvider)
        : null;
    final sparkController = companionMode
        ? ref.watch(sparkControllerProvider)
        : null;
    final sparkSettings = sparkController?.settings ?? const SparkSettings();
    final sparkInitialization = useMemoized(() async {
      if (sparkController == null) return false;
      await sparkController.initialize();
      return sparkController.settingsLoaded;
    }, [sparkController]);
    final sparkLoaded = useFuture(sparkInitialization);
    final sparkReady = sparkLoaded.data == true;
    final savingSparkSettings = useState(false);
    final deletingChat = useState(false);
    final isMuted =
        !companionMode &&
        ref.watch(channelMutesProvider).store.channels[channel.id]?.muted ==
            true;
    final isStarred =
        !companionMode &&
        !channel.isDm &&
        ref.watch(channelStarsProvider).store.channels[channel.id]?.starred ==
            true;
    final membersAsync = companionMode || channel.isDm
        ? const AsyncValue<List<ChannelMember>>.data([])
        : ref.watch(channelMembersProvider(channel.id));
    final agentOwnersAsync = companionMode || channel.isDm
        ? const AsyncValue<Map<String, String>>.data({})
        : ref.watch(agentOwnersProvider);
    final currentPubkey = companionMode
        ? null
        : ref.watch(currentPubkeyProvider)?.toLowerCase();
    final currentMember = membersAsync.value?.cast<ChannelMember?>().firstWhere(
      (member) => member?.pubkey.toLowerCase() == currentPubkey,
      orElse: () => null,
    );
    final ownsOwnerAgent =
        currentPubkey != null &&
        membersAsync.value?.any(
              (member) =>
                  member.isOwner &&
                  agentOwnersAsync.value?[member.pubkey.toLowerCase()]
                          ?.toLowerCase() ==
                      currentPubkey,
            ) ==
            true;
    final canManageLifecycle =
        currentMember?.isElevated == true || ownsOwnerAgent;
    final canArchive = !channel.isArchived && canManageLifecycle;
    final canUnarchive = channel.isArchived && canManageLifecycle;
    final canDelete =
        !channel.isArchived &&
        (currentMember?.isOwner == true || ownsOwnerAgent);
    final lifecycleCapabilitiesLoading =
        membersAsync.isLoading || agentOwnersAsync.isLoading;
    final lifecycleCapabilitiesUnavailable =
        membersAsync.hasError || agentOwnersAsync.hasError;

    void close() {
      if (deletingChat.value) return;
      Navigator.of(context).pop();
    }

    void explainUnavailable(String feature) {
      if (deletingChat.value) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      close();
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            '$feature is preserved but is not available for companion chats yet.',
          ),
        ),
      );
    }

    Future<void> updateSparkSettings(SparkSettings settings) async {
      if (!sparkReady || savingSparkSettings.value || deletingChat.value) {
        return;
      }
      savingSparkSettings.value = true;
      try {
        await ref.read(sparkControllerProvider).saveSettings(settings);
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(SnackBar(content: Text(error.toString())));
        }
      } finally {
        if (context.mounted) savingSparkSettings.value = false;
      }
    }

    Future<void> deleteCompanionChat() async {
      if (deletingChat.value) return;
      final confirmed = await showBuzzDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Delete this chat from your device?'),
          content: const Text(
            'Removes this connection, draft, and local voice transcript from this device. '
            'Remote OMP history and work are not deleted or stopped.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete chat'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
      final sheetRoute = ModalRoute.of(context);
      deletingChat.value = true;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Future<bool> commit() async {
        try {
          final spark = ref.read(sparkControllerProvider);
          if (spark.snapshot.boundChatId == channel.id) await spark.stop();
          await companionController!.forget(channel.id);
          return true;
        } catch (error) {
          if (messenger?.mounted == true) {
            messenger!.showSnackBar(
              SnackBar(
                content: Text(
                  'Could not delete this chat from this device. $error',
                ),
              ),
            );
          }
          return false;
        } finally {
          if (context.mounted) deletingChat.value = false;
        }
      }

      final completion = commit();
      onDeleteStarted?.call(completion);
      if (await completion &&
          context.mounted &&
          sheetRoute?.isCurrent == true) {
        Navigator.of(context).pop(true);
      }
    }

    return PopScope(
      canPop: !deletingChat.value,
      child: SafeArea(
        top: false,
        child: IconTheme.merge(
          data: const IconThemeData(size: 22),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              Grid.gutter,
              0,
              Grid.gutter,
              Grid.xs,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!channel.isDm) ...[
                  _ChannelQuickActionsRow(
                    isStarred: isStarred,
                    isUnread: isUnread,
                    onToggleStar: () {
                      if (companionMode) {
                        explainUnavailable('Starring channels');
                        return;
                      }
                      close();
                      final notifier = ref.read(channelStarsProvider.notifier);
                      isStarred
                          ? notifier.unstarChannel(channel.id)
                          : notifier.starChannel(channel.id);
                    },
                    onToggleRead: () {
                      if (companionMode) {
                        explainUnavailable('Read markers');
                        return;
                      }
                      close();
                      final timestamp = dateTimeToUnixSeconds(
                        channel.lastMessageAt,
                      );
                      if (isUnread) {
                        onMarkRead?.call();
                        if (timestamp != null) {
                          ref
                              .read(readStateProvider.notifier)
                              .markContextRead(
                                channel.id,
                                timestamp,
                                clearForcedMessages: true,
                              );
                          ref
                              .read(channelsProvider.notifier)
                              .clearObservedUnreadCoveredByRead(
                                channel.id,
                                timestamp,
                              );
                        }
                      } else {
                        ref
                            .read(readStateProvider.notifier)
                            .markContextUnread(
                              channel.id,
                              channelId: channel.id,
                            );
                      }
                    },
                  ),
                  const SizedBox(height: Grid.xs),
                ],
                if (!channel.isDm)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(LucideIcons.folderInput),
                    title: const Text('Move to section…'),
                    onTap: () async {
                      if (companionMode) {
                        explainUnavailable('Channel sections');
                        return;
                      }
                      final pageContext = Navigator.of(
                        context,
                        rootNavigator: true,
                      ).context;
                      close();
                      await _showMoveSectionSheet(
                        pageContext,
                        ref,
                        channel: channel,
                        sectionId: sectionId,
                      );
                    },
                  ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    isMuted ? LucideIcons.bell : LucideIcons.bellOff,
                  ),
                  title: Text(isMuted ? 'Unmute channel' : 'Mute channel'),
                  onTap: () {
                    if (companionMode) {
                      explainUnavailable('Muting channels');
                      return;
                    }
                    close();
                    final notifier = ref.read(channelMutesProvider.notifier);
                    isMuted
                        ? notifier.unmuteChannel(channel.id)
                        : notifier.muteChannel(channel.id);
                  },
                ),
                if (!channel.isDm)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(LucideIcons.settings),
                    title: const Text('Manage channel'),
                    onTap: () async {
                      if (companionMode) {
                        explainUnavailable('Channel management');
                        return;
                      }
                      final shouldClose = await showBuzzModalBottomSheet<bool>(
                        context: context,
                        title: 'Manage channel',
                        isScrollControlled: true,
                        showDragHandle: true,
                        constraints: BoxConstraints(
                          maxWidth: 640,
                          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
                        ),
                        builder: (_) => ManageChannelSheet(
                          channel: currentChannel,
                          canEditDetails:
                              canManageLifecycle && !currentChannel.isArchived,
                          onChannelUpdated: (updated) =>
                              displayedChannel.value = updated,
                        ),
                      );
                      if (shouldClose == true && context.mounted) {
                        Navigator.of(context).pop(true);
                      }
                    },
                  ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(LucideIcons.copy),
                  title: const Text('Copy channel name'),
                  onTap: deletingChat.value
                      ? null
                      : () {
                          final pageContext = Navigator.of(
                            context,
                            rootNavigator: true,
                          ).context;
                          close();
                          copyToClipboard(
                            pageContext,
                            currentChannel.name,
                            message: 'Channel name copied to clipboard',
                          );
                        },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(LucideIcons.hash),
                  title: const Text('Copy channel ID'),
                  onTap: deletingChat.value
                      ? null
                      : () {
                          final pageContext = Navigator.of(
                            context,
                            rootNavigator: true,
                          ).context;
                          close();
                          copyToClipboard(
                            pageContext,
                            channel.id,
                            message: 'Channel ID copied to clipboard',
                          );
                        },
                ),
                if (companionMode) ...[
                  const SheetDivider(),
                  if (sparkLoaded.data == false)
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Spark settings unavailable'),
                      subtitle: Text(
                        'Saved Spark settings could not be loaded.',
                      ),
                    ),
                  SwitchListTile.adaptive(
                    key: const ValueKey('companion-quick-show-thinking'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show thinking'),
                    value: !sparkSettings.hideThinking,
                    onChanged:
                        !sparkReady ||
                            savingSparkSettings.value ||
                            deletingChat.value
                        ? null
                        : (value) => unawaited(
                            updateSparkSettings(
                              sparkSettings.copyWith(hideThinking: !value),
                            ),
                          ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show tool activity'),
                    trailing: DropdownButton<SparkToolVisibility>(
                      key: const ValueKey('companion-quick-tool-visibility'),
                      value: sparkSettings.toolVisibility,
                      items: const [
                        DropdownMenuItem(
                          value: SparkToolVisibility.show,
                          child: Text('Show'),
                        ),
                        DropdownMenuItem(
                          value: SparkToolVisibility.hide,
                          child: Text('Hide'),
                        ),
                        DropdownMenuItem(
                          value: SparkToolVisibility.hideInVoice,
                          child: Text('Hide during voice'),
                        ),
                      ],
                      onChanged:
                          !sparkReady ||
                              savingSparkSettings.value ||
                              deletingChat.value
                          ? null
                          : (value) {
                              if (value != null) {
                                unawaited(
                                  updateSparkSettings(
                                    sparkSettings.copyWith(
                                      toolVisibility: value,
                                    ),
                                  ),
                                );
                              }
                            },
                    ),
                  ),
                  SwitchListTile.adaptive(
                    key: const ValueKey('companion-quick-announce-terminal'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Read terminal replies aloud'),
                    value: sparkSettings.announceTerminalReplies,
                    onChanged:
                        !sparkReady ||
                            savingSparkSettings.value ||
                            deletingChat.value
                        ? null
                        : (value) => unawaited(
                            updateSparkSettings(
                              sparkSettings.copyWith(
                                announceTerminalReplies: value,
                              ),
                            ),
                          ),
                  ),
                ],
                if (companionMode)
                  ListTile(
                    key: const ValueKey('companion-actions-disconnect'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(LucideIcons.wifiOff),
                    title: const Text('Disconnect'),
                    subtitle: const Text('Stops automatic reconnecting'),
                    onTap: deletingChat.value
                        ? null
                        : () {
                            final messenger = ScaffoldMessenger.maybeOf(
                              context,
                            );
                            close();
                            final controller = companionController!;
                            if (controller.chat(channel.id) == null) {
                              messenger?.showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'This companion chat is no longer open.',
                                  ),
                                ),
                              );
                              return;
                            }
                            unawaited(
                              controller.disconnect(channel.id).catchError((_) {
                                messenger?.showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Could not disconnect this chat.',
                                    ),
                                  ),
                                );
                              }),
                            );
                          },
                  ),
                if (companionMode)
                  ListTile(
                    key: const ValueKey('companion-actions-delete-chat'),
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      LucideIcons.trash2,
                      color: context.colors.error,
                    ),
                    title: Text(
                      'Delete chat',
                      style: TextStyle(color: context.colors.error),
                    ),
                    onTap: deletingChat.value
                        ? null
                        : () => unawaited(deleteCompanionChat()),
                  ),
                if (!channel.isDm) ...[
                  const SheetDivider(),
                  if (channel.isMember && !channel.isArchived)
                    _ActionTile(
                      icon: LucideIcons.logOut,
                      label: 'Leave channel',
                      destructive: true,
                      onTap: () {
                        if (companionMode) {
                          explainUnavailable('Leaving channels');
                          return;
                        }
                        _confirmAndRun(
                          context,
                          ref,
                          title: 'Leave #${currentChannel.name}?',
                          body:
                              'You’ll stop receiving messages from this channel.',
                          confirmLabel: 'Leave',
                          action: () => ref
                              .read(channelActionsProvider)
                              .leaveChannel(channel.id),
                        );
                      },
                    ),
                  if (lifecycleCapabilitiesLoading)
                    const ListTile(
                      enabled: false,
                      leading: BuzzLoadingIndicator(
                        size: 20,
                        semanticLabel: 'Loading channel actions',
                      ),
                      title: Text('Loading channel actions…'),
                    )
                  else if (lifecycleCapabilitiesUnavailable)
                    const ListTile(
                      enabled: false,
                      leading: Icon(LucideIcons.triangleAlert),
                      title: Text('Channel actions unavailable'),
                    )
                  else ...[
                    if (canArchive)
                      _ActionTile(
                        icon: LucideIcons.archive,
                        label: 'Archive channel',
                        onTap: () => _confirmAndRun(
                          context,
                          ref,
                          title: 'Archive #${currentChannel.name}?',
                          body: 'The channel will become read-only.',
                          confirmLabel: 'Archive',
                          action: () => ref
                              .read(channelActionsProvider)
                              .archiveChannel(channel.id),
                        ),
                      ),
                    if (canUnarchive)
                      _ActionTile(
                        icon: LucideIcons.archiveRestore,
                        label: 'Unarchive channel',
                        onTap: () => _confirmAndRun(
                          context,
                          ref,
                          title: 'Unarchive #${currentChannel.name}?',
                          body: 'The channel will become active again.',
                          confirmLabel: 'Unarchive',
                          action: () => ref
                              .read(channelActionsProvider)
                              .unarchiveChannel(channel.id),
                        ),
                      ),
                    if (canDelete)
                      _ActionTile(
                        icon: LucideIcons.trash2,
                        label: 'Delete channel',
                        destructive: true,
                        onTap: () => _confirmAndRun(
                          context,
                          ref,
                          title: 'Delete #${currentChannel.name}?',
                          body:
                              'This permanently deletes the channel and cannot be undone.',
                          confirmLabel: 'Delete',
                          action: () => ref
                              .read(channelActionsProvider)
                              .deleteChannel(channel.id),
                        ),
                      ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChannelQuickActionsRow extends StatelessWidget {
  const _ChannelQuickActionsRow({
    required this.isStarred,
    required this.isUnread,
    required this.onToggleStar,
    required this.onToggleRead,
  });

  final bool isStarred;
  final bool isUnread;
  final VoidCallback onToggleStar;
  final VoidCallback onToggleRead;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: _ChannelQuickAction(
          icon: isStarred ? LucideIcons.starOff : LucideIcons.star,
          label: isStarred ? 'Unstar' : 'Star',
          onTap: onToggleStar,
        ),
      ),
      const SizedBox(width: Grid.twelve),
      Expanded(
        child: _ChannelQuickAction(
          icon: isUnread ? LucideIcons.checkCheck : LucideIcons.circleDot,
          label: isUnread ? 'Mark Read' : 'Mark Unread',
          onTap: onToggleRead,
        ),
      ),
    ],
  );
}

class _ChannelQuickAction extends StatelessWidget {
  const _ChannelQuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () {
      unawaited(HapticFeedback.lightImpact());
      onTap();
    },
    behavior: HitTestBehavior.opaque,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 68 + (Grid.xxs * 2),
          decoration: BoxDecoration(
            color: context.colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.dialog),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 22, color: context.colors.onSurface),
              const SizedBox(height: Grid.xxs),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.labelMedium?.copyWith(
                  color: context.colors.onSurface,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon, color: destructive ? context.colors.error : null),
    title: Text(
      label,
      style: destructive ? TextStyle(color: context.colors.error) : null,
    ),
    onTap: () {
      unawaited(HapticFeedback.lightImpact());
      onTap();
    },
  );
}

Future<void> _confirmAndRun(
  BuildContext sheetContext,
  WidgetRef ref, {
  required String title,
  required String body,
  required String confirmLabel,
  required Future<void> Function() action,
}) async {
  final pageContext = Navigator.of(sheetContext, rootNavigator: true).context;
  final confirmed = await showBuzzDialog<bool>(
    context: pageContext,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  try {
    await action();
    if (pageContext.mounted) Navigator.of(pageContext).pop(true);
  } catch (error) {
    if (!pageContext.mounted) return;
    ScaffoldMessenger.of(pageContext).showSnackBar(
      SnackBar(
        content: Text(
          'Couldn’t ${confirmLabel.toLowerCase()} channel. Try again.',
        ),
      ),
    );
  }
}

Future<void> _showMoveSectionSheet(
  BuildContext context,
  WidgetRef ref, {
  required Channel channel,
  required String? sectionId,
}) async {
  final sections = [...ref.read(channelSectionsProvider).store.sections]
    ..sort((a, b) => a.order.compareTo(b.order));
  await showBuzzModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: IconTheme.merge(
        data: const IconThemeData(size: 22),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            Grid.gutter,
            0,
            Grid.gutter,
            Grid.xs,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final section in sections)
                ListTile(
                  leading: const Icon(LucideIcons.folder),
                  title: Text(section.name),
                  trailing: sectionId == section.id
                      ? Icon(
                          LucideIcons.check,
                          color: sheetContext.colors.primary,
                        )
                      : null,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    ref
                        .read(channelSectionsProvider.notifier)
                        .assignChannel(channel.id, section.id);
                  },
                ),
              ListTile(
                leading: const Icon(LucideIcons.folderPlus),
                title: const Text('New section…'),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  final name = await _showSectionNameDialog(context);
                  if (name == null || name.isEmpty) return;
                  final notifier = ref.read(channelSectionsProvider.notifier);
                  notifier.createSection(name);
                  final created = ref
                      .read(channelSectionsProvider)
                      .store
                      .sections
                      .where((section) => section.name == name.trim())
                      .lastOrNull;
                  if (created != null) {
                    notifier.assignChannel(channel.id, created.id);
                  }
                },
              ),
              if (sectionId != null)
                ListTile(
                  leading: const Icon(LucideIcons.folderMinus),
                  title: const Text('Remove from section'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    ref
                        .read(channelSectionsProvider.notifier)
                        .unassignChannel(channel.id);
                  },
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<String?> _showSectionNameDialog(BuildContext context) async {
  final controller = TextEditingController();
  final result = await showBuzzDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('New Section'),
      content: TextField(controller: controller, autofocus: true),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(controller.text.trim()),
          child: const Text('Create'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}
