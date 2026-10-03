// MODIFIED FOR RAIJU: preserves Buzz's home/list geometry while active data and
// navigation come only from local OMP companion sessions.
import 'dart:async';
import 'dart:io';
import 'dart:math' show max, min, pi;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter/physics.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/auth/auth.dart';
import '../../shared/community/community_icon_provider.dart';
import '../../shared/relay/relay.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/avatar_image.dart';
import '../../shared/widgets/anchored_popover_menu.dart';
import '../../shared/widgets/bee_refresh_indicator.dart';
import '../../shared/widgets/buzz_loading_indicator.dart';
import '../../shared/widgets/buzz_titled_sheet_layout.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/frosted_scaffold.dart';
import '../../shared/widgets/modal_presentation.dart';
import '../../shared/widgets/skeleton.dart';
import '../../shared/widgets/raiju_logo.dart';
import '../../shared/custom_emoji/custom_emoji.dart';
import '../../shared/custom_emoji/custom_emoji_provider.dart';
import '../../shared/custom_emoji/custom_emoji_render.dart';
import '../profile/profile_avatar.dart';
import '../../harness/harness.dart';
import '../../companion_controller.dart' show ChatThread;
import '../../raiju/companion_provider.dart';
import '../../raiju/connection_status_provider.dart';
import '../pairing/pairing_page.dart';
import '../pairing/ompd_pairing_page.dart';
import '../pairing/pairing_provider.dart';
import 'channel.dart';
import 'channel_actions_sheet.dart';
import 'channel_detail_page.dart';
import 'channel_management_provider.dart';
import 'dm_channel_labels.dart';
import 'ephemeral_channel_display.dart';
import 'channel_sections/channel_sections_storage.dart';
import 'channel_sort/channel_sort_storage.dart';
import 'channels_provider.dart';

part 'channels_page/body.dart';
part 'channels_page/browse_channels_sheet.dart';
part 'channels_page/sections.dart';
part 'channels_page/channel_tile.dart';
part 'channels_page/sheets.dart';
part 'channels_page/badges.dart';
part 'channels_page/skeleton.dart';
part 'channels_page/community.dart';
part 'channels_page/quick_actions.dart';
part 'channels_page/quick_actions_launcher.dart';

enum _QuickAction { attachCollab, addRemoteSession, browseRelay }

const double _kChannelSectionInset = Grid.gutter;
const double _kChannelLeadingWidth = 22.0;
const double _kChannelIconSize = 18.0;
const double _kChannelLabelGap = Grid.xxs;
const double _kChannelRowVerticalPadding = Grid.xxs + Grid.quarter;
const double _kSectionSpacingTightening = Grid.half;
const double _kSectionHeaderVerticalPadding =
    _kChannelRowVerticalPadding - _kSectionSpacingTightening;
// Section headers include touch targets for their actions, so their visual
// centre sits lower than a channel row's. This keeps an expanded section's
// final row equally spaced from the following divider.
const double _kExpandedSectionTrailingPadding =
    11.0 - _kSectionSpacingTightening;
const double _kChannelLabelInset =
    _kChannelSectionInset + _kChannelLeadingWidth + _kChannelLabelGap;

/// DM avatars are circles, so they fill their box edge to edge where a channel
/// glyph leaves 4dp of slack inside the same 22dp leading column. Sizing them to
/// the glyph's ink width keeps the icon-to-label distance identical across both
/// sections while the labels stay on [_kChannelLabelInset].
const double _kDmAvatarSize = _kChannelIconSize;

const double _kTopSectionCommunityAvatarSize = 40.0;
const double _kTopSectionProfileAvatarSize = 36.0;
const double _kTopSectionBottomPadding = Grid.xxs;

/// The top section's avatars are 40dp circles, which fill their box edge to
/// edge; the channel rows below lead with an 18dp glyph left-aligned in a 22dp
/// box at [_kChannelSectionInset]. Edge-aligning the two leaves the circles
/// looking pushed outward, so the bar is pulled in to sit the avatar's centre
/// near the channel-icon column.
const double _kTopSectionInset = Grid.twelve;
const Duration _kSectionExpandDuration = Duration(milliseconds: 220);
const Duration _kSectionCollapseDuration = Duration(milliseconds: 170);
const Curve _kSectionExpandCurve = Cubic(0.23, 1, 0.32, 1);
const Curve _kSectionCollapseCurve = Curves.easeInCubic;
const double _kSectionCollapsedScaleY = 0.98;
const double _kHeaderFrostScrollDistance = Grid.xxl;
const double _kHeaderFrostMaxBlurSigma = 23.12;

class ChannelsPage extends HookConsumerWidget {
  const ChannelsPage({
    required this.settingsPageBuilder,
    required this.onSettingsTransitionProgress,
    this.tabReselection,
    super.key,
  });

  final WidgetBuilder settingsPageBuilder;

  /// Reports Settings route progress so its foreground and Home's background
  /// render from the same timeline.
  final ValueChanged<double> onSettingsTransitionProgress;

  /// Notifies this page when its already-selected tab is tapped again.
  final ValueListenable<int>? tabReselection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channelsAsync = ref.watch(channelsProvider);
    final storageError = ref.watch(companionControllerProvider).storageError;
    const currentPubkey = localChannelParticipantId;
    final headerTitleStyle = context.textTheme.titleMedium?.copyWith(
      fontSize: 22,
      fontWeight: FontWeight.w600,
      color: navigationPrimaryForeground(context),
    );
    final topSectionHeight = frostedAppBarHeight(
      context,
      titleStyle: headerTitleStyle,
      bottomHeight: _kTopSectionBottomPadding,
    );
    final channelsScrollController = useScrollController();
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final headerFrostProgress = useState(0.0);
    useEffect(() {
      void updateHeaderTreatment() {
        final nextProgress = !channelsScrollController.hasClients
            ? 0.0
            : (channelsScrollController.offset / _kHeaderFrostScrollDistance)
                  .clamp(0.0, 1.0)
                  .toDouble();
        if ((headerFrostProgress.value - nextProgress).abs() > 0.001) {
          headerFrostProgress.value = nextProgress;
        }
      }

      channelsScrollController.addListener(updateHeaderTreatment);
      return () =>
          channelsScrollController.removeListener(updateHeaderTreatment);
    }, [channelsScrollController]);
    useEffect(() {
      final tabReselection = this.tabReselection;
      if (tabReselection == null) return null;

      void scrollToTop() {
        if (!channelsScrollController.hasClients) return;
        final position = channelsScrollController.position;
        if (position.pixels <= position.minScrollExtent + 0.5) return;
        if (reducedMotion) {
          channelsScrollController.jumpTo(position.minScrollExtent);
          return;
        }
        unawaited(
          channelsScrollController.animateTo(
            position.minScrollExtent,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          ),
        );
      }

      tabReselection.addListener(scrollToTop);
      return () => tabReselection.removeListener(scrollToTop);
    }, [tabReselection, channelsScrollController, reducedMotion]);

    // Cache the last successfully projected OMP chat list so controller
    // notifications never flash already-restored conversations.
    final cachedChannels = useRef<List<Channel>?>(null);
    if (channelsAsync.asData?.value case final data?) {
      cachedChannels.value = data;
    }
    final channels = cachedChannels.value;
    Future<void> openChannel(Channel channel) async {
      if (!context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChannelDetailPage(channel: channel),
        ),
      );
    }

    Future<void> openPairing() async {
      if (!context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const PairingPage(addingCommunity: true),
        ),
      );
    }

    final showError = useState(false);
    final hasError =
        channelsAsync.hasError && (channels == null || channels.isEmpty);
    useEffect(() {
      showError.value = hasError;
      return null;
    }, [hasError]);

    // Companion reconnect state is rendered inside each real chat. The list
    // itself remains stable and never watches the retained Buzz relay session.
    const showConnectionSkeleton = false;
    final topSectionGradient = context.appColors.topSectionGradient;
    final usesPinnedGradient = topSectionGradient != null;

    return FrostedScaffold(
      backgroundColor: usesPinnedGradient
          ? Colors.transparent
          : context.colors.surface,
      backgroundGradient: topSectionGradient,
      appBar: FrostedAppBar(
        horizontalInset: _kTopSectionInset,
        // Let the full Buzz gradient show at rest. Once the list begins to
        // move beneath this row, build up blur over the first 64dp of scroll
        // without adding the usual white frosted wash. The Buzz list is
        // transparent, so the blurred pixels remain a continuation of the
        // pinned gradient instead of turning into a white header.
        frosted: !usesPinnedGradient || headerFrostProgress.value > 0,
        frostedSurfaceOpacity: usesPinnedGradient ? 0 : 0.5,
        frostedBlurSigma: usesPinnedGradient
            ? _kHeaderFrostMaxBlurSigma * headerFrostProgress.value
            : 20,
        showBottomDivider: false,
        leading: const _CommunityIndicator(),
        centerTitle: false,
        titleStyle: headerTitleStyle,
        title: _CommunityHeaderTitle(
          style: headerTitleStyle,
          onTap: openPairing,
        ),
        actions: [
          SizedBox(
            width: Grid.xl,
            height: Grid.xl,
            child: Center(
              child: ProfileAvatar(
                size: _kTopSectionProfileAvatarSize,
                showPresence: false,
                localMode: true,
                localLabel: 'R',
                onTap: () {
                  unawaited(HapticFeedback.lightImpact());
                  final route = _SettingsPageRoute(
                    builder: settingsPageBuilder,
                    onTransitionProgress: onSettingsTransitionProgress,
                  );
                  Navigator.of(context).push(route);
                },
              ),
            ),
          ),
        ],
        bottomHeight: _kTopSectionBottomPadding,
        bottom: const SizedBox.expand(),
      ),
      body: _ChannelsBody(
        channels: channels,
        channelsAsync: channelsAsync,
        storageError: storageError,
        showError: showError.value,
        sessionStatus: SessionStatus.disconnected,
        showConnectionSkeleton: showConnectionSkeleton,
        currentPubkey: currentPubkey,
        topSectionHeight: topSectionHeight,
        usesPinnedGradient: usesPinnedGradient,
        scrollController: channelsScrollController,
        onRefresh: () => ref.read(channelsProvider.notifier).refresh(),
        onSelectChannel: openChannel,
        onConnect: openPairing,
      ),
    );
  }
}

/// A custom route deliberately avoids [MaterialPageRoute]'s platform exit
/// transition on Home. Settings has a centered scale-and-fade transition, not
/// a lateral page push.
class _SettingsPageRoute extends PageRouteBuilder<void> {
  _SettingsPageRoute({
    required WidgetBuilder builder,
    required this.onTransitionProgress,
  }) : super(
         pageBuilder: (context, animation, secondaryAnimation) =>
             builder(context),
         transitionsBuilder: _buildSettingsTransition,
         opaque: false,
         allowSnapshotting: false,
         transitionDuration: const Duration(milliseconds: 150),
         reverseTransitionDuration: const Duration(milliseconds: 150),
       );

  final ValueChanged<double> onTransitionProgress;

  Animation<double>? _progressAnimation;
  bool _hasStartedForwardTransition = false;

  @override
  void install() {
    super.install();
    _progressAnimation = animation?..addListener(_reportProgress);
  }

  void _reportProgress() {
    final progressAnimation = _progressAnimation;
    if (progressAnimation == null) return;

    // ProxyAnimation briefly exposes the previous completed value while the
    // route installs its new controller. Ignore that handoff notification and
    // begin reporting only once the route is genuinely moving forward.
    if (!_hasStartedForwardTransition) {
      if (progressAnimation.status != AnimationStatus.forward) return;
      _hasStartedForwardTransition = true;
    }
    onTransitionProgress(progressAnimation.value);
  }

  @override
  void dispose() {
    _progressAnimation?.removeListener(_reportProgress);
    super.dispose();
  }

  static Widget _buildSettingsTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;

    final motion = CurvedAnimation(
      parent: animation,
      // Keep the complete page on one timeline. A gentler forward ease keeps
      // the entrance visible without letting scale finish ahead of opacity;
      // the existing reverse curve preserves the exit motion.
      curve: Curves.easeOutQuad,
      reverseCurve: Curves.easeOutCubic,
    );
    return FadeTransition(
      key: const ValueKey('settings-transition-opacity'),
      opacity: motion,
      child: RepaintBoundary(
        key: const ValueKey('settings-transition-layer'),
        child: ScaleTransition(
          key: const ValueKey('settings-transition-scale'),
          scale: Tween<double>(begin: 1.04, end: 1).animate(motion),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }
}
