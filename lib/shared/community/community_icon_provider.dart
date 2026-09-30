// MODIFIED FOR RAIJU: community icon declarations remain compatible but never
// fetch relay metadata or construct an active network client.
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;

import '../relay/relay_client.dart';

/// Supplies the HTTP client used for NIP-11 community icon lookups.
///
/// Tests can override this provider to return deterministic relay responses.
final communityIconHttpClientProvider = Provider<http.Client>((ref) {
  final client = RelayClient(baseUrl: 'https://buzz-backend-disabled.invalid');
  ref.onDispose(client.dispose);
  return client.httpClient;
});

/// Raiju has no Buzz community metadata source.
final communityIconProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, relayUrl) async => null);
