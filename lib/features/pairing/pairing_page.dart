// MODIFIED FOR RAIJU: the original scanner and onboarding visuals now join
// encrypted OMP chats; Buzz account recovery and SAS are not active paths.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../shared/theme/theme.dart';
import '../../shared/widgets/buzz_loading_indicator.dart';
import '../../shared/widgets/ios_glass_navigation_button.dart';
import '../../shared/widgets/tappable_flapping_bee.dart';
import '../channels/channel_detail_page.dart';
import '../channels/channels_provider.dart';
import 'pairing_provider.dart';
import 'pairing_qr_scanner.dart';

part 'pairing_page/onboarding_background.dart';
part 'pairing_page/pairing_welcome_view.dart';

const _onboardingChartreuse = Color(0xFFD7D72E);
const _onboardingShellBottom = Color(0xFFD7E7F6);
const _onboardingCtaLabel = Color(0xFFD7E6F0);
const _onboardingInk = Color(0xFF111111);
const _onboardingMutedInk = Color(0xB3111111);
// Retained original onboarding error color with the dormant Buzz error view.
// ignore: unused_element
const _onboardingErrorInk = Color(0xFF7A1025);

class PairingPage extends HookConsumerWidget {
  /// When true, this user-opened page connects another saved OMP chat.
  final bool addingCommunity;
  final bool identityRecoveryOnly;

  /// Test/platform seam. Production leaves this null to use the original
  /// Dynamic Island portal and fallback camera scanner.
  final Future<String?> Function(BuildContext context)? scannerLauncher;

  const PairingPage({
    super.key,
    this.addingCommunity = false,
    this.identityRecoveryOnly = false,
    this.scannerLauncher,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairingState = ref.watch(pairingProvider);
    final codeController = useTextEditingController();
    final fallbackScannerVisible = useState(false);
    final pairingCodeExpanded = useState(false);
    final isBusy =
        pairingState.status == PairingStatus.connecting ||
        pairingState.status == PairingStatus.transferring ||
        pairingState.status == PairingStatus.storing;

    // A successful join replaces this route with the original Buzz chat
    // detail surface, so Back returns to the chat list rather than Connect.
    if (pairingState.status == PairingStatus.success &&
        pairingState.joinedChat != null) {
      final joinedChat = pairingState.joinedChat!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ref.read(pairingProvider.notifier).reset();
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) =>
                ChannelDetailPage(channel: channelFromChatThread(joinedChat)),
          ),
        );
      });
    }

    Future<void> handleScannerResult(String? code) async {
      if (code != null && context.mounted) {
        // Scanner and pasted text intentionally share PairingNotifier.pair.
        await ref.read(pairingProvider.notifier).pair(code);
      }
    }

    Future<void> openScanner() async {
      if (scannerLauncher != null) {
        await handleScannerResult(await scannerLauncher!(context));
        return;
      }
      final usesDynamicIslandPortal = await usesDynamicIslandQrScannerPortal();
      if (!context.mounted) {
        return;
      }

      if (!usesDynamicIslandPortal) {
        fallbackScannerVisible.value = true;
        return;
      }

      final code = await showDynamicIslandPairingQrScanner(context);
      await handleScannerResult(code);
    }

    final onboardingSystemOverlayStyle = SystemUiOverlayStyle.dark.copyWith(
      statusBarColor: Colors.transparent,
    );
    final pairingAppBar = addingCommunity
        ? AppBar(
            foregroundColor: _onboardingInk,
            systemOverlayStyle: onboardingSystemOverlayStyle,
            leadingWidth: Theme.of(context).platform == TargetPlatform.iOS
                ? Grid.quarter + iosGlassChannelHeaderLeadingWidth
                : null,
            leading: Theme.of(context).platform == TargetPlatform.iOS
                ? Padding(
                    padding: const EdgeInsets.only(left: Grid.quarter),
                    child: IosGlassNavigationButton(
                      key: const ValueKey('pairing-ios-glass-back'),
                      icon: IosGlassNavigationIcon.back,
                      semanticLabel: 'Back',
                      onPressed: () => Navigator.of(context).maybePop(),
                      width: iosGlassChannelHeaderLeadingWidth,
                      buttonCenterX: iosGlassChannelHeaderButtonCenterX,
                      foregroundColor: _onboardingInk,
                    ),
                  )
                : IconButton(
                    icon: const Icon(LucideIcons.arrowLeft),
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
            title: Text(
              'Connect OMP Chat',
              style: context.textTheme.titleMedium?.copyWith(
                color: _onboardingInk,
              ),
            ),
          )
        : null;

    final pairingScaffold = AnnotatedRegion<SystemUiOverlayStyle>(
      key: const Key('pairing-onboarding-system-overlay'),
      value: onboardingSystemOverlayStyle,
      child: _OnboardingBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: pairingAppBar,
          body: SafeArea(
            child: _PairingWelcomeView(
              codeController: codeController,
              isBusy: isBusy,
              pairingCodeExpanded: pairingCodeExpanded.value,
              errorMessage: pairingState.status == PairingStatus.error
                  ? pairingState.errorMessage
                  : null,
              onScan: openScanner,
              onTogglePairingCode: () {
                pairingCodeExpanded.value = !pairingCodeExpanded.value;
              },
              onConnect: () {
                final input = codeController.text;
                codeController.clear();
                unawaited(handleScannerResult(input));
              },
            ),
          ),
        ),
      ),
    );

    final appSurface = PopScope(
      key: const Key('pairing-pop-scope'),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          ref.read(pairingProvider.notifier).reset();
        }
      },
      child: pairingScaffold,
    );

    if (!fallbackScannerVisible.value) {
      return appSurface;
    }

    return FallbackPairingQrScanner(
      appSurface: appSurface,
      onClosed: (code) {
        fallbackScannerVisible.value = false;
        unawaited(handleScannerResult(code));
      },
    );
  }
}
