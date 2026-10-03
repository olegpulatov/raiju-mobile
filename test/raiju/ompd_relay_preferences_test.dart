import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:raiju_mobile/raiju/ompd_relay_preferences.dart';
import 'package:raiju_mobile/shared/theme/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  ProviderContainer open() => ProviderContainer(
    overrides: [savedPrefsProvider.overrideWithValue(prefs)],
  );

  test('fresh preferences have no hardcoded endpoint or profile', () {
    final container = open();
    addTearDown(container.dispose);
    final state = container.read(ompdRelayPreferencesProvider);
    expect(state.endpoint, isNull);
    expect(state.profile, isEmpty);
  });

  test(
    'endpoint and profile survive provider recreation without a chat',
    () async {
      final first = open();
      await first
          .read(ompdRelayPreferencesProvider.notifier)
          .setDraft(endpoint: 'relay.example:8543', profile: 'test');
      first.dispose();
      await prefs.reload();
      final second = open();
      addTearDown(second.dispose);
      final restored = second.read(ompdRelayPreferencesProvider);
      expect(restored.endpoint, 'relay.example:8543');
      expect(restored.profile, 'test');
    },
  );

  test('rapid edits keep the latest endpoint and typed profile', () async {
    final container = open();
    final notifier = container.read(ompdRelayPreferencesProvider.notifier);
    final writes = [
      notifier.setDraft(endpoint: 'first.example:8543'),
      notifier.setDraft(profile: 'unfinished profile'),
      notifier.setDraft(endpoint: 'last.example:9000'),
    ];
    expect(
      container.read(ompdRelayPreferencesProvider).endpoint,
      'last.example:9000',
    );
    await Future.wait(writes);
    container.dispose();
    await prefs.reload();
    final restored = open();
    addTearDown(restored.dispose);
    final state = restored.read(ompdRelayPreferencesProvider);
    expect(state.endpoint, 'last.example:9000');
    expect(state.profile, 'unfinished profile');
  });

  test('empty and unfinished edits survive recreation', () async {
    final first = open();
    final notifier = first.read(ompdRelayPreferencesProvider.notifier);
    await notifier.setDraft(endpoint: 'unfinished:', profile: 'test');
    await notifier.setDraft(profile: '');
    first.dispose();
    final second = open();
    addTearDown(second.dispose);
    final state = second.read(ompdRelayPreferencesProvider);
    expect(state.endpoint, 'unfinished:');
    expect(state.profile, '');
  });
}
