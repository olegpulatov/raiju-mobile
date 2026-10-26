// MODIFIED FOR RAIJU: obsolete identity/invite controls are removed; retain
// profile editing, appearance/avatar preferences, push placeholder and metadata.
import 'package:raiju_mobile/features/settings/settings_page.dart';
import 'package:raiju_mobile/raiju/chat_avatar_preference.dart';
import 'package:raiju_mobile/shared/community/community_membership_provider.dart';
import 'package:raiju_mobile/shared/community/community.dart';
import 'package:raiju_mobile/shared/community/community_provider.dart';
import 'package:raiju_mobile/shared/theme/theme.dart';
import 'package:raiju_mobile/shared/relay/app_lifecycle_provider.dart';
import 'package:raiju_mobile/shared/widgets/app_list.dart';
import 'package:raiju_mobile/shared/widgets/app_list_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Buzz',
      packageName: 'xyz.block.buzz',
      version: '0.16.0',
      buildNumber: '432',
      buildSignature: '',
    );
  });

  for (final buildNumber in ['432', '', '2147483647']) {
    testWidgets('shows version with build number "$buildNumber"', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      PackageInfo.setMockInitialValues(
        appName: 'Buzz',
        packageName: 'xyz.block.buzz',
        version: '0.16.0',
        buildNumber: buildNumber,
        buildSignature: '',
      );
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            savedPrefsProvider.overrideWithValue(prefs),
            currentCommunityRoleProvider.overrideWithValue(
              const AsyncData<CommunityMemberRole?>(CommunityMemberRole.admin),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: SettingsPage(
              profileHeader: const SizedBox.shrink(),
              invitePageBuilder: (_) => const SizedBox.shrink(),
              identityRecoveryPageBuilder: (_) => const SizedBox.shrink(),
            ),
          ),
        ),
      );
      expect(find.text('Invite to community'), findsNothing);
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          buildNumber.isEmpty ? 'v0.16.0\n' : 'v0.16.0 ($buildNumber)\n',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('retains push placeholder without Buzz registration on iOS', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final community = Community.create(
      name: 'Team',
      relayUrl: 'wss://relay.example',
    ).copyWith(pushNotificationsEnabled: true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          savedPrefsProvider.overrideWithValue(prefs),
          activeCommunityProvider.overrideWith((ref) async => community),
          appLifecycleProvider.overrideWith(_SettingsLifecycleNotifier.new),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SettingsPage(
            profileHeader: const SizedBox.shrink(),
            invitePageBuilder: (_) => const SizedBox.shrink(),
            identityRecoveryPageBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey('push-notifications-unavailable')),
    );
    expect(find.text('Unavailable yet'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('push-notifications-unavailable')),
        matching: find.byType(Switch),
      ),
      findsNothing,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('opens profile edit choices and routes photo directly', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [savedPrefsProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SettingsPage(
            profileHeader: const SizedBox.square(dimension: 128),
            profileEditPageBuilder: (_) =>
                const Scaffold(body: Text('Profile editor destination')),
            invitePageBuilder: (_) => const SizedBox.shrink(),
            identityRecoveryPageBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Profile'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('settings-edit-profile')));
    await tester.pumpAndSettle();
    expect(find.text('Edit profile'), findsOneWidget);
    expect(find.text('Display name'), findsOneWidget);
    expect(find.text('Profile description'), findsOneWidget);
    expect(find.text('Photo'), findsOneWidget);
    final optionCard = find.descendant(
      of: find.byKey(const ValueKey('edit-profile-options')),
      matching: find.byType(Material),
    );
    expect(tester.getSize(optionCard.first).height, greaterThan(150));
    for (final key in const [
      'edit-profile-display-name',
      'edit-profile-description',
      'edit-profile-photo',
    ]) {
      expect(
        tester.widget<AppListRow>(find.byKey(ValueKey(key))).verticalPadding,
        Grid.xs,
      );
    }
    final sheetContent = tester.widget<Padding>(
      find.byKey(const ValueKey('edit-profile-sheet-content')),
    );
    expect(sheetContent.padding, const EdgeInsets.only(bottom: Grid.xs));
    final sheetSafeArea = tester.widget<SafeArea>(
      find.ancestor(
        of: find.byKey(const ValueKey('edit-profile-sheet-content')),
        matching: find.byType(SafeArea),
      ),
    );
    expect(sheetSafeArea.top, isFalse);
    expect(sheetSafeArea.bottom, isTrue);
    final sheetRect = tester.getRect(find.byType(BottomSheet));
    final optionRect = tester.getRect(
      find.byKey(const ValueKey('edit-profile-options')),
    );
    expect(sheetRect.height, lessThan(340));
    expect(sheetRect.bottom - optionRect.bottom, Grid.xs);
    await tester.tap(find.byKey(const ValueKey('edit-profile-photo')));
    await tester.pumpAndSettle();
    expect(find.text('Profile editor destination'), findsOneWidget);
  });

  testWidgets('opens profile text editors after dismissing the choices', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final opened = <String>[];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [savedPrefsProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SettingsPage(
            profileHeader: const SizedBox.shrink(),
            onEditDisplayName: (_) async => opened.add('name'),
            onEditProfileDescription: (_) async => opened.add('description'),
            invitePageBuilder: (_) => const SizedBox.shrink(),
            identityRecoveryPageBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings-edit-profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit-profile-display-name')));
    await tester.pumpAndSettle();
    expect(opened, ['name']);
    expect(find.text('Edit profile'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-edit-profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit-profile-description')));
    await tester.pumpAndSettle();
    expect(opened, ['name', 'description']);
  });

  testWidgets('groups appearance controls under Interface', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          savedPrefsProvider.overrideWithValue(prefs),
          currentCommunityRoleProvider.overrideWithValue(
            const AsyncData<CommunityMemberRole?>(CommunityMemberRole.admin),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SettingsPage(
            profileHeader: const SizedBox.shrink(),
            invitePageBuilder: (_) => const SizedBox.shrink(),
            identityRecoveryPageBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final themeRow = find.byKey(const ValueKey('community-theme-row'));
    await tester.ensureVisible(themeRow);
    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('Interface'), findsOneWidget);
    expect(find.text('Invite to community'), findsNothing);
    expect(find.byKey(const ValueKey('settings-appearance')), findsOneWidget);
    final avatarRow = find.byKey(const ValueKey('settings-chat-avatars'));
    await tester.ensureVisible(avatarRow);
    await tester.pumpAndSettle();
    final avatarSwitch = find.descendant(
      of: avatarRow,
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(avatarSwitch).value, isFalse);
    await tester.tap(avatarSwitch);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(avatarSwitch).value, isTrue);
    expect(prefs.getBool(ChatAvatarsNotifier.preferenceKey), isTrue);

    await tester.tap(avatarRow);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(avatarSwitch).value, isFalse);
    expect(prefs.getBool(ChatAvatarsNotifier.preferenceKey), isFalse);
    await tester.ensureVisible(themeRow);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('community-theme-row')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('theme-preview-pages')), findsOneWidget);
  });

  testWidgets('uses the native glass close control on iOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [savedPrefsProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SettingsPage(
            profileHeader: const SizedBox.shrink(),
            invitePageBuilder: (_) => const SizedBox.shrink(),
            identityRecoveryPageBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final nativeViews = tester.widgetList<UiKitView>(find.byType(UiKitView));
    final nativeClose = nativeViews.singleWhere(
      (view) =>
          (view.creationParams as Map<Object?, Object?>?)?['icon'] == 'close',
    );
    final nativeEdit = nativeViews.singleWhere(
      (view) =>
          (view.creationParams as Map<Object?, Object?>?)?['label'] == 'Edit',
    );
    expect(nativeClose.viewType, 'buzz/navigation_glass');
    expect(nativeClose.creationParams, containsPair('icon', 'close'));
    expect(nativeEdit.viewType, 'buzz/navigation_glass');
    expect(nativeEdit.creationParams, containsPair('controlWidth', 56.0));
    expect(find.byTooltip('Close settings'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final role in CommunityMemberRole.values) {
    testWidgets('removes obsolete community controls for $role', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            savedPrefsProvider.overrideWithValue(prefs),
            currentCommunityRoleProvider.overrideWithValue(AsyncData(role)),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: SettingsPage(
              profileHeader: const SizedBox.shrink(),
              invitePageBuilder: (_) => const Text('Invite destination'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Invite to community'), findsNothing);
      expect(find.text('Identity (pubkey)'), findsNothing);
      expect(find.text('Send identity to desktop'), findsNothing);
      expect(find.text('Remove community'), findsNothing);
      expect(find.text('Saved connections'), findsNothing);
      expect(find.text('No saved connections'), findsNothing);
      expect(find.text('Attach to collab'), findsOneWidget);
      expect(find.text('Browse relay'), findsOneWidget);
      final sections = tester
          .widgetList<AppListCard>(find.byType(AppListCard))
          .map((section) => section.label)
          .whereType<String>()
          .toList();
      expect(sections, ['Spark live voice', 'Connection', 'Interface']);
      final policy = tester.widget<AppListRow>(
        find.byKey(const ValueKey('settings-licenses')),
      );
      final relay = tester.widget<AppListRow>(
        find.byKey(const ValueKey('settings-browse-relay')),
      );
      expect(policy.title, 'Policy');
      expect(policy.icon, isNotNull);
      expect(policy.trailing.runtimeType, relay.trailing.runtimeType);
    });
  }

  testWidgets('uses a 24dp rhythm between profile settings groups', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          savedPrefsProvider.overrideWithValue(prefs),
          currentCommunityRoleProvider.overrideWithValue(
            const AsyncData<CommunityMemberRole?>(CommunityMemberRole.admin),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SettingsPage(
            profileHeader: const SizedBox(height: 100),
            invitePageBuilder: (_) => const SizedBox.shrink(),
            identityRecoveryPageBuilder: (_) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final sections = tester.widgetList<AppListCard>(find.byType(AppListCard));
    expect(sections, isNotEmpty);
    expect(
      sections.every((section) => section.verticalPadding == Grid.twelve),
      isTrue,
    );
  });
}

class _SettingsLifecycleNotifier extends AppLifecycleNotifier {
  @override
  AppLifecycleState build() => AppLifecycleState.resumed;
}
