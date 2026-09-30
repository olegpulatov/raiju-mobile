// MODIFIED FOR RAIJU: retained Buzz relay queries are fail-closed; only the
// separate OMP harness transport may open application chat connections.
import 'package:http/http.dart' as http;

import 'backend_disabled.dart';

/// Owns the reusable HTTP transport used for relay `/query` requests.
class RelayHttpQueryClient {
  RelayHttpQueryClient({
    http.Client? client,
    http.Client Function()? clientFactory,
  }) : _injectedClient = client;

  final http.Client? _injectedClient;

  Future<http.Response> post(
    Uri url, {
    required Map<String, String> headers,
    required List<int> body,
    required Duration timeout,
  }) async {
    throw buzzBackendUnavailable;
  }

  void close() => _injectedClient?.close();
}
