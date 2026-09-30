// Modified for Raiju: private broker-to-Core live provider probe flow.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _defaultBroker = 'http://studio.home.arpa:8765';
const _maxBytes = 1024 * 1024;

Future<void> main() async {
  final env = Platform.environment;
  final brokerToken =
      (env['SPARK_BROKER_TOKEN'] ?? env['OMP_AUTH_BROKER_TOKEN'] ?? '').trim();
  final brokerText =
      (env['SPARK_BROKER_URL'] ?? env['OMP_AUTH_BROKER_URL'] ?? _defaultBroker)
          .trim();
  Process? providerProcess;
  try {
    if (env['SPARK_LIVE'] != '1') {
      throw const _ProbeError('live provider probe requires SPARK_LIVE=1');
    }
    if (brokerToken.isEmpty) {
      throw const _ProbeError('broker token must be inherited at runtime');
    }
    final broker = Uri.tryParse(brokerText);
    if (broker == null ||
        !broker.hasScheme ||
        broker.host.isEmpty ||
        broker.path.isNotEmpty ||
        broker.hasQuery ||
        broker.hasFragment) {
      throw const _ProbeError('broker URL must be an origin');
    }
    if (broker.scheme != 'https' &&
        !(broker.scheme == 'http' && env['SPARK_ALLOW_HTTP'] == '1')) {
      throw const _ProbeError(
        'plaintext broker access requires SPARK_ALLOW_HTTP=1',
      );
    }
    final snapshot = await _getSnapshot(broker, brokerToken);
    final raw = snapshot['credentials'];
    if (raw is! List) {
      throw const _ProbeError('broker returned an invalid snapshot');
    }
    final serverNow = snapshot['serverNowMs'] is num
        ? (snapshot['serverNowMs'] as num).toInt()
        : DateTime.now().millisecondsSinceEpoch;
    final eligible = raw
        .whereType<Map>()
        .where((entry) {
          final credential = entry['credential'];
          return entry['provider'] == 'openai-codex' &&
              credential is Map &&
              credential['type'] == 'oauth' &&
              credential['access'] is String &&
              (credential['access'] as String).isNotEmpty &&
              credential['expires'] is num &&
              (credential['expires'] as num).toInt() > serverNow;
        })
        .toList(growable: false);
    final selectedId = env['SPARK_CREDENTIAL_ID']?.trim();
    Map? selected;
    if (selectedId != null && selectedId.isNotEmpty) {
      selected = eligible
          .where((entry) => '${entry['id']}' == selectedId)
          .firstOrNull;
    } else if (eligible.length == 1) {
      selected = eligible.single;
    }
    if (selected == null) {
      throw _ProbeError(
        eligible.isEmpty
            ? 'no eligible openai-codex credential is available'
            : 'multiple credentials require SPARK_CREDENTIAL_ID',
      );
    }
    final credential = selected['credential'] as Map;
    final childEnv = Map<String, String>.of(env)
      ..remove('SPARK_ACCESS_TOKEN')
      ..remove('SPARK_ACCOUNT_ID')
      ..remove('SPARK_BROKER_TOKEN')
      ..remove('OMP_AUTH_BROKER_TOKEN');
    providerProcess = await Process.start(
      'cargo',
      [
        'run',
        '--manifest-path',
        'spark-core/Cargo.toml',
        '--bin',
        'spark-live-probe',
      ],
      environment: childEnv,
      includeParentEnvironment: false,
      mode: ProcessStartMode.normal,
    );
    final process = providerProcess;
    final stdoutDone = process.stdout.pipe(stdout);
    final stderrDone = process.stderr.pipe(stderr);
    process.stdin.write(
      jsonEncode({
        'accessToken': credential['access'],
        if (credential['accountId'] is String)
          'accountId': credential['accountId'],
      }),
    );
    await process.stdin.close();
    exitCode = await process.exitCode.timeout(const Duration(minutes: 2));
    await Future.wait([stdoutDone, stderrDone]);
  } on _ProbeError catch (error) {
    stderr.writeln('error: ${error.message}');
    exitCode = 2;
  } on TimeoutException {
    if (providerProcess case final process?) {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
    }
    stderr.writeln('error: live provider probe timed out');
    exitCode = 2;
  } catch (_) {
    stderr.writeln(
      'error: live provider probe failed without exposing provider data',
    );
    exitCode = 2;
  }
}

Future<Map<String, Object?>> _getSnapshot(Uri broker, String token) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client
        .getUrl(broker.resolve('/v1/snapshot'))
        .timeout(const Duration(seconds: 10));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.set(
      'OMP-Auth-Broker-Capabilities',
      'codex-meter-block-scopes',
    );
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.isRedirect) {
      await response.drain<void>();
      throw const _ProbeError('broker redirects are not accepted');
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      if (bytes.length + chunk.length > _maxBytes) {
        throw const _ProbeError('broker response exceeded the size limit');
      }
      bytes.addAll(chunk);
    }
    if (response.statusCode != HttpStatus.ok) {
      throw _ProbeError('broker rejected the request (${response.statusCode})');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map) return decoded.cast<String, Object?>();
    throw const _ProbeError('broker returned an invalid snapshot');
  } finally {
    client.close(force: true);
  }
}

final class _ProbeError implements Exception {
  const _ProbeError(this.message);
  final String message;
}
