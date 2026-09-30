// MODIFIED FOR RAIJU: original Community card and appearance controls remain;
// the Buzz invite action is visible but explicitly unavailable.
part of '../settings_page.dart';

class _CommunitySection extends ConsumerWidget {
  const _CommunitySection({this.invitePageBuilder});

  /// Retained for source compatibility. Buzz invitation routes are inactive.
  final WidgetBuilder? invitePageBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preference = ref.watch(communityThemeProvider);
    final accentIndex =
        accentIndexForWireValue(preference.accent) ?? defaultAccentIndex;

    return AppListCard(
      label: 'Community',
      verticalPadding: Grid.twelve,
      children: [
        const AppListRow(
          key: ValueKey('community-invites-unavailable'),
          icon: LucideIcons.userPlus,
          title: 'Invite to community',
          subtitle: 'Unavailable in Raiju; OMP links connect chats directly',
        ),
        AppListRow(
          key: const ValueKey('community-theme-row'),
          icon: LucideIcons.palette,
          title: 'Theme',
          value: themeSelectionLabel(preference.theme, preference.mode),
          trailing: const _RowChevron(),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ThemePickerPage()),
          ),
        ),
        AppListRow(
          key: const ValueKey('community-accent-row'),
          icon: LucideIcons.paintbrush,
          title: 'Accent color',
          value: accentColors[accentIndex].name,
          trailing: const _RowChevron(),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const AccentPickerPage()),
          ),
        ),
      ],
    );
  }
}
