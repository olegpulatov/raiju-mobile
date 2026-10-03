import 'dart:io';

import 'harness.dart';

/// Raw TCP endpoint. No credentials, URL paths, or TLS fallback are accepted.
final class OmpdEndpoint {
  const OmpdEndpoint._(this.host, this.port);

  final String host;
  final int port;

  static OmpdEndpoint parse(String input, {bool requirePort = false}) {
    const invalid = HarnessException('Enter a relay host and TCP port.');
    final text = input.trim();
    if (text.isEmpty || text.length > 512 || RegExp(r'\s').hasMatch(text)) {
      throw invalid;
    }
    try {
      String host;
      int? port = requirePort ? null : 7420;
      if (text.contains('://')) {
        final uri = Uri.parse(text);
        if (uri.scheme != 'tcp' ||
            uri.userInfo.isNotEmpty ||
            (uri.path.isNotEmpty && uri.path != '/') ||
            uri.hasQuery ||
            uri.hasFragment ||
            uri.host.isEmpty) {
          throw invalid;
        }
        host = uri.host;
        if (uri.hasPort) port = uri.port;
      } else if (text.startsWith('[')) {
        final match = RegExp(r'^\[([^\]]+)\](?::([0-9]+))?$').firstMatch(text);
        if (match == null) throw invalid;
        host = match[1]!;
        if (InternetAddress.tryParse(host)?.type != InternetAddressType.IPv6) {
          throw invalid;
        }
        if (match[2] != null) port = int.parse(match[2]!);
      } else if (InternetAddress.tryParse(text)?.type ==
          InternetAddressType.IPv6) {
        host = text;
      } else {
        final match = RegExp(r'^([^:/?#@]+)(?::([0-9]+))?$').firstMatch(text);
        if (match == null) throw invalid;
        host = match[1]!;
        if (match[2] != null) port = int.parse(match[2]!);
      }
      if (host.startsWith('[') && host.endsWith(']')) {
        host = host.substring(1, host.length - 1);
      }
      final address = InternetAddress.tryParse(host);
      if (address != null) {
        host = address.address;
      } else {
        if (host.length > 253 ||
            !RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(host) ||
            host
                .split('.')
                .any(
                  (part) =>
                      part.isEmpty ||
                      part.length > 63 ||
                      part.startsWith('-') ||
                      part.endsWith('-'),
                )) {
          throw invalid;
        }
        host = host.toLowerCase();
      }
      if (port == null || port < 1 || port > 65535) throw invalid;
      return OmpdEndpoint._(host, port);
    } catch (_) {
      throw invalid;
    }
  }

  @override
  String toString() => host.contains(':') ? '[$host]:$port' : '$host:$port';
}

final class OmpdConnection {
  OmpdConnection({
    required this.endpoint,
    required this.instance,
    this.sessionId,
    this.sessionFile,
    this.rpcSessionFile,
    required this.trustedNetwork,
  }) {
    validateOmpdName(instance);
    if (sessionId != null &&
        (sessionId!.isEmpty ||
            sessionId!.length > 512 ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(sessionId!))) {
      throw const HarnessException('Invalid relay session identity.');
    }
    if (sessionFile != null &&
        (!sessionFile!.startsWith('/') ||
            sessionFile!.length > 4096 ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(sessionFile!))) {
      throw const HarnessException('Invalid relay transcript identity.');
    }
    if (rpcSessionFile != null &&
        (rpcSessionFile!.isEmpty ||
            rpcSessionFile!.length > 4096 ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(rpcSessionFile!))) {
      throw const HarnessException('Invalid relay RPC transcript identity.');
    }
  }

  final OmpdEndpoint endpoint;
  final String instance;
  final String? sessionId;
  final String? sessionFile;
  final String? rpcSessionFile;
  final bool trustedNetwork;

  String encode() => Uri(
    scheme: 'ompd',
    host: endpoint.host,
    port: endpoint.port,
    pathSegments: [instance],
    queryParameters: {
      'session': ?sessionId,
      'file': ?sessionFile,
      'rpc-file': ?rpcSessionFile,
      'trusted': trustedNetwork ? '1' : '0',
    },
  ).toString();

  static bool isOmpd(String input) =>
      input.trim().toLowerCase().startsWith('ompd:');

  static OmpdConnection parse(String input) {
    const invalid = HarnessException('Invalid saved relay connection.');
    try {
      if (input.length > 65536) throw invalid;
      final uri = Uri.parse(input.trim());
      if (uri.scheme != 'ompd' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          uri.pathSegments.length != 1 ||
          uri.queryParametersAll.values.any((values) => values.length != 1) ||
          uri.queryParameters.keys.any(
            (key) => !['session', 'file', 'rpc-file', 'trusted'].contains(key),
          ) ||
          !['0', '1'].contains(uri.queryParameters['trusted'])) {
        throw invalid;
      }
      final host = uri.host.replaceAll('[', '').replaceAll(']', '');
      final endpoint = OmpdEndpoint.parse(
        '${host.contains(':') ? '[$host]' : host}:${uri.hasPort ? uri.port : 7420}',
      );
      return OmpdConnection(
        endpoint: endpoint,
        instance: uri.pathSegments.single,
        sessionId: uri.queryParameters['session'],
        sessionFile: uri.queryParameters['file'],
        rpcSessionFile: uri.queryParameters['rpc-file'],
        trustedNetwork: uri.queryParameters['trusted'] == '1',
      );
    } catch (_) {
      throw invalid;
    }
  }

  @override
  String toString() => 'OmpdConnection(${endpoint.toString()})';
}

/// The controller persists this loss even when takeover interrupted bootstrap.
abstract interface class OmpdControlStatus {
  bool get controlLost;
}

/// Supplies the bound relay identity for encrypted connection persistence.
abstract interface class OmpdBoundConnection {
  String? get savedConnection;
}

void validateOmpdName(String name) {
  if (name.isEmpty ||
      name.length > 80 ||
      name == '.' ||
      name == '..' ||
      !RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(name)) {
    throw const HarnessException(
      'Use 1–80 letters, digits, dots, or hyphens for the relay name.',
    );
  }
}
