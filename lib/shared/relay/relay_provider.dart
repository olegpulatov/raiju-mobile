// MODIFIED FOR RAIJU: retained Buzz provider declarations are neutral and
// cannot bootstrap credentials or transport. OMP networking lives elsewhere.
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'backend_disabled.dart';
import 'relay_client.dart';

/// Relay connection configuration.
///
/// In the pure-nostr world the only secrets the app cares about are:
///   - `baseUrl` — where the relay lives (used for WS + media upload)
///   - `nsec`    — the user's signing key (drives NIP-42 AUTH and event sigs)
class RelayConfig {
  const RelayConfig({required String baseUrl, this.nsec}) : _baseUrl = baseUrl;

  /// Relay origin exactly as the active community stored it.
  final String _baseUrl;

  /// Nostr secret key (bech32 nsec) for signing events and NIP-42 AUTH.
  final String? nsec;

  /// The origin as persisted, before scheme canonicalization.
  ///
  /// Exists solely so identity-scoped storage keys written before [baseUrl]
  /// was canonicalized stay reachable — see [readMigratedPref]. Never use it
  /// for network I/O; [baseUrl] and [wsUrl] are the addresses to connect to.
  String get storedOrigin => _baseUrl;

  /// Relay origin as an HTTP(S) URL.
  ///
  /// Communities are persisted with whichever scheme their onboarding flow
  /// used: device pairing stores `https://` (it rejects anything else), while
  /// an invite join stores the `wss://` relay URL carried by the invite link.
  /// Every consumer treats this as an HTTP origin — [wsUrl], the `/query`
  /// endpoint, media upload and Blossom auth — so a `wss://` base silently
  /// degrades all of them. Folding the websocket schemes back here keeps both
  /// onboarding paths equivalent, including for already-persisted communities.
  ///
  /// Derived rather than normalized in the constructor so that the constructor
  /// stays `const`: the compile-time fallback below relies on canonicalization
  /// to keep its identity stable across rebuilds, and Riverpod's default
  /// `updateShouldNotify` is `previous != next`, which falls back to identity
  /// here. A fresh instance per rebuild would resubscribe every listener.
  String get baseUrl {
    final uri = Uri.tryParse(_baseUrl);
    if (uri == null) return _baseUrl;
    final scheme = switch (uri.scheme) {
      'wss' => 'https',
      'ws' => 'http',
      _ => null,
    };
    return scheme == null ? _baseUrl : uri.replace(scheme: scheme).toString();
  }

  /// Derive the websocket URL from the HTTP base URL.
  String get wsUrl {
    final uri = Uri.parse(baseUrl);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    return uri.replace(scheme: scheme).toString();
  }
}

/// Retained compile-time names deliberately ignore legacy dart-defines.
///
/// Raiju never enables the Buzz relay or push gateway from build settings.
class Env {
  static const relayUrl = '';
  static const pushGatewayUrl = '';
  static const pushGatewayConfigured = false;
}

class RelayConfigNotifier extends Notifier<RelayConfig> {
  @override
  RelayConfig build() =>
      const RelayConfig(baseUrl: 'https://buzz-backend-disabled.invalid');

  void update({required String baseUrl, String? nsec}) {
    throw buzzBackendUnavailable;
  }
}

final relayConfigProvider = NotifierProvider<RelayConfigNotifier, RelayConfig>(
  RelayConfigNotifier.new,
);

/// Buzz signing identities are never decoded or exposed by Raiju.
String? pubkeyFromNsec(String? nsec) => null;

/// The current user's hex pubkey, derived from the active community nsec.
final myPubkeyProvider = Provider<String?>((ref) {
  final config = ref.watch(relayConfigProvider);
  return pubkeyFromNsec(config.nsec);
});

/// Provides a [RelayClient] that reacts to config changes.
///
/// Only used for the media upload HTTP endpoint now — all data flow goes
/// through the relay WebSocket session.
final relayClientProvider = Provider<RelayClient>((ref) {
  final config = ref.watch(relayConfigProvider);
  final client = RelayClient(baseUrl: config.baseUrl);
  ref.onDispose(client.dispose);
  return client;
});
