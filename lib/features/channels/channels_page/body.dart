// MODIFIED FOR RAIJU: empty/list content keeps Buzz slivers and refresh
// treatment while exposing OMP connection as the real primary action.
part of '../channels_page.dart';

class _ChannelsBody extends StatelessWidget {
  final List<Channel>? channels;
  final AsyncValue<List<Channel>> channelsAsync;
  final String? storageError;
  final bool showError;
  final SessionStatus sessionStatus;
  final bool showConnectionSkeleton;
  final String? currentPubkey;
  final double topSectionHeight;
  final bool usesPinnedGradient;
  final ScrollController scrollController;
  final Future<void> Function() onRefresh;
  final Future<void> Function(Channel channel) onSelectChannel;
  final VoidCallback onConnect;

  const _ChannelsBody({
    required this.channels,
    required this.channelsAsync,
    required this.storageError,
    required this.showError,
    required this.sessionStatus,
    required this.showConnectionSkeleton,
    required this.currentPubkey,
    required this.topSectionHeight,
    required this.usesPinnedGradient,
    required this.scrollController,
    required this.onRefresh,
    required this.onSelectChannel,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    final barHeight = topSectionHeight;
    final loadedChannels = channels;
    final loading =
        showConnectionSkeleton || (loadedChannels == null && !showError);
    final content = showError && channelsAsync.hasError
        ? Padding(
            padding: EdgeInsets.only(top: barHeight),
            child: _ErrorView(error: channelsAsync.error!, onRetry: onRefresh),
          )
        : loadedChannels == null
        ? const SizedBox.shrink()
        : BeeRefreshIndicator(
            edgeOffset: barHeight,
            onRefresh: onRefresh,
            child: CustomScrollView(
              controller: scrollController,
              // Transparent list gaps must remain hit-testable so a new drag
              // can interrupt ballistic scrolling. The app bar is painted
              // later and retains its community and profile controls.
              hitTestBehavior: HitTestBehavior.translucent,
              slivers: [
                SliverToBoxAdapter(child: SizedBox(height: barHeight)),
                if (storageError != null && loadedChannels.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _InlineStorageError(error: storageError!),
                  ),
                if (usesPinnedGradient)
                  _SliverChannelsList(
                    channels: loadedChannels,
                    currentPubkey: currentPubkey,
                    onSelectChannel: onSelectChannel,
                    onConnect: onConnect,
                  )
                else
                  DecoratedSliver(
                    decoration: BoxDecoration(
                      color: context.colors.surface,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(Radii.dialog),
                      ),
                    ),
                    sliver: _SliverChannelsList(
                      channels: loadedChannels,
                      currentPubkey: currentPubkey,
                      onSelectChannel: onSelectChannel,
                      onConnect: onConnect,
                    ),
                  ),
              ],
            ),
          );

    return SkeletonReveal(
      loading: loading,
      shimmerEnabled: sessionStatus != SessionStatus.disconnected,
      skeleton: _ChannelsSkeleton(
        channels: loadedChannels,
        topInset: barHeight,
        status: sessionStatus,
      ),
      content: content,
    );
  }
}

class _InlineStorageError extends StatelessWidget {
  const _InlineStorageError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _kChannelSectionInset,
        Grid.xxs,
        _kChannelSectionInset,
        Grid.xs,
      ),
      child: Material(
        color: context.colors.errorContainer,
        borderRadius: BorderRadius.circular(Radii.md),
        child: Padding(
          padding: const EdgeInsets.all(Grid.xs),
          child: Text(
            error.toString().replaceFirst('Bad state: ', ''),
            style: context.textTheme.bodyMedium?.copyWith(
              color: context.colors.onErrorContainer,
            ),
          ),
        ),
      ),
    );
  }
}

class _SliverChannelsList extends HookConsumerWidget {
  final List<Channel> channels;
  final String? currentPubkey;
  final Future<void> Function(Channel channel) onSelectChannel;
  final VoidCallback onConnect;

  const _SliverChannelsList({
    required this.channels,
    required this.currentPubkey,
    required this.onSelectChannel,
    required this.onConnect,
  });
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visibleChannels = channels
        .where((channel) => channel.isMember && !channel.isArchived)
        .toList(growable: false);
    final dmChannels = sortDmChannelsByDisplayLabel(
      visibleChannels.where((channel) => channel.isDm),
      currentPubkey: currentPubkey,
    );
    final dmsExpanded = useState(true);
    final channelsExpanded = useState(true);
    final sortMode = useState(ChannelSortMode.recent);
    final sortedDmChannels = sortMode.value == ChannelSortMode.recent
        ? sortChannelsForList(dmChannels, ChannelSortMode.recent)
        : dmChannels;

    return SliverPadding(
      padding: EdgeInsets.only(
        top: Grid.xxs,
        bottom: MediaQuery.paddingOf(context).bottom,
      ),
      sliver: SliverList.list(
        children: [
          if (visibleChannels.isEmpty)
            _EmptyState(onConnect: onConnect)
          else ...[
            _ChannelSection(
              title: 'Channels',
              icon: LucideIcons.hash,
              showTopDivider: false,
              expanded: channelsExpanded.value,
              onToggle: () =>
                  channelsExpanded.value = !channelsExpanded.value,
              channels: const [],
              unreadChannelIds: const {},
              mutedChannelIds: const {},
              currentPubkey: currentPubkey,
              emptyLabel: 'OMP sessions appear in Direct messages',
              onSelectChannel: onSelectChannel,
            ),
            _ChannelSection(
              title: 'DMs',
              icon: LucideIcons.messagesSquare,
              showTopDivider: true,
              expanded: dmsExpanded.value,
              onToggle: () => dmsExpanded.value = !dmsExpanded.value,
              channels: sortedDmChannels,
              unreadChannelIds: const {},
              mutedChannelIds: const {},
              currentPubkey: currentPubkey,
              emptyLabel: 'No companion chats yet',
              sortMode: sortMode.value,
              onSortModeChange: (value) => sortMode.value = value,
              onSelectChannel: onSelectChannel,
            ),
          ],
        ],
      ),
    );
  }
}
