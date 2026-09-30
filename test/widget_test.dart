// Modified for Raiju: startup must render original shell without Buzz gates.
import 'package:raiju_mobile/app.dart';
import 'package:raiju_mobile/companion_controller.dart';
import 'package:raiju_mobile/features/age_gate/age_signal_provider.dart';
import 'package:raiju_mobile/features/home/home_page.dart';
import 'package:raiju_mobile/features/pairing/pairing_page.dart';
import 'package:raiju_mobile/raiju/companion_provider.dart';
import 'package:raiju_mobile/shared/auth/auth.dart';
import 'package:raiju_mobile/shared/theme/theme_provider.dart';
import 'package:raiju_mobile/storage/chat_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final storageFails in [false, true]) {
    testWidgets('App opens original home without account or age checks '
        '(storage failure: $storageFails)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = CompanionController(
        clientFactory: () => throw StateError('No connection was requested'),
        store: _StartupStore(fails: storageFails),
      );
      await controller.initialize();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(_ForbiddenAuthNotifier.new),
            ageSignalProvider.overrideWith(_ForbiddenAgeSignalNotifier.new),
            savedPrefsProvider.overrideWithValue(prefs),
            companionControllerProvider.overrideWith((ref) => controller),
          ],
          child: const App(),
        ),
      );
      await tester.pump();

      expect(find.byType(HomePage), findsOneWidget);
      expect(find.byType(PairingPage), findsNothing);
      expect(find.text('Welcome to Buzz'), findsNothing);
      expect(controller.storageError != null, storageFails);
      expect(tester.takeException(), isNull);
    });
  }
}

class _StartupStore implements ChatStore {
  _StartupStore({required this.fails});
  final bool fails;

  @override
  Future<List<StoredChat>> load() async {
    if (fails) {
      throw const ChatStoreException(
        ChatStoreFailure.keyUnavailable,
        'The device key for saved chats is unavailable.',
      );
    }
    return [];
  }

  @override
  Future<void> save(List<StoredChat> chats) async {}
}

class _ForbiddenAgeSignalNotifier extends AgeSignalNotifier {
  @override
  AgeSignalState build() => throw StateError('Buzz age gate activated');
}

class _ForbiddenAuthNotifier extends AuthNotifier {
  @override
  Future<AuthState> build() async =>
      throw StateError('Buzz account gate activated');
}
