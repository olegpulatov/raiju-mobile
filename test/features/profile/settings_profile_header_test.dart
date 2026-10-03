// MODIFIED FOR RAIJU: local profile header and reactive aggregate connectivity.
import 'package:raiju_mobile/features/profile/settings_profile_header.dart';
import 'package:raiju_mobile/raiju/connection_status_provider.dart';
import 'package:raiju_mobile/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/legacy.dart';

import '../../helpers/widget_helpers.dart';

final _online = StateProvider<bool>((ref) => false);

void main() {
  testWidgets('retains local avatar, name and settings spacing', (
    tester,
  ) async {
    await _pumpHeader(tester);
    final header = tester.widget<Padding>(
      find.byKey(const ValueKey('settings-profile-header')),
    );
    expect((header.padding as EdgeInsets).bottom, Grid.twelve);
    final avatar = find.byKey(const ValueKey('settings-profile-avatar'));
    expect(tester.getSize(avatar), const Size(128, 128));
    final name = find.text('You');
    expect(name, findsOneWidget);
    expect(
      tester.getTopLeft(name).dy,
      greaterThan(tester.getBottomLeft(avatar).dy),
    );
  });

  testWidgets(
    'presence follows aggregate online state without reopening settings',
    (tester) async {
      await _pumpHeader(tester);
      expect(find.text('Offline'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SettingsProfileHeader)),
      );
      container.read(_online.notifier).state = true;
      await tester.pump();
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('Offline'), findsNothing);
      container.read(_online.notifier).state = false;
      await tester.pump();
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('Online'), findsNothing);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('settings-presence-target')))
            .height,
        Grid.xl,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('settings-presence-label')))
            .style
            ?.fontSize,
        filterChipTextStyle.fontSize,
      );
    },
  );

  testWidgets('unsupported avatar action has a simple explanation', (
    tester,
  ) async {
    await _pumpHeader(tester);
    await tester.tap(find.byKey(const ValueKey('settings-profile-avatar')));
    await tester.pump();
    expect(find.text('Unavailable yet'), findsOneWidget);
  });

  testWidgets('manual presence selection cannot override connection state', (
    tester,
  ) async {
    await _pumpHeader(tester);
    await tester.tap(find.byKey(const ValueKey('settings-presence-target')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-presence-online')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('settings-presence-online')));
    await tester.pumpAndSettle();
    expect(find.text('Unavailable yet'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
  });
}

Future<void> _pumpHeader(WidgetTester tester) async {
  await tester.pumpWidget(
    WidgetHelpers.testable(
      overrides: [
        connectionOnlineProvider.overrideWith((ref) => ref.watch(_online)),
      ],
      child: const SettingsProfileHeader(),
    ),
  );
  await tester.pumpAndSettle();
}
