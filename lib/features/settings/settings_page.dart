// MODIFIED FOR RAIJU: this keeps the original frosted settings shell and
// appearance pickers while replacing Buzz backend actions with OMP controls
// and adding offline third-party licenses to the existing settings list.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../harness/collab_link.dart';
import '../../raiju/collab_relay_preference.dart';
import '../../spark/spark.dart';
import '../pairing/ompd_pairing_page.dart';
import '../pairing/pairing_page.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/app_list.dart';
import '../../shared/widgets/app_list_card.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/frosted_scaffold.dart';
import '../../shared/widgets/ios_glass_navigation_button.dart';
import '../../shared/widgets/ios_glass_navigation_action.dart';
import '../../shared/widgets/immediate_page_route.dart';
import '../../shared/widgets/modal_presentation.dart';
import 'accent_picker_page.dart';
import 'theme_picker_page.dart';
import 'theme_option_sheets.dart';

part 'settings_page/community_section.dart';
part 'settings_page/connection_section.dart';
part 'settings_page/notifications_section.dart';
part 'settings_page/spark_section.dart';

enum _ProfileEditAction { displayName, description, photo }

class SettingsPage extends HookConsumerWidget {
  /// Creates the settings page.
  const SettingsPage({
    super.key,
    required this.profileHeader,
    this.invitePageBuilder,
    this.identityRecoveryPageBuilder,
    this.profileEditPageBuilder,
    this.onEditDisplayName,
    this.onEditProfileDescription,
  });

  /// Header widget displayed at the top of settings.
  final Widget profileHeader;

  final WidgetBuilder? invitePageBuilder;

  /// Retained for source compatibility; Buzz recovery is inactive.
  final WidgetBuilder? identityRecoveryPageBuilder;

  /// Optional legacy profile editor. Raiju does not require an account.
  final WidgetBuilder? profileEditPageBuilder;

  /// Opens the display-name editor after the Edit Profile sheet closes.
  final Future<void> Function(BuildContext context)? onEditDisplayName;

  /// Opens the profile-description editor after the Edit Profile sheet closes.
  final Future<void> Function(BuildContext context)? onEditProfileDescription;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final packageInfoFuture = useMemoized(() => PackageInfo.fromPlatform());
    final packageInfo = useFuture(packageInfoFuture);
    final topSectionHeight = frostedAppBarHeight(
      context,
      bottomHeight: Grid.xxs,
    );

    Future<void> showEditProfileSheet() async {
      if (profileEditPageBuilder == null &&
          onEditDisplayName == null &&
          onEditProfileDescription == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Unavailable yet')));
        return;
      }
      final action = await showBuzzModalBottomSheet<_ProfileEditAction>(
        context: context,
        title: 'Edit profile',
        builder: (sheetContext) => SafeArea(
          top: false,
          child: Padding(
            key: const ValueKey('edit-profile-sheet-content'),
            padding: const EdgeInsets.only(bottom: Grid.xs),
            // AppListCard normally fills the height offered by a page section.
            // Give it unbounded vertical space here so this compact action sheet
            // hugs its three rows instead of filling the modal height cap.
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppListCard(
                  key: const ValueKey('edit-profile-options'),
                  dividerIndent: Grid.xs,
                  verticalPadding: 0,
                  children: [
                    AppListRow(
                      key: const ValueKey('edit-profile-display-name'),
                      title: 'Display name',
                      trailing: const _RowChevron(),
                      onTap: () => Navigator.pop(
                        sheetContext,
                        _ProfileEditAction.displayName,
                      ),
                    ),
                    AppListRow(
                      key: const ValueKey('edit-profile-description'),
                      title: 'Profile description',
                      trailing: const _RowChevron(),
                      onTap: () => Navigator.pop(
                        sheetContext,
                        _ProfileEditAction.description,
                      ),
                    ),
                    AppListRow(
                      key: const ValueKey('edit-profile-photo'),
                      title: 'Photo',
                      trailing: const _RowChevron(),
                      onTap: () =>
                          Navigator.pop(sheetContext, _ProfileEditAction.photo),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      if (!context.mounted || action == null) return;
      unawaited(HapticFeedback.selectionClick());
      switch (action) {
        case _ProfileEditAction.displayName:
          if (onEditDisplayName != null) {
            await onEditDisplayName!(context);
          } else if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Unavailable yet')));
          }
          break;
        case _ProfileEditAction.description:
          if (onEditProfileDescription != null) {
            await onEditProfileDescription!(context);
          } else if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Unavailable yet')));
          }
          break;
        case _ProfileEditAction.photo:
          if (profileEditPageBuilder != null) {
            await Navigator.of(
              context,
            ).push(immediatePageRoute<void>(builder: profileEditPageBuilder!));
          } else if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Unavailable yet')));
          }
          break;
      }
    }

    return FrostedScaffold(
      useUtilitySurfaceTheme: true,
      appBar: FrostedAppBar(
        automaticallyImplyLeading: false,
        horizontalInset: Grid.gutter,
        showBottomDivider: false,
        leading: Theme.of(context).platform == TargetPlatform.iOS
            ? IosGlassNavigationButton(
                key: const ValueKey('settings-ios-glass-close'),
                icon: IosGlassNavigationIcon.close,
                semanticLabel: 'Close settings',
                onPressed: () {
                  unawaited(HapticFeedback.lightImpact());
                  Navigator.of(context).pop();
                },
                foregroundColor: navigationPrimaryForeground(context),
              )
            : SizedBox(
                width: Grid.xl,
                height: Grid.xl,
                child: IconButton(
                  tooltip: 'Close settings',
                  onPressed: () {
                    unawaited(HapticFeedback.lightImpact());
                    Navigator.of(context).pop();
                  },
                  color: navigationPrimaryForeground(context),
                  icon: const Icon(LucideIcons.x),
                ),
              ),
        actions: [
          if (Theme.of(context).platform == TargetPlatform.iOS)
            IosGlassNavigationAction(
              key: const ValueKey('settings-edit-profile'),
              label: 'Edit',
              foregroundColor: navigationPrimaryForeground(context),
              onPressed: () => unawaited(showEditProfileSheet()),
            )
          else
            Material(
              key: const ValueKey('settings-edit-profile'),
              color: context.colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.full),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => unawaited(showEditProfileSheet()),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Grid.xs,
                    vertical: Grid.xxs,
                  ),
                  child: Text(
                    'Edit',
                    style: context.textTheme.labelLarge?.copyWith(
                      color: context.colors.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
        bottomHeight: Grid.xxs,
        bottom: const SizedBox.expand(),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: EdgeInsets.only(top: topSectionHeight, bottom: Grid.xs),
              children: [
                profileHeader,
                const _SparkSection(),
                const _ConnectionSection(),
                const _InterfaceSection(),
                AppListCard(
                  verticalPadding: Grid.twelve,
                  children: [
                    AppListRow(
                      key: const ValueKey('settings-licenses'),
                      icon: LucideIcons.scale,
                      title: 'Policy',
                      trailing: const _RowChevron(),
                      onTap: () => showLicensePage(
                        context: context,
                        applicationName: 'Raiju',
                        applicationVersion: packageInfo.hasData
                            ? 'v${packageInfo.data!.version}'
                            : null,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (packageInfo.hasData)
            _VersionFooter(
              version: packageInfo.data!.version,
              buildNumber: packageInfo.data!.buildNumber,
            ),
        ],
      ),
    );
  }
}

const _sourceCommit = String.fromEnvironment(
  'RAIJU_SOURCE_COMMIT',
  defaultValue: 'unavailable',
);
const _buildStarted = String.fromEnvironment(
  'RAIJU_BUILD_STARTED',
  defaultValue: 'unavailable',
);

class _VersionFooter extends StatelessWidget {
  const _VersionFooter({required this.version, required this.buildNumber});

  final String version;
  final String buildNumber;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: Grid.xs, top: Grid.xxs),
        child: Center(
          child: Text(
            '${buildNumber.isEmpty ? 'v$version' : 'v$version ($buildNumber)'}'
            '\nSource: $_sourceCommit · Built: $_buildStarted',
            textAlign: TextAlign.center,
            style: context.textTheme.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }
}

/// Trailing affordance shared by the rows that push a picker page.
class _RowChevron extends StatelessWidget {
  const _RowChevron();

  @override
  Widget build(BuildContext context) {
    return Icon(
      LucideIcons.chevronRight,
      size: 18,
      color: context.colors.onSurfaceVariant,
    );
  }
}
