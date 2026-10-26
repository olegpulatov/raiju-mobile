// Modified for Raiju: keep local appearance and avatar preferences in Interface;
// obsolete community invitation controls are removed.
part of '../settings_page.dart';

class _InterfaceSection extends ConsumerWidget {
  const _InterfaceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preference = ref.watch(communityThemeProvider);
    final showAvatars = ref.watch(showChatAvatarsProvider);
    final accentIndex =
        accentIndexForWireValue(preference.accent) ?? defaultAccentIndex;

    return AppListCard(
      label: 'Interface',
      verticalPadding: Grid.twelve,
      children: [
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
          key: const ValueKey('settings-appearance'),
          icon: LucideIcons.sunMoon,
          title: 'Appearance',
          value: appearanceModeLabel(preference.mode),
          trailing: const _RowChevron(),
          onTap: () => unawaited(
            showAppearanceModePickerSheet(
              context: context,
              selectedMode: preference.mode,
              onSelected: ref.read(communityThemeProvider.notifier).setMode,
            ),
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
        AppListRow(
          key: const ValueKey('settings-chat-avatars'),
          icon: LucideIcons.userRound,
          title: 'Show avatars in chats',
          trailing: Switch.adaptive(
            value: showAvatars,
            onChanged: (value) => unawaited(
              ref.read(showChatAvatarsProvider.notifier).setVisible(value),
            ),
          ),
          onTap: () => unawaited(
            ref.read(showChatAvatarsProvider.notifier).setVisible(!showAvatars),
          ),
        ),
        const _NotificationsSection(),
      ],
    );
  }
}
