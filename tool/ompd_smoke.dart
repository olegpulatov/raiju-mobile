import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/harness/ompd_api.dart';
import 'package:raiju_mobile/harness/ompd_client.dart';
import 'package:raiju_mobile/harness/ompd_connection.dart';

const _limit = Duration(seconds: 10);
const _mainId = 'synthetic-main';
const _resumeId = 'synthetic-resume';

/// Real ompd interoperability, deliberately without OMP or any model provider.
Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 &&
      (arguments.single == '--help' || arguments.single == '-h')) {
    stdout.writeln(
      '''usage: node scripts/flutter-tool.mjs dart run tool/ompd_smoke.dart --daemon /path/to/ompd

launches only the specified ompd binary on an isolated loopback high port.
uses temporary config/state and a synthetic Dart RPC v1 worker, never OMP,
credentials, real sessions, or a model. checks status/start/readiness, attach,
state/history, send/prompt events, takeover, resume, and reconnect without
worker restart or prompt replay. removes its own processes and temp files.
this is real-daemon wire evidence, not real-model or OMP persistence evidence.''',
    );
    return;
  }
  if (arguments.length != 2 || arguments.first != '--daemon') {
    stderr.writeln('usage: ompd_smoke.dart --daemon /path/to/ompd (or --help)');
    exitCode = 64;
    return;
  }

  Directory? temporary;
  Process? daemon;
  Future<int>? daemonExit;
  final clients = <OmpdClient>[];
  final wires = <_Wire>[];
  final signals = <StreamSubscription<ProcessSignal>>[];
  Timer? watchdog;
  var interrupted = false;
  Object? failure;
  var completed = false;
  try {
    final executable = await File(arguments.last).resolveSymbolicLinks();
    final worker = File.fromUri(
      Platform.script.resolve('ompd_fixture_worker.dart'),
    ).absolute.path;
    _require(await File(worker).exists(), 'synthetic worker source missing');
    temporary = await Directory.systemTemp.createTemp('raiju-ompd-smoke-');
    // macOS temp paths may traverse /var -> /private/var. Match ompd's
    // canonical session identity rather than comparing two aliases of one file.
    temporary = Directory(await temporary.resolveSymbolicLinks());
    final root = temporary.path;
    final audit = File('$root/audit.jsonl');
    final mainSession = File('$root/main.json');
    final resumedSession = File('$root/resume.json');
    await mainSession.writeAsString(
      jsonEncode({
        'synthetic': true,
        'id': _mainId,
        'name': 'synthetic main',
        'messages': [],
      }),
    );
    await resumedSession.writeAsString(
      jsonEncode({
        'synthetic': true,
        'id': _resumeId,
        'name': 'synthetic resumed',
        'messages': [
          {
            'role': 'user',
            'content': 'synthetic saved question',
            'timestamp': 1790000000000,
          },
          _assistant('synthetic saved answer'),
        ],
      }),
    );
    final wrapper = File('$root/worker');
    await wrapper.writeAsString(
      '#!/bin/sh\nexec ${_quote(Platform.resolvedExecutable)} '
      '${_quote(worker)} "\$@"\n',
    );
    final chmod = await Process.run('/bin/chmod', ['700', wrapper.path]);
    _require(chmod.exitCode == 0, 'cannot make synthetic worker executable');
    final reservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final port = reservation.port;
    _require(port >= 1024, 'expected unprivileged loopback port');
    final endpoint = OmpdEndpoint.parse('127.0.0.1:$port');
    final config = File('$root/profiles.toml');
    await config.writeAsString('''listen = "127.0.0.1:$port"
state-dir = ${jsonEncode('$root/state')}
[supervisor]
stop-timeout-secs = 2
ready-timeout-secs = 10
[profiles.synthetic]
cwd = ${jsonEncode(root)}
executable = ${jsonEncode(wrapper.path)}
restart = "never"
env = { RAIJU_OMPD_FIXTURE_SESSION = ${jsonEncode(mainSession.path)}, RAIJU_OMPD_FIXTURE_AUDIT = ${jsonEncode(audit.path)} }
''');
    // No inherited auth/provider environment and no user configuration lookup.
    await reservation.close();
    daemon = await Process.start(
      executable,
      [
        '--config',
        config.path,
        'daemon',
        '--listen',
        endpoint.toString(),
        '--state-dir',
        '$root/state',
      ],
      environment: {
        'HOME': root,
        'XDG_CONFIG_HOME': '$root/config',
        'XDG_STATE_HOME': '$root/state',
        'PATH': '/usr/bin:/bin',
      },
      includeParentEnvironment: false,
    );
    var exited = false;
    daemonExit = daemon.exitCode.then((code) {
      exited = true;
      return code;
    });
    // The acknowledgement comes from our child, not a potentially raced port.
    // Discard all other output; no daemon transcripts or environment are logged.
    final listening = Completer<void>();
    unawaited(daemon.stdout.drain<void>());
    daemon.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line == 'ompd listening on $endpoint' &&
                !listening.isCompleted) {
              listening.complete();
            }
          },
          onError: (Object _) {
            if (!listening.isCompleted) {
              listening.completeError(
                StateError('cannot read owned daemon startup'),
              );
            }
          },
        );
    void interrupt() {
      interrupted = true;
      daemon?.kill(ProcessSignal.sigterm);
    }

    signals.add(ProcessSignal.sigint.watch().listen((_) => interrupt()));
    signals.add(ProcessSignal.sigterm.watch().listen((_) => interrupt()));
    watchdog = Timer(const Duration(seconds: 90), interrupt);
    const api = OmpdApi(timeout: _limit, readinessTimeout: _limit);
    await Future.any<void>([
      listening.future,
      daemonExit.then<void>(
        (code) => throw StateError(
          'owned daemon exited before listener (code $code)',
        ),
      ),
    ]).timeout(_limit);
    _require(!exited && !interrupted, 'owned daemon did not acquire listener');
    _require(
      (await api.status(endpoint)).isEmpty,
      'isolated daemon is not empty',
    );
    await api.start(endpoint, name: 'main', profile: 'synthetic');
    await api.waitUntilReady(endpoint, 'main');
    await _wait('supervisor session metadata', () async {
      final state = _map(
        await _call(endpoint, {'method': 'status', 'name': 'main'}),
      );
      final session = _map(state['session']);
      return session['id'] == _mainId && session['file'] == mainSession.path;
    });
    final before = _map(
      await _call(endpoint, {'method': 'status', 'name': 'main'}),
    );
    final connection = OmpdConnection(
      endpoint: endpoint,
      instance: 'main',
      sessionId: _mainId,
      sessionFile: _map(before['session'])['file'] as String,
      trustedNetwork: true,
    ).encode();
    final first = OmpdClient(timeout: _limit);
    clients.add(first);
    await first.connect(connection).timeout(_limit);
    _require(
      first.snapshot.canSend && first.snapshot.sessionId == _mainId,
      'production client did not attach and load state/history',
    );
    final viewer = await _Wire.open(endpoint);
    wires.add(viewer);
    final attachment = _map(
      await viewer.control({
        'method': 'attach',
        'name': 'main',
        'mode': 'view',
      }),
    );
    _require(
      attachment['mode'] == 'view' && attachment['ready'] == true,
      'view attach did not preserve readiness',
    );

    for (final command in ['get_state', 'get_messages']) {
      final sent = _map(
        await _call(endpoint, {
          'method': 'send',
          'name': 'main',
          'request': {'id': command, 'type': command},
        }),
      );
      _require(
        sent['sent'] == true && sent['id'] == '${sent['client_id']}:$command',
        'one-shot send did not return its prefixed correlation id',
      );
      final response = await viewer.until((frame) => frame['id'] == sent['id']);
      _require(
        response['type'] == 'response' &&
            response['success'] == true &&
            response['command'] == command,
        '$command RPC shape mismatch',
      );
      if (command == 'get_state') {
        _require(
          _map(response['data'])['sessionId'] == _mainId,
          'get_state did not expose synthetic session',
        );
      } else {
        _require(
          _map(response['data'])['messages'] is List,
          'get_messages did not expose messages array',
        );
      }
    }
    final sent = _map(
      await _call(endpoint, {
        'method': 'send',
        'name': 'main',
        'request': {
          'id': 'send-prompt',
          'type': 'prompt',
          'message': 'synthetic-send',
        },
      }),
    );
    await _promptEvents(viewer, sent['id'] as String);
    await _hasReply(first, 'synthetic-send');
    await first.sendPrompt('synthetic-client').timeout(_limit);
    await _hasReply(first, 'synthetic-client');
    _require(
      first.snapshot.agentEvents.any((event) => event.type == 'agent_end'),
      'production client missed prompt events',
    );

    final second = OmpdClient(timeout: _limit);
    clients.add(second);
    await second.connect(connection).timeout(_limit);
    await _wait('controller takeover', () async => first.snapshot.readOnly);
    _require(second.snapshot.canSend, 'new controller is not writable');
    var rejected = false;
    try {
      await first.sendPrompt('must-not-reach-worker').timeout(_limit);
    } on HarnessException {
      rejected = true;
    }
    _require(rejected, 'displaced controller allowed prompt');
    await second.sendPrompt('synthetic-takeover').timeout(_limit);
    await _hasReply(second, 'synthetic-takeover');
    await first.disconnect().timeout(_limit);
    await second.disconnect().timeout(_limit);
    await viewer.close();
    final eventBoundary = first.snapshot.agentEvents.last.sequence;
    // A disconnected worker remains independently usable. No stream replay exists.
    await _call(endpoint, {
      'method': 'send',
      'name': 'main',
      'request': {
        'id': 'offline',
        'type': 'prompt',
        'message': 'synthetic-offline',
      },
    });
    await _wait('disconnected prompt completion', () async {
      final rows = await _audit(audit);
      return rows.any(
        (row) =>
            row['event'] == 'completed' &&
            row['message'] == 'synthetic-offline',
      );
    });
    await first.connect(connection).timeout(_limit);
    await _hasReply(first, 'synthetic-offline');
    _require(
      !first.snapshot.agentEvents.any(
        (event) =>
            event.sequence > eventBoundary &&
            const [
              'agent_start',
              'agent_end',
              'message_start',
              'message_update',
              'message_end',
              'prompt_result',
            ].contains(event.type),
      ),
      'reconnect replayed historical live events',
    );
    final after = _map(
      await _call(endpoint, {'method': 'status', 'name': 'main'}),
    );
    _require(
      before['pid'] == after['pid'] &&
          before['generation'] == after['generation'] &&
          after['restart_count'] == 0,
      'disconnect/reconnect restarted worker',
    );
    final rows = await _audit(audit);
    _require(
      rows.where((row) => row['event'] == 'started').length == 1 &&
          rows.every((row) => row['event'] != 'stopped') &&
          rows.where((row) => row['event'] == 'prompt').length == 4 &&
          rows.every((row) => row['message'] != 'must-not-reach-worker'),
      'worker audit found stop/start, prompt replay, or unauthorized prompt',
    );
    final productionId = RegExp(r'^c[0-9]+:r[0-9]+$');
    _require(
      rows.any(
            (row) =>
                row['event'] == 'get_state' &&
                productionId.hasMatch(row['id'] as String? ?? ''),
          ) &&
          rows.any(
            (row) =>
                const [
                  'get_messages',
                  'get_messages_page',
                ].contains(row['event']) &&
                productionId.hasMatch(row['id'] as String? ?? ''),
          ),
      'production state/history path was not exercised',
    );

    await api.start(
      endpoint,
      name: 'resumed',
      profile: 'synthetic',
      session: resumedSession.path,
    );
    await api.waitUntilReady(endpoint, 'resumed');
    final resumed = OmpdClient(timeout: _limit);
    clients.add(resumed);
    await resumed
        .connect(
          OmpdConnection(
            endpoint: endpoint,
            instance: 'resumed',
            sessionId: _resumeId,
            sessionFile: resumedSession.path,
            trustedNetwork: true,
          ).encode(),
        )
        .timeout(_limit);
    _require(
      resumed.snapshot.sessionId == _resumeId &&
          resumed.snapshot.messages.any(
            (message) => message.text == 'synthetic saved answer',
          ),
      'resume did not load known synthetic session history',
    );
    _require(
      (await _audit(audit)).any(
        (row) =>
            row['event'] == 'started' &&
            row['sessionId'] == _resumeId &&
            row['resume'] == resumedSession.path,
      ),
      'daemon did not pass exact --resume target to worker',
    );
    _require(!interrupted, 'smoke interrupted or exceeded total deadline');
    completed = true;
  } catch (error) {
    failure = error;
  } finally {
    watchdog?.cancel();
    for (final signal in signals) {
      await signal.cancel();
    }
    for (final client in clients) {
      try {
        await client.dispose().timeout(_limit);
      } catch (error) {
        failure ??= error;
      }
    }
    for (final wire in wires) {
      try {
        await wire.close();
      } catch (error) {
        failure ??= error;
      }
    }
    if (daemon != null && daemonExit != null) {
      // Signal only the Process handle we created, never a discovered PID or port.
      daemon.kill(ProcessSignal.sigterm);
      try {
        final code = await daemonExit.timeout(const Duration(seconds: 8));
        _require(code == 0, 'owned daemon exited with code $code');
      } catch (error) {
        failure ??= error;
        daemon.kill(ProcessSignal.sigkill);
        try {
          await daemonExit.timeout(_limit);
        } catch (_) {}
      }
      if (temporary != null) {
        final cleanupAudit = File('${temporary.path}/audit.jsonl');
        var started = 0;
        var stopped = 0;
        try {
          await _wait('owned worker cleanup', () async {
            final rows = await _audit(cleanupAudit);
            started = rows.where((row) => row['event'] == 'started').length;
            stopped = rows.where((row) => row['event'] == 'stopped').length;
            return started == stopped && (!completed || started == 2);
          });
        } catch (error) {
          failure ??= StateError(
            'owned worker cleanup: started=$started stopped=$stopped; $error',
          );
        }
      }
    }
    if (temporary != null) {
      try {
        await temporary.delete(recursive: true);
      } catch (error) {
        failure ??= error;
      }
    }
  }
  if (failure != null) {
    stderr.writeln('ompd synthetic smoke failed: $failure');
    exitCode = 1;
  } else {
    stdout.writeln(
      'ompd synthetic smoke passed: real daemon; synthetic RPC worker; '
      '0 model calls; state/history, prompt events, takeover, resume, '
      'reconnect without restart/replay, and cleanup verified',
    );
  }
}

Map<String, Object?> _assistant(String text) => {
  'role': 'assistant',
  'content': [
    {'type': 'text', 'text': text},
  ],
  'api': 'openai-responses',
  'provider': 'synthetic',
  'model': 'no-model',
  'usage': {
    'input': 0,
    'output': 0,
    'cacheRead': 0,
    'cacheWrite': 0,
    'totalTokens': 0,
    'cost': {
      'input': 0,
      'output': 0,
      'cacheRead': 0,
      'cacheWrite': 0,
      'total': 0,
    },
  },
  'stopReason': 'stop',
  'timestamp': 1790000000000,
};

String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";
Map<String, Object?> _map(Object? value) {
  _require(value is Map, 'expected JSON object');
  return Map<String, Object?>.from(value as Map);
}

void _require(bool accepted, String message) {
  if (!accepted) {
    throw StateError(message);
  }
}

Future<void> _wait(String stage, Future<bool> Function() accept) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < _limit) {
    if (await accept()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw TimeoutException(stage, _limit);
}

Future<void> _hasReply(OmpdClient client, String marker) => _wait(
  'synthetic reply',
  () async =>
      !client.snapshot.isStreaming &&
      client.snapshot.messages.any(
        (message) =>
            message.role == MessageRole.assistant &&
            message.text == 'synthetic reply: $marker',
      ),
);
Future<List<Map<String, Object?>>> _audit(File base) async {
  final rows = <Map<String, Object?>>[];
  final prefix = '${base.path}.';
  await for (final entity in base.parent.list(followLinks: false)) {
    if (entity is! File ||
        !entity.path.startsWith(prefix) ||
        !RegExp(r'^[0-9]+$').hasMatch(entity.path.substring(prefix.length))) {
      continue;
    }
    for (final line in await entity.readAsLines()) {
      if (line.isNotEmpty) {
        rows.add(_map(jsonDecode(line)));
      }
    }
  }
  return rows;
}

Future<Object?> _call(
  OmpdEndpoint endpoint,
  Map<String, Object?> request,
) async {
  final wire = await _Wire.open(endpoint);
  try {
    return await wire.control(request);
  } finally {
    await wire.close();
  }
}

Future<void> _promptEvents(_Wire viewer, String id) async {
  final types = <String>{};
  await viewer.until((frame) {
    types.add(frame['type'] as String? ?? '');
    if (frame['type'] == 'response' && frame['id'] == id) {
      _require(frame['success'] == true, 'prompt rejected');
    }
    return frame['type'] == 'prompt_result' &&
        frame['id'] == id &&
        frame['status'] == 'completed';
  });
  _require(
    types.containsAll([
      'response',
      'agent_start',
      'message_start',
      'message_update',
      'message_end',
      'agent_end',
      'prompt_result',
    ]),
    'prompt event sequence incomplete',
  );
}

final class _Wire {
  _Wire(this.socket)
    : frames = StreamIterator(
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );
  final Socket socket;
  final StreamIterator<String> frames;
  bool closed = false;
  static Future<_Wire> open(OmpdEndpoint endpoint) async => _Wire(
    await Socket.connect(endpoint.host, endpoint.port, timeout: _limit),
  );
  Future<Object?> control(Map<String, Object?> request) async {
    socket.writeln(jsonEncode(request));
    await socket.flush().timeout(_limit);
    final frame = await next();
    _require(
      !frame.containsKey('error'),
      'daemon rejected control request: ${frame['error']}',
    );
    _require(frame.containsKey('result'), 'daemon omitted result');
    return frame['result'];
  }

  Future<Map<String, Object?>> next() async {
    _require(await frames.moveNext().timeout(_limit), 'relay stream closed');
    return _map(jsonDecode(frames.current));
  }

  Future<Map<String, Object?>> until(
    bool Function(Map<String, Object?>) accept,
  ) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < _limit) {
      _require(
        await frames.moveNext().timeout(_limit - clock.elapsed),
        'relay stream closed',
      );
      final frame = _map(jsonDecode(frames.current));
      if (accept(frame)) {
        return frame;
      }
    }
    throw TimeoutException('relay event', _limit);
  }

  Future<void> close() async {
    if (closed) {
      return;
    }
    closed = true;
    socket.destroy();
    await frames.cancel();
  }
}
