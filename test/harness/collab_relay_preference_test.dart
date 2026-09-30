import 'package:buzz/harness/collab_link.dart';
import 'package:buzz/raiju/collab_relay_preference.dart';
import 'package:buzz/shared/theme/theme_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('default relay persists across provider reload', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final first = ProviderContainer(
      overrides: [savedPrefsProvider.overrideWithValue(prefs)],
    );
    addTearDown(first.dispose);
    expect(first.read(collabRelayProvider), defaultCollabRelay);
    await first
        .read(collabRelayProvider.notifier)
        .setRelay('wss://preferred.example:9443');
    expect(
      prefs.getString(collabRelayPreferenceKey),
      'wss://preferred.example:9443',
    );
    final reloaded = ProviderContainer(
      overrides: [savedPrefsProvider.overrideWithValue(prefs)],
    );
    addTearDown(reloaded.dispose);
    expect(reloaded.read(collabRelayProvider), 'wss://preferred.example:9443');
  });

  test('invalid endpoints do not replace the saved preference', () async {
    SharedPreferences.setMockInitialValues({
      collabRelayPreferenceKey: 'wss://good.example',
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [savedPrefsProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    expect(
      () => container
          .read(collabRelayProvider.notifier)
          .setRelay('ws://remote.example'),
      throwsA(isA<CollabLinkException>()),
    );
    expect(container.read(collabRelayProvider), 'wss://good.example');
    expect(prefs.getString(collabRelayPreferenceKey), 'wss://good.example');
  });
}
