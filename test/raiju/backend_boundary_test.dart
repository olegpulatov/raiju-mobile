import 'dart:typed_data';

import 'package:buzz/shared/auth/auth_provider.dart';
import 'package:buzz/shared/community/community_icon_provider.dart';
import 'package:buzz/shared/community/community_membership_provider.dart';
import 'package:buzz/shared/community/community_provider.dart';
import 'package:buzz/shared/community/community_storage.dart';
import 'package:buzz/shared/huddle/huddle_auth.dart';
import 'package:buzz/shared/huddle/huddle_session.dart';
import 'package:buzz/shared/huddle/huddle_transport.dart';
import 'package:buzz/features/search/recent_searches_provider.dart';
import 'package:buzz/shared/relay/backend_disabled.dart';
import 'package:buzz/shared/push/dev_push_lease.dart';
import 'package:buzz/shared/push/push_bridge.dart';
import 'package:buzz/shared/relay/relay_client.dart';
import 'package:buzz/shared/relay/media_upload.dart';
import 'package:buzz/shared/relay/media_auth.dart';
import 'package:buzz/shared/relay/relay_http_query_client.dart';
import 'package:buzz/shared/relay/relay_provider.dart';
import 'package:buzz/shared/relay/relay_session.dart';
import 'package:buzz/shared/relay/relay_socket.dart';
import 'package:buzz/shared/theme/community_theme_provider.dart';
import 'package:buzz/shared/theme/theme_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'default providers ignore legacy Buzz credentials and stay neutral',
    () async {
      SharedPreferences.setMockInitialValues({
        'buzz_relay_url': 'https://legacy.invalid',
        'buzz_nsec': 'nsec1legacy-secret-must-not-load',
      });
      final prefs = await SharedPreferences.getInstance();
      final secure = _LegacySecureStorage();
      final container = ProviderContainer(
        overrides: [
          communityStorageProvider.overrideWithValue(
            CommunityStorage(secure: secure),
          ),
          savedPrefsProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);

      final auth = await container.read(authProvider.future);
      final communities = await container.read(communityListProvider.future);
      final active = await container.read(activeCommunityProvider.future);
      final membership = await container.read(
        communityMembershipProvider.future,
      );
      final session = container.read(relaySessionProvider);
      final config = container.read(relayConfigProvider);

      // Appearance is an active no-login surface and must not wake the relay.
      container.read(communityThemeProvider);
      expect(
        await container.read(
          communityIconProvider('https://legacy.invalid').future,
        ),
        isNull,
      );

      expect(auth.status, AuthStatus.unauthenticated);
      expect(communities, isEmpty);
      expect(active, isNull);
      expect(membership.snapshotFound, isFalse);
      expect(session.status, SessionStatus.disconnected);
      expect(config.nsec, isNull);
      expect(config.baseUrl, 'https://buzz-backend-disabled.invalid');
      expect(secure.readCount, 0);
      expect(secure.writeCount, 0);
    },
  );

  test(
    'retained HTTP and WebSocket boundaries fail before transport',
    () async {
      var factoryCalls = 0;
      final queryClient = RelayHttpQueryClient(
        clientFactory: () {
          factoryCalls++;
          return _CountingHttpClient();
        },
      );
      await expectLater(
        queryClient.post(
          Uri.parse('https://legacy.invalid/query'),
          headers: const {},
          body: const [],
          timeout: const Duration(seconds: 1),
        ),
        throwsA(isA<BuzzBackendUnavailableException>()),
      );
      expect(factoryCalls, 0);

      final underlying = _CountingHttpClient();
      final relayClient = RelayClient(
        baseUrl: 'https://legacy.invalid',
        httpClient: underlying,
      );
      await expectLater(
        relayClient.httpClient.get(Uri.parse('https://legacy.invalid/upload')),
        throwsA(isA<BuzzBackendUnavailableException>()),
      );
      expect(underlying.sendCount, 0);

      final uploader = MediaUploadService(
        baseUrl: 'https://legacy.invalid',
        nsec: 'nsec1legacy-secret-must-not-decode',
        pickGalleryImage: () async => null,
        pickGalleryVideo: () async => null,
        httpClient: underlying,
      );
      addTearDown(uploader.dispose);
      await expectLater(
        uploader.uploadBytes(
          Uint8List.fromList(const [0x89, 0x50, 0x4e, 0x47]),
          mimeType: 'image/png',
        ),
        throwsA(isA<BuzzBackendUnavailableException>()),
      );
      expect(underlying.sendCount, 0);

      await expectLater(
        fetchBuzzPushLeaseDescriptor(
          'https://legacy.invalid',
          client: underlying,
        ),
        throwsA(isA<BuzzBackendUnavailableException>()),
      );
      await expectLater(
        enrollBuzzPush('wss://legacy.invalid', 'https://gateway.invalid'),
        throwsA(isA<BuzzBackendUnavailableException>()),
      );
      await expectLater(
        startBuzzPushRegistration(),
        throwsA(isA<BuzzBackendUnavailableException>()),
      );
      expect(underlying.sendCount, 0);

      final mediaAuth = MediaGetAuthService(
        baseUrl: 'https://legacy.invalid',
        nsec: 'nsec1legacy-secret-must-not-decode',
      );
      expect(
        mediaAuth.headersFor('https://legacy.invalid/media/private'),
        isEmpty,
      );
      expect(
        () => buildNip98AuthHeader(
          method: 'POST',
          url: 'https://legacy.invalid/query',
          bodyBytes: const [],
          nsec: 'nsec1legacy-secret-must-not-decode',
        ),
        throwsA(isA<BuzzBackendUnavailableException>()),
      );

      final socket = RelaySocket(
        wsUrl: 'wss://legacy.invalid',
        nsec: 'nsec1legacy-secret-must-not-decode',
        onMessage: (_) {},
        onConnected: () {},
        onDisconnected: (_) {},
      );
      await expectLater(
        socket.connect(),
        throwsA(isA<BuzzBackendUnavailableException>()),
      );

      var huddleSocketOpens = 0;
      final huddleParameters = HuddleConnectionParameters(
        relayWebSocketUrl: 'wss://legacy.invalid',
        nsec: 'nsec1legacy-secret-must-not-decode',
        parentChannelId: '00000000-0000-4000-8000-000000000001',
        ephemeralChannelId: '00000000-0000-4000-8000-000000000002',
      );
      final huddle = HuddleTransport(
        parameters: huddleParameters,
        channelFactory: (_) {
          huddleSocketOpens++;
          throw StateError('Huddle socket opener must never be reached.');
        },
      );
      addTearDown(huddle.dispose);
      await expectLater(
        huddle.connect(),
        throwsA(isA<BuzzBackendUnavailableException>()),
      );
      expect(huddleSocketOpens, 0);
      expect(
        () => HuddleAuthV2.buildMessage(
          parameters: huddleParameters,
          challenge: 'legacy-challenge',
        ),
        throwsA(isA<BuzzBackendUnavailableException>()),
      );

      final huddleContainer = ProviderContainer();
      addTearDown(huddleContainer.dispose);
      await huddleContainer
          .read(huddleSessionProvider.notifier)
          .join(huddleParameters);
      expect(
        huddleContainer.read(huddleSessionProvider).phase,
        HuddleSessionPhase.failed,
      );
      expect(
        huddleContainer.read(huddleSessionProvider).error,
        contains('unavailable'),
      );
    },
  );

  test('relay session stays inert and public operations fail closed', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(relaySessionProvider).status,
      SessionStatus.disconnected,
    );
    await expectLater(
      container.read(relaySessionProvider.notifier).queryRelay(const []),
      throwsA(isA<BuzzBackendUnavailableException>()),
    );
    await expectLater(
      container.read(relaySessionProvider.notifier).reconnect(),
      throwsA(isA<BuzzBackendUnavailableException>()),
    );
  });

  test(
    'recent searches stay memory-only and old plaintext is removed',
    () async {
      const legacyKey = 'recent_searches_v1:https://relay.invalid:anon';
      SharedPreferences.setMockInitialValues({
        legacyKey: <String>['private transcript phrase'],
      });
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [savedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      expect(container.read(recentSearchesProvider), isEmpty);
      container
          .read(recentSearchesProvider.notifier)
          .record('new private phrase');
      expect(container.read(recentSearchesProvider), ['new private phrase']);
      await Future<void>.delayed(Duration.zero);
      expect(prefs.containsKey(legacyKey), isFalse);
      expect(
        prefs.getKeys().where((key) => key.startsWith('recent_searches_v1')),
        isEmpty,
      );
    },
  );
}

class _CountingHttpClient extends http.BaseClient {
  int sendCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sendCount++;
    throw StateError('Network transport must never be reached.');
  }
}

class _LegacySecureStorage extends Fake implements FlutterSecureStorage {
  int readCount = 0;
  int writeCount = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    readCount++;
    return switch (key) {
      'buzz_relay_url' => 'https://legacy.invalid',
      'buzz_nsec' => 'nsec1legacy-secret-must-not-load',
      _ => null,
    };
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writeCount++;
  }
}
