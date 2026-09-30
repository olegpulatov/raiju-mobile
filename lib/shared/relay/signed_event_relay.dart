// MODIFIED FOR RAIJU: retained event-signing declarations never decode keys,
// sign Nostr events, or open sockets. OMP transport does not use this file.
import 'nostr_models.dart';
import 'relay_session.dart';
import 'backend_disabled.dart';

/// Signs and submits Nostr events through the relay WebSocket connection.
class SignedEventRelay {

  SignedEventRelay({
    required RelaySessionNotifier session,
    required String? nsec,
  });

  /// The hex pubkey derived from the signing key, or null if no key.
  String? get pubkey => null;

  /// Sign and submit an event. Returns the relay's OK response as a [NostrEvent]
  /// whose `content` field contains the OK message (e.g. `"response:{...}"`
  /// for command kinds).
  Future<NostrEvent> submit({
    required int kind,
    required String content,
    required List<List<String>> tags,
    int? createdAt,
    void Function(NostrEvent event)? onSigned,
  }) async {
    throw buzzBackendUnavailable;
  }
}

/// Publishes one signed event over a short-lived authenticated NIP-42 socket.
///
/// This is used for community-removal tombstones because the community being
/// removed is not necessarily the app's active relay session.
Future<NostrEvent> submitSignedEventOnce({
  required String wsUrl,
  required String nsec,
  required int kind,
  required String content,
  required List<List<String>> tags,
  int? createdAt,
  Duration timeout = const Duration(seconds: 12),
}) async {
  throw buzzBackendUnavailable;
}
