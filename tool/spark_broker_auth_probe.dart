// Modified for Raiju: opt-in, metadata-only Spark broker probe.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _defaultBroker = 'http://studio.home.arpa:8765';
const _maximumBodyBytes = 1024 * 1024;

Future<void> main() async {
  final environment = Platform.environment;
  final token =
      (environment['SPARK_BROKER_TOKEN'] ??
              environment['OMP_AUTH_BROKER_TOKEN'] ??
              '')
          .trim();
  final originText =
      (environment['SPARK_BROKER_URL'] ??
              environment['OMP_AUTH_BROKER_URL'] ??
              _defaultBroker)
          .trim();
  try {
    if (environment['SPARK_LIVE'] != '1') {
      throw const _ProbeError('live probe requires SPARK_LIVE=1');
    }
    if (token.isEmpty) {
      throw const _ProbeError(
        'broker token must be supplied through inherited runtime environment',
      );
    }
    final origin = Uri.tryParse(originText);
    if (origin == null ||
        !origin.hasScheme ||
        origin.host.isEmpty ||
        origin.path != '' ||
        origin.query.isNotEmpty ||
        origin.fragment.isNotEmpty) {
      throw const _ProbeError('SPARK_BROKER_URL must be an origin URL');
    }
    if (origin.scheme != 'https' &&
        !(origin.scheme == 'http' && environment['SPARK_ALLOW_HTTP'] == '1')) {
      throw const _ProbeError(
        'plaintext broker access requires explicit SPARK_ALLOW_HTTP=1',
      );
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client
          .getUrl(origin.resolve('/v1/snapshot'))
          .timeout(const Duration(seconds: 10));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(
        'OMP-Auth-Broker-Capabilities',
        'codex-meter-block-scopes',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.isRedirect) {
        await response.drain<void>();
        throw const _ProbeError('broker redirects are not accepted');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        if (bytes.length + chunk.length > _maximumBodyBytes) {
          throw const _ProbeError('broker response exceeded the size limit');
        }
        bytes.addAll(chunk);
      }
      if (response.statusCode != HttpStatus.ok) {
        throw _ProbeError(
          'broker rejected the request (${response.statusCode})',
        );
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const _ProbeError('broker returned an invalid snapshot');
      }
      final entries = decoded['credentials'];
      if (entries is! List) {
        throw const _ProbeError('broker returned an invalid snapshot');
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final eligible = entries.where((entry) {
        if (entry is! Map) return false;
        final credential = entry['credential'];
        return entry['provider'] == 'openai-codex' &&
            credential is Map &&
            credential['type'] == 'oauth' &&
            credential['access'] is String &&
            (credential['access'] as String).isNotEmpty &&
            credential['expires'] is num &&
            (credential['expires'] as num).toInt() > now;
      }).length;
      if (eligible == 0) {
        throw const _ProbeError(
          'no unexpired openai-codex credential is eligible',
        );
      }
      stdout.writeln('broker=ok provider=openai-codex eligible=$eligible');
      stdout.writeln(
        'provider-signaling=not-run (run the separate opt-in live provider probe)',
      );
    } finally {
      client.close(force: true);
    }
  } on _ProbeError catch (error) {
    stderr.writeln('error: ${error.message}');
    exitCode = 2;
  } on TimeoutException {
    stderr.writeln('error: broker probe timed out');
    exitCode = 2;
  } on FormatException {
    stderr.writeln('error: broker returned an invalid snapshot');
    exitCode = 2;
  } catch (_) {
    stderr.writeln('error: broker probe failed without exposing provider data');
    exitCode = 2;
  }
}

final class _ProbeError implements Exception {
  const _ProbeError(this.message);
  final String message;
}
