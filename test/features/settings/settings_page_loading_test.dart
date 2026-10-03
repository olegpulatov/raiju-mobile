// MODIFIED FOR RAIJU: verify offline policy collection and logical settings.
import 'dart:async';

import 'package:raiju_mobile/features/settings/settings_page.dart';
import 'package:raiju_mobile/raiju/licenses.dart';
import 'package:raiju_mobile/shared/community/community_membership_provider.dart';
import 'package:raiju_mobile/shared/theme/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('settings remains usable while package metadata loads', (
    tester,
  ) async {
    final metadata = Completer<Map<String, String>>();
    const channel = MethodChannel('dev.fluttercommunity.plus/package_info');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) => metadata.future,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    SharedPreferences.setMockInitialValues({});
    registerRaijuLicenses();
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
    expect(find.text('Spark live voice'), findsOneWidget);
    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('Attach to collab'), findsOneWidget);

    expect(find.text('v0.16.0 (432)'), findsNothing);
    expect(find.byTooltip('Close settings'), findsOneWidget);
    metadata.complete({
      'appName': 'Buzz',
      'packageName': 'xyz.block.buzz',
      'version': '0.16.0',
      'buildNumber': '432',
      'buildSignature': '',
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('v0.16.0 (432)\n'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final licenses = (await tester.runAsync(
      () => LicenseRegistry.licenses.toList(),
    ))!;
    final emojiLicense = licenses.singleWhere(
      (entry) => entry.packages.contains('@emoji-mart/data 1.2.1'),
    );
    expect(
      emojiLicense.paragraphs.map((paragraph) => paragraph.text).join('\n'),
      contains('Permission is hereby granted'),
    );
    expect(
      licenses.any(
        (entry) =>
            entry.packages.any((name) => name.endsWith('(Spark native)')),
      ),
      isTrue,
    );
    final licensesRow = find.byKey(const ValueKey('settings-licenses'));
    await tester.scrollUntilVisible(licensesRow, 300);
    expect(find.text('Policy'), findsOneWidget);
    expect(find.text('Licenses'), findsNothing);
    await tester.pumpAndSettle();
    await tester.tap(licensesRow);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LicensePage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
