// MODIFIED FOR RAIJU: retained NIP-98 auth cannot decode keys, generate
// nonces, or sign events.
part of 'relay_session.dart';

String buildNip98AuthHeader({
  required String method,
  required String url,
  required List<int> bodyBytes,
  required String? nsec,
}) {
  throw buzzBackendUnavailable;
}
