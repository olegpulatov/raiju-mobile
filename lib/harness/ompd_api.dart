import 'dart:async';

import 'harness.dart';
import 'ompd_connection.dart';
import 'ompd_wire.dart';

class OmpdInstance {
  const OmpdInstance({
    required this.name,
    required this.state,
    required this.ready,
    required this.rpc,
    this.sessionId,
    this.sessionName,
    this.sessionFile,
    this.generation,
    this.sessionConflict = false,
  });

  final String name;
  final String state;
  final bool ready;
  final bool rpc;
  final String? sessionId;
  final String? sessionName;
  final String? sessionFile;
  final int? generation;
  final bool sessionConflict;

  static OmpdInstance fromJson(Object? value) {
    const invalid = HarnessException(
      'The relay returned invalid instance metadata.',
    );
    if (value is! Map ||
        value['name'] is! String ||
        value['state'] is! String ||
        value['ready'] is! bool ||
        value['rpc'] is! bool) {
      throw invalid;
    }
    final session = value['session'];
    if (session != null && session is! Map) throw invalid;
    final fields = session is Map ? session : const <String, Object?>{};
    for (final key in ['id', 'name', 'file', 'conflict']) {
      if (fields[key] != null && fields[key] is! String) throw invalid;
    }
    validateOmpdName(value['name'] as String);
    return OmpdInstance(
      name: value['name'] as String,
      state: value['state'] as String,
      ready: value['ready'] as bool,
      rpc: value['rpc'] as bool,
      sessionId: fields['id'] as String?,
      sessionName: fields['name'] as String?,
      sessionFile: fields['file'] as String?,
      sessionConflict: fields['conflict'] != null,
      generation: value['generation'] is int
          ? value['generation'] as int
          : null,
    );
  }
}

/// Requests never access workstation files or use one-shot RPC `send`.
class OmpdApi {
  const OmpdApi({
    this.timeout = const Duration(seconds: 10),
    this.readinessTimeout = const Duration(seconds: 30),
    this.pollInterval = const Duration(milliseconds: 250),
  });

  final Duration timeout;
  final Duration readinessTimeout;
  final Duration pollInterval;

  Future<List<OmpdInstance>> status(OmpdEndpoint endpoint) async {
    final result = await _request(endpoint, {'method': 'status'});
    if (result is! List) {
      throw const HarnessException(
        'The relay returned invalid status metadata.',
      );
    }
    return List.unmodifiable(result.map(OmpdInstance.fromJson));
  }

  Future<OmpdInstance> start(
    OmpdEndpoint endpoint, {
    required String name,
    String? profile,
    String? cwd,
    String? session,
  }) async {
    validateOmpdName(name);
    if (profile != null) validateOmpdName(profile);
    if (profile == null && (cwd == null || !cwd.startsWith('/'))) {
      throw const HarnessException(
        'Choose a profile or enter an absolute remote working directory.',
      );
    }
    for (final value in [cwd, session]) {
      if (value != null &&
          (value.trim().isEmpty ||
              value.length > 4096 ||
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(value))) {
        throw const HarnessException(
          'Invalid remote directory or session reference.',
        );
      }
    }
    if (cwd != null && !cwd.startsWith('/')) {
      throw const HarnessException(
        'Enter an absolute remote working directory.',
      );
    }
    final instance = OmpdInstance.fromJson(
      await _request(endpoint, {
        'method': 'start',
        'name': name,
        'profile': ?profile,
        'cwd': ?cwd,
        'session': ?session,
      }),
    );
    if (instance.name != name) {
      throw const HarnessException(
        'The relay returned a different instance. Refresh status before attaching.',
      );
    }
    return instance;
  }

  Future<OmpdInstance> waitUntilReady(
    OmpdEndpoint endpoint,
    String name,
  ) async {
    validateOmpdName(name);
    final elapsed = Stopwatch()..start();
    while (elapsed.elapsed < readinessTimeout) {
      final remaining = readinessTimeout - elapsed.elapsed;
      final instance = OmpdInstance.fromJson(
        await _request(endpoint, {
          'method': 'status',
          'name': name,
        }, limit: remaining < timeout ? remaining : timeout),
      );
      if (instance.name != name) {
        throw const HarnessException(
          'The relay returned a different instance. Refresh status before attaching.',
        );
      }
      if (instance.sessionConflict) {
        throw const HarnessException(
          'Another instance owns this session. Choose its running instance.',
        );
      }
      if (instance.ready) {
        if (!instance.rpc) {
          throw const HarnessException(
            'This instance does not support RPC attachment.',
          );
        }
        // Ready stdout can precede ompd's asynchronous session metadata poll.
        if (instance.sessionId != null &&
            instance.sessionId!.isNotEmpty &&
            instance.sessionFile != null &&
            instance.sessionFile!.isNotEmpty) {
          return instance;
        }
      }
      if (['exited', 'failed', 'stopped'].contains(instance.state)) {
        throw const HarnessException(
          'The relay worker stopped before it became ready. Check it on the workstation.',
        );
      }
      final delay = readinessTimeout - elapsed.elapsed;
      if (delay <= Duration.zero) break;
      await Future<void>.delayed(delay < pollInterval ? delay : pollInterval);
    }
    throw const HarnessException(
      'The relay worker did not become ready in time. Check it on the workstation.',
    );
  }

  Future<Object?> _request(
    OmpdEndpoint endpoint,
    Map<String, Object?> request, {
    Duration? limit,
  }) async {
    final bound = limit ?? timeout;
    final elapsed = Stopwatch()..start();
    Duration remaining() {
      final duration = bound - elapsed.elapsed;
      if (duration <= Duration.zero) {
        throw TimeoutException('relay control deadline');
      }
      return duration;
    }

    OmpdWire? wire;
    StreamIterator<Map<String, Object?>>? iterator;
    try {
      wire = await OmpdWire.connect(
        endpoint,
        timeout: remaining(),
        maxFrameBytes: 8 * 1024 * 1024,
      );
      iterator = StreamIterator(wire.frames);
      await wire.send(request).timeout(remaining());
      if (!await iterator.moveNext().timeout(remaining())) {
        throw const HarnessException('The relay closed before answering.');
      }
      final response = iterator.current;
      if (response.containsKey('error')) {
        throw const HarnessException(
          'The relay rejected this operation. Check instance, profile, and session on the workstation.',
        );
      }
      if (!response.containsKey('result')) {
        throw const HarnessException(
          'The relay sent an invalid control response.',
        );
      }
      return response['result'];
    } on HarnessException {
      rethrow;
    } on TimeoutException {
      throw const HarnessException('The relay did not answer in time.');
    } catch (_) {
      throw const HarnessException(
        'The relay operation failed. Check the connection on the workstation.',
      );
    } finally {
      await iterator?.cancel();
      await wire?.close();
    }
  }
}
