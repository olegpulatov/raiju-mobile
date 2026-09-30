// MODIFIED FOR RAIJU: this retained Buzz HTTP compatibility client is
// deliberately fail-closed. OMP transport is implemented under lib/harness.
import 'package:http/http.dart' as http;

import 'backend_disabled.dart';

/// Compatibility shape for legacy media callers; no request can leave Raiju.
class RelayClient {
  final String baseUrl;
  final http.Client _http;

  RelayClient({required this.baseUrl, http.Client? httpClient})
    : _http = _DisabledBuzzHttpClient(httpClient);

  http.Client get httpClient => _http;

  String get mediaUploadUrl =>
      Uri.parse(baseUrl).resolve('/upload').toString();

  void dispose() => _http.close();
}

class _DisabledBuzzHttpClient extends http.BaseClient {
  _DisabledBuzzHttpClient(this._legacyClient);

  final http.Client? _legacyClient;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Future.error(buzzBackendUnavailable);

  @override
  void close() => _legacyClient?.close();
}

/// Retained for source compatibility with legacy callers.
class RelayException implements Exception {
  final int statusCode;
  final String body;

  RelayException(this.statusCode, this.body);

  @override
  String toString() {
    final trimmedBody = body.trim();
    if (trimmedBody.isEmpty) return 'RelayException($statusCode)';
    return 'RelayException($statusCode): $trimmedBody';
  }
}
