import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:buzz/harness/harness.dart';
import 'package:buzz/harness/omp_collab_client.dart';

Future<void> main(List<String> arguments) async {
  OmpCollabClient? client;
  String? capability;
  try {
    final options = _Options.parse(arguments);
    capability = options.fromStdin
        ? await _readCapabilityFromStdin()
        : await _acquireCapability(options.host!);

    client = OmpCollabClient.withOptions(
      const OmpCollabClientOptions(
        welcomeTimeout: Duration(seconds: 20),
        snapshotProgressTimeout: Duration(seconds: 20),
      ),
    );
    await client
        .connect(capability, displayName: 'raiju-smoke')
        .timeout(const Duration(seconds: 30));
    final connected = client.snapshot;
    if (connected.phase != ConnectionPhase.live) {
      throw const _SmokeError('Host did not reach the live state.');
    }
    stdout.writeln(
      'connected readOnly=${connected.readOnly} history=${connected.messages.length}',
    );
    if (options.countMarker case final marker?) {
      final markerCount = connected.messages
          .where((message) => message.text.contains(marker))
          .length;
      stdout.writeln('markerCount=$markerCount');
    }

    if (options.send) {
      if (!connected.canSend) {
        throw const _SmokeError(
          'Selected capability is read-only; --send requires control access.',
        );
      }
      final marker = 'RAIJU_${DateTime.now().toUtc().microsecondsSinceEpoch}';
      final reply = _waitForMarker(client, marker);
      await client
          .sendPrompt(
            'Reply with exactly $marker and no other text. Do not use tools.',
          )
          .timeout(const Duration(seconds: 15));
      final snapshot = await reply.timeout(const Duration(seconds: 90));
      final durable = snapshot.messages.any(
        (message) =>
            message.role == MessageRole.assistant &&
            !message.isStreaming &&
            message.text.contains(marker),
      );
      if (!durable) throw const _SmokeError('Marker reply was not durable.');
      stdout.writeln('send=ok messages=${snapshot.messages.length}');
    }

    await client.disconnect().timeout(const Duration(seconds: 10));
    stdout.writeln('closed=ok');
  } on _UsageError catch (error) {
    stderr.writeln('error: ${error.message}');
    exitCode = 64;
  } on TimeoutException {
    stderr.writeln('error: timed out waiting for the selected OMP host.');
    exitCode = 2;
  } on ProcessException {
    stderr.writeln(
      'error: OMP CLI is unavailable; install `omp` or use --stdin.',
    );
    exitCode = 127;
  } on _SmokeError catch (error) {
    stderr.writeln('error: ${error.message}');
    exitCode = 2;
  } on HarnessException catch (error) {
    stderr.writeln(
      'error: protocol check failed: ${_safeMessage(error.message)}',
    );
    exitCode = 2;
  } catch (_) {
    stderr.writeln('error: protocol check failed without exposing host data.');
    exitCode = 2;
  } finally {
    try {
      await client?.dispose().timeout(const Duration(seconds: 5));
    } catch (_) {
      // Exit status from the actual check is more useful than close errors.
    }
    capability = null;
  }
}

final class _Options {
  const _Options({
    required this.host,
    required this.fromStdin,
    required this.send,
    required this.countMarker,
  });
  final String? host;
  final bool fromStdin;
  final bool send;
  final String? countMarker;

  static _Options parse(List<String> args) {
    String? host;
    var fromStdin = false;
    var send = false;
    String? countMarker;
    for (var index = 0; index < args.length; index++) {
      switch (args[index]) {
        case '--help' || '-h':
          stdout.writeln(
            'Usage: dart run tool/collab_smoke.dart '
            '(--host ID_OR_PID | --stdin) [--send] '
            '[--count-marker RAIJU_NUMBER]\n'
            'Handshake and history are checked by default. --send performs one '
            'harmless marker round-trip.',
          );
          exit(0);
        case '--host':
          if (++index >= args.length || args[index].trim().isEmpty) {
            throw const _UsageError('--host requires an instance ID or PID.');
          }
          host = args[index].trim();
        case '--stdin':
          fromStdin = true;
        case '--send':
          send = true;
        case '--count-marker':
          if (++index >= args.length ||
              !RegExp(r'^RAIJU_[0-9]+$').hasMatch(args[index])) {
            throw const _UsageError(
              '--count-marker requires a synthetic RAIJU_NUMBER marker.',
            );
          }
          countMarker = args[index];
        default:
          throw _UsageError('Unknown option "${args[index]}".');
      }
    }
    if ((host == null) == !fromStdin) {
      throw const _UsageError(
        'Choose exactly one of --host ID_OR_PID or --stdin.',
      );
    }
    return _Options(
      host: host,
      fromStdin: fromStdin,
      send: send,
      countMarker: countMarker,
    );
  }
}

Future<String> _acquireCapability(String host) async {
  final result = await Process.run('omp', [
    'collab',
    'link',
    host,
    '--json',
  ]).timeout(const Duration(seconds: 15));
  if (result.exitCode != 0) {
    throw const _SmokeError(
      'Could not acquire that host link. Run `omp collab list --json` and select an active host.',
    );
  }
  try {
    final value = jsonDecode(result.stdout as String);
    if (value is Map && value['url'] is String) {
      final url = (value['url'] as String).trim();
      if (url.isNotEmpty) return url;
    }
  } catch (_) {
    // Never echo stdout: a malformed response can still contain a capability.
  }
  throw const _SmokeError('OMP returned an invalid collab link response.');
}

Future<String> _readCapabilityFromStdin() async {
  final value =
      (await utf8.decoder
              .bind(stdin)
              .timeout(const Duration(seconds: 30))
              .join())
          .trim();
  if (value.isEmpty) {
    throw const _UsageError('--stdin received no collab link.');
  }
  return value;
}

Future<HarnessSnapshot> _waitForMarker(
  HarnessClient client,
  String marker,
) async {
  bool matches(HarnessSnapshot snapshot) => snapshot.messages.any(
    (message) =>
        message.role == MessageRole.assistant &&
        !message.isStreaming &&
        message.text.contains(marker),
  );
  if (matches(client.snapshot)) return client.snapshot;
  return client.changes.firstWhere(matches);
}

String _safeMessage(String message) {
  final lower = message.toLowerCase();
  if (lower.contains('/r/') ||
      lower.contains('token') ||
      lower.contains('key')) {
    return 'the host rejected or closed the protected session.';
  }
  return message.length <= 240 ? message : '${message.substring(0, 240)}…';
}

final class _UsageError implements Exception {
  const _UsageError(this.message);
  final String message;
}

final class _SmokeError implements Exception {
  const _SmokeError(this.message);
  final String message;
}
