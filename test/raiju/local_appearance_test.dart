import 'package:raiju_mobile/shared/theme/community_theme_provider.dart';
import 'package:raiju_mobile/shared/theme/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('appearance survives provider recreation without any relay', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final first = ProviderContainer(
      overrides: [savedPrefsProvider.overrideWithValue(preferences)],
    );
    final notifier = first.read(communityThemeProvider.notifier);
    notifier.setMode(ThemeMode.dark);
    notifier.setAccent(1);
    final expected = first.read(communityThemeProvider);
    await notifier.flush();
    first.dispose();

    final second = ProviderContainer(
      overrides: [savedPrefsProvider.overrideWithValue(preferences)],
    );
    addTearDown(second.dispose);
    expect(second.read(communityThemeProvider).toJson(), expected.toJson());
  });
}
