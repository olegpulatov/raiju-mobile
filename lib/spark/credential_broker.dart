import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class SparkCredential {
  const SparkCredential({
    required this.id,
    required this.accessToken,
    this.accountId,
    required this.expiresAtMs,
  });
  final String id;
  final String accessToken;
  final String? accountId;
  final int expiresAtMs;
}

class SparkCredentialResult {
  const SparkCredentialResult({required this.choices, this.credential});
  final List<SparkCredentialChoice> choices;
  final SparkCredential? credential;
}

class SparkCancellation {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];
  bool get isCancelled => _cancelled;
  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }
}

abstract interface class SparkCredentialSource {
  Future<SparkCredentialResult> acquire(
    SparkSettings settings,
    String brokerToken,
  );
}

abstract interface class CancellableSparkCredentialSource
    implements SparkCredentialSource {
  Future<SparkCredentialResult> acquireCancellable(
    SparkSettings settings,
    String brokerToken,
    SparkCancellation cancellation,
  );
}

class SparkBrokerException implements Exception {
  const SparkBrokerException(this.message);
  final String message;
  @override
  String toString() => message;
}

class OmpBrokerCredentialSource implements CancellableSparkCredentialSource {
  OmpBrokerCredentialSource({
    http.Client? client,
    this.maxResponseBytes = 512 * 1024,
    this.nearExpiry = const Duration(minutes: 5),
  }) : _providedClient = client;
  final http.Client? _providedClient;
  final int maxResponseBytes;
  final Duration nearExpiry;

  @override
  Future<SparkCredentialResult> acquire(
    SparkSettings settings,
    String brokerToken,
  ) => acquireCancellable(settings, brokerToken, SparkCancellation());
  @override
  Future<SparkCredentialResult> acquireCancellable(
    SparkSettings settings,
    String brokerToken,
    SparkCancellation cancellation,
  ) async {
    final base = _validateBase(settings);
    final client = _providedClient ?? http.Client();
    cancellation.onCancel(client.close);
    if (cancellation.isCancelled) {
      throw const SparkBrokerException('Spark start was cancelled.');
    }
    try {
      final response = await _request(
        client,
        base.resolve('v1/snapshot'),
        brokerToken,
        'GET',
        cancellation,
      );
      final root = _object(response);
      final serverNow = _integer(root['serverNowMs']);
      final rawEntries = root['credentials'];
      if (rawEntries is! List || rawEntries.length > 1000) {
        throw const SparkBrokerException(
          'The broker returned an invalid credential snapshot.',
        );
      }
      final entries = <_BrokerEntry>[];
      for (final value in rawEntries) {
        if (value is! Map) continue;
        final entry = _parseEntry(value.cast<String, Object?>());
        if (entry != null) entries.add(entry);
      }
      final choices = entries
          .map((e) => SparkCredentialChoice(id: e.id, label: e.label))
          .toList(growable: false);
      if (entries.isEmpty) {
        throw const SparkBrokerException(
          'No eligible ChatGPT subscription credential is available.',
        );
      }
      _BrokerEntry? selected;
      final selectedId = settings.selectedCredentialId;
      if (selectedId != null) {
        selected = entries.where((e) => e.id == selectedId).firstOrNull;
        if (selected == null) return SparkCredentialResult(choices: choices);
      } else if (entries.length == 1) {
        selected = entries.single;
      } else {
        return SparkCredentialResult(choices: choices);
      }
      if (selected.expiresAtMs - serverNow <= nearExpiry.inMilliseconds) {
        final refreshed = await _request(
          client,
          base.resolve(
            'v1/credential/${Uri.encodeComponent(selected.id)}/refresh',
          ),
          brokerToken,
          'POST',
          cancellation,
        );
        final refreshRoot = _object(refreshed);
        final raw = refreshRoot['entry'];
        if (raw is! Map) {
          throw const SparkBrokerException(
            'The broker returned an invalid refreshed credential.',
          );
        }
        selected =
            _parseEntry(raw.cast<String, Object?>()) ??
            (throw const SparkBrokerException(
              'The refreshed credential is not eligible for Spark.',
            ));
        if (selected.expiresAtMs - serverNow <= 30000) {
          throw const SparkBrokerException(
            'The broker credential is expired or too close to expiry.',
          );
        }
      }
      return SparkCredentialResult(
        choices: choices,
        credential: SparkCredential(
          id: selected.id,
          accessToken: selected.access,
          accountId: selected.accountId,
          expiresAtMs: selected.expiresAtMs,
        ),
      );
    } finally {
      client.close();
    }
  }

  Uri _validateBase(SparkSettings settings) {
    final uri = Uri.tryParse(settings.brokerUrl.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw const SparkBrokerException(
        'Enter a valid broker URL without embedded credentials.',
      );
    }
    if (uri.scheme == 'http' && !settings.allowInsecureHttp) {
      throw const SparkBrokerException(
        'HTTP broker access requires explicit trusted-network consent.',
      );
    }
    final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
    return uri.replace(path: path);
  }

  Future<String> _request(
    http.Client client,
    Uri uri,
    String token,
    String method,
    SparkCancellation? cancellation,
  ) async {
    try {
      final operation = () async {
        if (cancellation?.isCancelled ?? false) {
          throw const SparkBrokerException('Spark start was cancelled.');
        }
        final request = http.Request(method, uri)
          ..followRedirects = false
          ..headers.addAll({
            'authorization': 'Bearer $token',
            'accept': 'application/json',
            'OMP-Auth-Broker-Capabilities': 'codex-meter-block-scopes',
          });
        final response = await client.send(request);
        if (response.isRedirect) {
          throw const SparkBrokerException('Broker redirects are not allowed.');
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (cancellation?.isCancelled ?? false) {
            throw const SparkBrokerException('Spark start was cancelled.');
          }
          bytes.addAll(chunk);
          if (bytes.length > maxResponseBytes) {
            throw const SparkBrokerException(
              'The broker response was too large.',
            );
          }
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          if (response.statusCode == 401 || response.statusCode == 403) {
            throw const SparkBrokerException(
              'Broker authentication failed. Check the saved broker token.',
            );
          }
          throw SparkBrokerException(
            'The broker request failed (${response.statusCode}).',
          );
        }
        return utf8.decode(bytes, allowMalformed: false);
      }();
      return await operation.timeout(const Duration(seconds: 10));
    } on SparkBrokerException {
      rethrow;
    } catch (_) {
      if (cancellation?.isCancelled ?? false) {
        throw const SparkBrokerException('Spark start was cancelled.');
      }
      throw const SparkBrokerException(
        'The broker could not be reached securely.',
      );
    }
  }

  Map<String, Object?> _object(String body) {
    try {
      final value = jsonDecode(body);
      if (value is Map) return value.cast<String, Object?>();
    } catch (_) {}
    throw const SparkBrokerException(
      'The broker returned an invalid response.',
    );
  }

  int _integer(Object? value) => value is num && value.isFinite
      ? value.toInt()
      : (throw const SparkBrokerException(
          'The broker returned an invalid clock.',
        ));
  _BrokerEntry? _parseEntry(Map<String, Object?> value) {
    if (value['provider'] != 'openai-codex') return null;
    final id = value['id'];
    final rawCredential = value['credential'];
    if (id is! num || rawCredential is! Map) return null;
    final credential = rawCredential.cast<String, Object?>();
    if (credential['type'] != 'oauth' ||
        credential['access'] is! String ||
        (credential['access'] as String).isEmpty ||
        credential['expires'] is! num) {
      return null;
    }
    final identity = value['identityKey'];
    final email = credential['email'];
    final label = email is String && email.isNotEmpty
        ? email
        : identity is String && identity.isNotEmpty
        ? identity
        : 'ChatGPT account ${id.toInt()}';
    return _BrokerEntry(
      id: '${id.toInt()}',
      access: credential['access'] as String,
      accountId: credential['accountId'] as String?,
      expiresAtMs: (credential['expires'] as num).toInt(),
      label: label,
    );
  }
}

class _BrokerEntry {
  const _BrokerEntry({
    required this.id,
    required this.access,
    this.accountId,
    required this.expiresAtMs,
    required this.label,
  });
  final String id;
  final String access;
  final String? accountId;
  final int expiresAtMs;
  final String label;
}
