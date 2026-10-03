// MODIFIED FOR RAIJU: connection actions are peers; obsolete identity rows gone.
import 'package:raiju_mobile/features/pairing/ompd_pairing_page.dart';
import 'package:raiju_mobile/features/pairing/pairing_page.dart';
import 'package:raiju_mobile/features/settings/settings_page.dart';
import 'package:raiju_mobile/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/widget_helpers.dart';

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Raiju',
      packageName: 'raiju',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  testWidgets('connection actions have no identity or per-chat clutter', (
    tester,
  ) async {
    await _pumpSettings(tester);
    expect(find.text('Identity (pubkey)'), findsNothing);
    expect(find.text('Send identity to desktop'), findsNothing);
    expect(find.text('Saved connections'), findsNothing);
    expect(find.text('No saved connections'), findsNothing);
    expect(find.text('Attach to collab'), findsOneWidget);
    expect(find.text('Browse relay'), findsOneWidget);
    expect(find.text('Default collaboration relay'), findsOneWidget);
  });

  testWidgets('collab opens directly from settings', (tester) async {
    await _pumpSettings(tester);
    await tester.tap(find.byKey(const ValueKey('settings-connect-omp')));
    await tester.pumpAndSettle();
    expect(find.byType(PairingPage), findsOneWidget);
    expect(find.byType(OmpdPairingPage), findsNothing);
  });

  testWidgets('relay browsing opens directly from settings', (tester) async {
    await _pumpSettings(tester);
    await tester.tap(find.byKey(const ValueKey('settings-browse-relay')));
    await tester.pumpAndSettle();
    final page = tester.widget<OmpdPairingPage>(find.byType(OmpdPairingPage));
    expect(page.initialView, OmpdPairingView.browse);
    expect(find.byType(PairingPage), findsNothing);
  });

  testWidgets('Interface appearance saves mode without changing accent', (
    tester,
  ) async {
    await _pumpSettings(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPage)),
    );
    final prefs = container.read(savedPrefsProvider);
    expect(container.read(communityThemeProvider), defaultCommunityTheme);
    await tester.tap(find.byKey(const ValueKey('settings-appearance')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appearance-mode-dark')));
    await tester.pump();
    await container.read(communityThemeProvider.notifier).flush();
    expect(
      CommunityThemeStorage(prefs).legacyPreference(),
      const CommunityThemePreference(
        theme: 'material-theme',
        accent: '#22c55e',
        followSystem: false,
      ),
    );
  });
}

Future<void> _pumpSettings(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    WidgetHelpers.testable(
      overrides: [savedPrefsProvider.overrideWithValue(prefs)],
      child: const SettingsPage(profileHeader: SizedBox.shrink()),
    ),
  );
  await tester.pumpAndSettle();
}
