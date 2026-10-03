// MODIFIED FOR RAIJU: Buzz push registration is inactive, but its settings
// surface remains visible and explains the unavailable state.
part of '../settings_page.dart';

class _NotificationsSection extends StatelessWidget {
  const _NotificationsSection();

  @override
  Widget build(BuildContext context) {
    return const AppListRow(
      key: ValueKey('push-notifications-unavailable'),
      icon: LucideIcons.bell,
      title: 'Push notifications',
      subtitle: 'Unavailable yet',
    );
  }
}
