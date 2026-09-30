import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

const _smokeTarget = 'integration_test/raiju_smoke_test.dart';
const _sparkSmokeTarget = 'integration_test/spark_smoke_test.dart';
const _liveTarget = 'integration_test/raiju_live_test.dart';
const _sparkLiveTarget = 'integration_test/spark_live_test.dart';
const _bundleId = 'dev.raiju.mobile';
const _normalAppPath = 'build/ios/iphonesimulator/Raiju.app';
const _acceptanceDraft = 'live smoke draft (safe to discard)';
const _acceptanceProbeFileName = 'raiju-acceptance-probe.json';

Future<void> main(List<String> arguments) async {
  try {
    final options = _Options.parse(arguments);
    if (!Platform.isMacOS) {
      throw const _CliError(
        'iOS simulator workflows require macOS with Xcode command-line tools.',
      );
    }
    final childBaseEnvironment = options.command == 'spark-live'
        ? _withoutSparkSecrets(Platform.environment)
        : Map<String, String>.of(Platform.environment);
    final sparkBuildCode = await _runInherited(
      'node',
      const ['scripts/build-spark-ios.mjs', 'debug'],
      timeout: const Duration(minutes: 10),
      environment: childBaseEnvironment,
      includeParentEnvironment: false,
    );
    if (sparkBuildCode != 0) {
      throw const _CliError('Spark iOS library build failed.');
    }
    final needsSimulator = options.command != 'build';
    final device = needsSimulator
        ? await _selectSimulator(options.deviceId)
        : null;
    final flutter = Platform.environment['FLUTTER']?.trim().isNotEmpty == true
        ? Platform.environment['FLUTTER']!.trim()
        : 'flutter';
    await _requireCommand(
      flutter,
      const ['--version'],
      'Flutter',
      timeout: const Duration(minutes: 2),
      environment: childBaseEnvironment,
      includeParentEnvironment: false,
    );
    final nativeEnvironment = await _prepareCocoaPodsEnvironment(
      childBaseEnvironment,
      includeParentEnvironment: options.command != 'spark-live',
    );

    if (options.command == 'build') {
      exitCode = await _runInherited(
        flutter,
        const ['build', 'ios', '--simulator', '--debug'],
        timeout: const Duration(minutes: 10),
        environment: nativeEnvironment,
      );
      return;
    }

    switch (options.command) {
      case 'run':
        exitCode = await _runInherited(flutter, [
          'run',
          '-d',
          device!.udid,
        ], environment: nativeEnvironment);
      case 'smoke':
        exitCode = await _runInherited(
          flutter,
          [
            'drive',
            '--driver=test_driver/integration_test.dart',
            '--target=$_smokeTarget',
            '--keep-app-running',
            '-d',
            device!.udid,
          ],
          timeout: const Duration(minutes: 10),
          environment: nativeEnvironment,
        );
      case 'spark-smoke':
        exitCode = await _runInherited(
          flutter,
          [
            'drive',
            '--driver=test_driver/integration_test.dart',
            '--target=$_sparkSmokeTarget',
            '--keep-app-running',
            '-d',
            device!.udid,
          ],
          timeout: const Duration(minutes: 10),
          environment: nativeEnvironment,
        );
      case 'spark-live':
        final runtime = _sparkLiveRuntimeFromEnvironment();
        await _runChecked(
          'xcrun',
          ['simctl', 'privacy', device!.udid, 'grant', 'microphone', _bundleId],
          'Could not grant microphone permission to the designated simulator.',
        );
        final runtimeServer = await _serveSparkRuntimeOnce(runtime);
        final childEnvironment = Map<String, String>.of(nativeEnvironment);
        try {
          exitCode = await _runRedacted(
            flutter,
            [
              'drive',
              '--driver=test_driver/integration_test.dart',
              '--target=$_sparkLiveTarget',
              '--keep-app-running',
              '-d',
              device.udid,
              '--dart-define=SPARK_LIVE_IPC_PORT=${runtimeServer.port}',
            ],
            secrets: [runtime.token],
            timeout: const Duration(minutes: 10),
            environment: childEnvironment,
            includeParentEnvironment: false,
          );
        } finally {
          await _closeServer(runtimeServer);
          await _runCaptured(
            'xcrun',
            ['simctl', 'terminate', device.udid, _bundleId],
            environment: childEnvironment,
            includeParentEnvironment: false,
          );
        }
      case 'live':
        final host = options.host!;
        final capability = await _acquireCapability(host);
        final marker = 'RAIJU_${DateTime.now().toUtc().microsecondsSinceEpoch}';
        final capabilityServer = await _serveCapabilityOnce(capability);
        try {
          exitCode = await _runRedacted(
            flutter,
            [
              'drive',
              '--driver=test_driver/integration_test.dart',
              '--target=$_liveTarget',
              '--keep-app-running',
              '-d',
              device!.udid,
              '--dart-define=RAIJU_LIVE_MARKER=$marker',
            ],
            secrets: [capability],
            timeout: const Duration(minutes: 10),
            environment: nativeEnvironment,
          );
          if (exitCode == 0) {
            await _verifyNormalProcessRestore(
              flutter: flutter,
              device: device,
              capability: capability,
              host: host,
              marker: marker,
              environment: nativeEnvironment,
            );
          }
        } finally {
          await _closeServer(capabilityServer);
        }
    }
  } on _CliError catch (error) {
    stderr.writeln('error: ${error.message}');
    exitCode = error.exitCode;
  } on ProcessException catch (error) {
    stderr.writeln(
      'error: could not start ${error.executable}. Is it installed and on PATH?',
    );
    exitCode = 127;
  } catch (error) {
    stderr.writeln('error: ${_redact(error.toString(), const [])}');
    exitCode = 1;
  }
}

final class _Options {
  const _Options(this.command, this.deviceId, this.host);
  final String command;
  final String? deviceId;
  final String? host;

  static _Options parse(List<String> args) {
    if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
      stdout.writeln(
        'Usage: dart run tool/ios_dev.dart <build|run|smoke|spark-smoke|spark-live|live> '
        '[HOST] [--device UDID] [--host HOST]\n'
        '  build       Create a signed debug simulator build without booting a device.\n'
        '  run         Boot/select an iPhone simulator and launch the app.\n'
        '  smoke       Run the deterministic native GUI integration journey.\n'
        '  spark-smoke Run the synthetic Spark voice and delegation journey.\n'
        '  spark-live  Opt-in production native voice/provider check.\n'
        '  live        Opt-in real-host GUI check; requires positional HOST or --host.',
      );
      if (args.isEmpty) {
        throw const _CliError(
          'Choose build, run, smoke, spark-smoke, spark-live, or live.',
        );
      }
      exit(0);
    }
    final command = args.first;
    if (!const {
      'build',
      'run',
      'smoke',
      'spark-smoke',
      'live',
      'spark-live',
    }.contains(command)) {
      throw _CliError(
        'Unknown command "$command". Expected build, run, smoke, spark-smoke, spark-live, or live.',
      );
    }
    String? device;
    String? host;
    for (var index = 1; index < args.length; index++) {
      final flag = args[index];
      if (command == 'live' && !flag.startsWith('-') && host == null) {
        host = flag.trim();
        continue;
      }
      if (flag != '--device' && flag != '--host') {
        throw _CliError('Unknown option "$flag".', 64);
      }
      if (++index >= args.length || args[index].trim().isEmpty) {
        throw _CliError('$flag requires a value.', 64);
      }
      if (flag == '--device') device = args[index].trim();
      if (flag == '--host') {
        if (host != null) {
          throw const _CliError('Specify the live host once.', 64);
        }
        host = args[index].trim();
      }
    }
    if (command == 'live' && host == null) {
      throw const _CliError(
        'live requires HOST from `omp collab list --json`.',
        64,
      );
    }
    if (command != 'live' && host != null) {
      throw const _CliError('--host is valid only with live.', 64);
    }
    return _Options(command, device, host);
  }
}

final class _Simulator {
  const _Simulator(this.udid, this.name, this.state);
  final String udid;
  final String name;
  final String state;
}

Future<_Simulator> _selectSimulator(String? requested) async {
  await _requireCommand('xcrun', const ['--find', 'simctl'], 'Xcode simctl');
  final result = await _runCaptured('xcrun', const [
    'simctl',
    'list',
    'devices',
    '--json',
  ]);
  if (result.exitCode != 0) {
    throw const _CliError(
      'Could not list iOS simulators. Open Xcode and install an iOS Simulator runtime.',
    );
  }
  final decoded = jsonDecode(result.stdout) as Map<String, dynamic>;
  final runtimes = decoded['devices'];
  if (runtimes is! Map) {
    throw const _CliError('simctl returned an unexpected device list.');
  }
  final devices = <_Simulator>[];
  for (final value in runtimes.values) {
    if (value is! List) continue;
    for (final raw in value) {
      if (raw is! Map) continue;
      final name = raw['name'];
      final udid = raw['udid'];
      final state = raw['state'];
      final available =
          raw['isAvailable'] != false && raw['availabilityError'] == null;
      if (available &&
          name is String &&
          name.contains('iPhone') &&
          udid is String &&
          state is String) {
        devices.add(_Simulator(udid, name, state));
      }
    }
  }
  _Simulator? selected;
  if (requested != null) {
    selected = devices.where((item) => item.udid == requested).firstOrNull;
    if (selected == null) {
      throw _CliError(
        'Requested iPhone simulator $requested is not available.',
      );
    }
  } else {
    selected = devices.where((item) => item.state == 'Booted').firstOrNull;
    selected ??= devices.firstOrNull;
  }
  if (selected == null) {
    throw const _CliError(
      'No available iPhone simulator was found. Install one in Xcode Settings > Platforms.',
    );
  }
  if (selected.state != 'Booted') {
    final boot = await _runCaptured('xcrun', ['simctl', 'boot', selected.udid]);
    if (boot.exitCode != 0) {
      throw _CliError('Could not boot iPhone simulator ${selected.name}.');
    }
    final ready = await _runCaptured('xcrun', [
      'simctl',
      'bootstatus',
      selected.udid,
      '-b',
    ], timeout: const Duration(minutes: 2));
    if (ready.exitCode != 0) {
      throw _CliError('Simulator ${selected.name} did not finish booting.');
    }
  }
  stdout.writeln('Using ${selected.name} (${selected.udid}).');
  return selected;
}

Future<String> _acquireCapability(String host) async {
  await _requireCommand('omp', const ['--version'], 'OMP');
  final result = await _runCaptured('omp', ['collab', 'link', host, '--json']);
  if (result.exitCode != 0) {
    final safe = _redact(result.stderr, const []);
    throw _CliError(
      'Could not acquire the selected OMP host link'
      '${safe.trim().isEmpty ? '.' : ': ${safe.trim()}'}',
    );
  }
  try {
    final decoded = jsonDecode(result.stdout);
    if (decoded is Map && decoded['url'] is String) {
      final url = (decoded['url'] as String).trim();
      if (url.isNotEmpty) return url;
    }
  } catch (_) {
    // Fall through to the intentionally generic error; stdout may be secret.
  }
  throw const _CliError('OMP returned an invalid collab link response.');
}

Future<ServerSocket> _serveCapabilityOnce(String capability) async {
  final server = await ServerSocket.bind(
    InternetAddress.loopbackIPv4,
    38471,
    shared: false,
  );
  late final StreamSubscription<Socket> subscription;
  subscription = server.listen((socket) {
    unawaited(() async {
      try {
        await subscription.cancel().timeout(const Duration(seconds: 2));
        socket.write(capability);
        await socket.flush().timeout(const Duration(seconds: 2));
      } catch (_) {
        // The live driver reports a failed or incomplete capability handoff.
      } finally {
        socket.destroy();
      }
    }());
  });
  return server;
}

Future<void> _closeServer(ServerSocket server) async {
  try {
    await server.close().timeout(const Duration(seconds: 2));
  } on TimeoutException {
    // A stalled socket shutdown must not keep the helper alive.
  }
}

final class _SparkLiveRuntime {
  const _SparkLiveRuntime({
    required this.brokerUrl,
    required this.token,
    required this.allowInsecureHttp,
    required this.muteTiming,
  });
  final String brokerUrl;
  final String token;
  final bool allowInsecureHttp;
  final String muteTiming;
}

Map<String, String> _withoutSparkSecrets(Map<String, String> source) =>
    Map<String, String>.of(source)
      ..remove('SPARK_BROKER_TOKEN')
      ..remove('OMP_AUTH_BROKER_TOKEN')
      ..remove('SPARK_ACCESS_TOKEN')
      ..remove('SPARK_ACCOUNT_ID');
_SparkLiveRuntime _sparkLiveRuntimeFromEnvironment() {
  final environment = Platform.environment;
  if (environment['SPARK_LIVE'] != '1') {
    throw const _CliError('spark-live requires explicit SPARK_LIVE=1 opt-in.');
  }
  final token =
      (environment['SPARK_BROKER_TOKEN'] ??
              environment['OMP_AUTH_BROKER_TOKEN'] ??
              '')
          .trim();
  if (token.isEmpty) {
    throw const _CliError(
      'spark-live requires an inherited broker token at runtime.',
    );
  }
  final brokerUrl =
      (environment['SPARK_BROKER_URL'] ??
              environment['OMP_AUTH_BROKER_URL'] ??
              'http://studio.home.arpa:8765')
          .trim();
  final broker = Uri.tryParse(brokerUrl);
  if (broker == null ||
      !broker.hasAuthority ||
      broker.host.isEmpty ||
      broker.userInfo.isNotEmpty ||
      (broker.path.isNotEmpty && broker.path != '/') ||
      broker.hasQuery ||
      broker.hasFragment ||
      (broker.scheme != 'https' && broker.scheme != 'http')) {
    throw const _CliError('spark-live broker URL must be an HTTP(S) origin.');
  }
  final allowHttp = environment['SPARK_ALLOW_HTTP'] == '1';
  if (broker.scheme == 'http' && !allowHttp) {
    throw const _CliError(
      'spark-live plaintext broker access requires SPARK_ALLOW_HTTP=1.',
    );
  }
  final muteTiming =
      (environment['SPARK_LIVE_MUTE_TIMING'] ?? 'after-connection').trim();
  if (muteTiming != 'before-connection' && muteTiming != 'after-connection') {
    throw const _CliError(
      'SPARK_LIVE_MUTE_TIMING must be before-connection or after-connection.',
    );
  }
  return _SparkLiveRuntime(
    brokerUrl: brokerUrl,
    token: token,
    allowInsecureHttp: allowHttp,
    muteTiming: muteTiming,
  );
}

Future<ServerSocket> _serveSparkRuntimeOnce(_SparkLiveRuntime runtime) async {
  final payload = jsonEncode({
    'brokerUrl': runtime.brokerUrl,
    'token': runtime.token,
    'allowInsecureHttp': runtime.allowInsecureHttp,
    'muteTiming': runtime.muteTiming,
  });
  final server = await ServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    shared: false,
  );
  late final StreamSubscription<Socket> subscription;
  subscription = server.listen((socket) {
    unawaited(() async {
      try {
        await subscription.cancel().timeout(const Duration(seconds: 2));
        socket.write(payload);
        await socket.flush().timeout(const Duration(seconds: 2));
      } catch (_) {
        // The live fixture reports a failed or incomplete private handoff.
      } finally {
        socket.destroy();
      }
    }());
  });
  return server;
}

Future<void> _verifyNormalProcessRestore({
  required String flutter,
  required _Simulator device,
  required String capability,
  required String host,
  required String marker,
  required Map<String, String> environment,
}) async {
  final markerCountBefore = await _readMarkerCount(capability, marker);
  final expectedDraftDigest = sha256
      .convert(utf8.encode(_acceptanceDraft))
      .toString();
  final expectedReplyDigest = sha256.convert(utf8.encode(marker)).toString();
  // The live app seeds these local-only fields; relative sequences allow
  // another run to coexist with older voice turns on the same chat.
  final expectedVoiceDigest = sha256
      .convert(
        utf8.encode(
          jsonEncode([
            [
              'raiju-acceptance-$expectedReplyDigest-1',
              0,
              'user',
              'Synthetic spoken request, not delegated',
              'pending',
              null,
              null,
            ],
            [
              'raiju-acceptance-$expectedReplyDigest-2',
              1,
              'spark',
              'Synthetic local voice response',
              'pending',
              null,
              null,
            ],
            [
              'raiju-acceptance-$expectedReplyDigest-3',
              2,
              'user',
              'Synthetic spoken follow-up, not delegated',
              'uncertain',
              null,
              null,
            ],
          ]),
        ),
      )
      .toString();
  final buildCode = await _runInherited(
    flutter,
    [
      'build',
      'ios',
      '--simulator',
      '--debug',
      '--dart-define=RAIJU_ACCEPTANCE_PROBE=true',
      '--dart-define=RAIJU_EXPECTED_DRAFT_SHA256=$expectedDraftDigest',
      '--dart-define=RAIJU_EXPECTED_REPLY_SHA256=$expectedReplyDigest',
      '--dart-define=RAIJU_EXPECTED_VOICE_SHA256=$expectedVoiceDigest',
    ],
    timeout: const Duration(minutes: 10),
    environment: environment,
  );
  if (buildCode != 0) {
    throw const _CliError('Normal app build failed after the live journey.');
  }

  await _runCaptured('xcrun', ['simctl', 'terminate', device.udid, _bundleId]);
  await _runChecked('xcrun', [
    'simctl',
    'install',
    device.udid,
    _normalAppPath,
  ], 'Could not install the normal app build.');
  final staleProbe = await _acceptanceProbeFile(device.udid);
  if (await staleProbe.exists()) await staleProbe.delete();
  await _runChecked('xcrun', [
    'simctl',
    'launch',
    device.udid,
    _bundleId,
  ], 'Could not launch normal lib/main.dart in a new process.');

  final participantsAfter = await _readParticipantCount(host);
  final probe = await _waitForAcceptanceProbe(device.udid, expectedReplyDigest);

  final markerCountAfter = await _readMarkerCount(capability, marker);
  if (markerCountAfter != markerCountBefore) {
    throw _CliError(
      'Normal-app reconnect changed synthetic marker occurrences from '
      '$markerCountBefore to $markerCountAfter; possible prompt replay.',
    );
  }
  stdout.writeln(
    'instrumented-normal-main=ok participants=$participantsAfter '
    'markerCount=$markerCountAfter chats=${probe['chatCount']} '
    'messages=${probe['messageCount']}',
  );
}

Future<int> _readParticipantCount(String host) async {
  final result = await _runCaptured('omp', const ['collab', 'list', '--json']);
  if (result.exitCode != 0) {
    throw const _CliError('Could not inspect OMP participant state.');
  }
  try {
    final decoded = jsonDecode(result.stdout);
    final hosts = decoded is Map ? decoded['hosts'] : null;
    if (hosts is List) {
      for (final item in hosts) {
        if (item is Map &&
            (item['instanceId']?.toString() == host ||
                item['pid']?.toString() == host) &&
            item['participants'] is num) {
          return (item['participants'] as num).toInt();
        }
      }
    }
  } catch (_) {
    // Do not echo host metadata; it is not needed for diagnosis.
  }
  throw const _CliError('OMP participant state was unavailable.');
}

Future<int> _readMarkerCount(String capability, String marker) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    'tool/collab_smoke.dart',
    '--stdin',
    '--count-marker',
    marker,
  ]);
  final output = StringBuffer();
  final error = StringBuffer();
  final subscriptions = <StreamSubscription<String>>[
    process.stdout.transform(utf8.decoder).listen(output.write),
    process.stderr.transform(utf8.decoder).listen(error.write),
  ];
  final drains = subscriptions.map(_observeDrain).toList();
  int code;
  try {
    process.stdin.writeln(capability);
    await process.stdin.close().timeout(const Duration(seconds: 2));
    code = await process.exitCode.timeout(const Duration(minutes: 2));
  } on TimeoutException {
    await _stopProcess(process);
    await _settleOutput(subscriptions, drains);
    throw const _CliError('Timed out inspecting OMP history safely.');
  } catch (_) {
    await _stopProcess(process);
    await _settleOutput(subscriptions, drains);
    rethrow;
  }
  await _settleOutput(subscriptions, drains);
  final outputText = output.toString();
  final errorText = error.toString();
  if (code != 0) {
    throw _CliError(
      'Could not inspect OMP history safely: '
      '${_redact(errorText, [capability]).trim()}',
    );
  }
  final match = RegExp(r'\bmarkerCount=(\d+)\b').firstMatch(outputText);
  if (match == null) {
    throw const _CliError(
      'OMP marker-count check returned an unexpected result.',
    );
  }
  return int.parse(match.group(1)!);
}

Future<Map<String, Object?>> _waitForAcceptanceProbe(
  String udid,
  String expectedRunDigest,
) async {
  final file = await _acceptanceProbeFile(udid);
  final deadline = DateTime.now().add(const Duration(seconds: 50));
  try {
    while (DateTime.now().isBefore(deadline)) {
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map) {
          throw const _CliError('Acceptance probe returned invalid JSON.');
        }
        final result = decoded.cast<String, Object?>();
        if (result['runDigest'] != expectedRunDigest) {
          await file.delete();
          continue;
        }
        const requiredTrue = [
          'storageAvailable',
          'restoredSession',
          'draftDigestMatches',
          'transcriptDigestMatches',
          'voiceTextMatches',
          'voiceOriginMatches',
          'voiceDeliveryMatches',
          'voiceOrderingMatches',
          'voiceDigestMatches',
          'liveReconnect',
          'newProcess',
        ];
        final failed = requiredTrue
            .where((key) => result[key] != true)
            .toList();
        final chatCount = result['chatCount'];
        final messageCount = result['messageCount'];
        if (chatCount is! num || chatCount < 1) failed.add('chatCount');
        if (messageCount is! num || messageCount < 1) {
          failed.add('messageCount');
        }
        if (failed.isNotEmpty) {
          throw _CliError(
            'Normal-main probe failed safe fields: ${failed.join(', ')}.',
          );
        }
        return result;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw const _CliError(
      'Timed out waiting for normal-main acceptance probe.',
    );
  } finally {
    if (await file.exists()) await file.delete();
  }
}

Future<File> _acceptanceProbeFile(String udid) async {
  final container = await _runCaptured('xcrun', [
    'simctl',
    'get_app_container',
    udid,
    _bundleId,
    'data',
  ]);
  if (container.exitCode != 0) {
    throw const _CliError('Could not locate the normal app data container.');
  }
  final path =
      '${container.stdout.trim()}/Library/Application Support/'
      '$_acceptanceProbeFileName';
  return File(path);
}

final class _CapturedProcess {
  const _CapturedProcess(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final String stdout;
  final String stderr;
}

Future<_CapturedProcess> _runCaptured(
  String executable,
  List<String> args, {
  Map<String, String>? environment,
  Duration timeout = const Duration(seconds: 30),
  bool includeParentEnvironment = true,
}) async {
  final process = await Process.start(
    executable,
    args,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
  );
  final output = StringBuffer();
  final error = StringBuffer();
  final subscriptions = <StreamSubscription<String>>[
    process.stdout.transform(utf8.decoder).listen(output.write),
    process.stderr.transform(utf8.decoder).listen(error.write),
  ];
  final drains = subscriptions.map(_observeDrain).toList();
  try {
    final code = await process.exitCode.timeout(timeout);
    await _settleOutput(subscriptions, drains);
    return _CapturedProcess(code, output.toString(), error.toString());
  } on TimeoutException {
    await _stopProcess(process);
    await _settleOutput(subscriptions, drains);
    throw _CliError(
      '$executable did not finish within ${timeout.inSeconds} seconds.',
    );
  } catch (_) {
    await _stopProcess(process);
    await _settleOutput(subscriptions, drains);
    rethrow;
  }
}

Future<void> _runChecked(
  String executable,
  List<String> args,
  String failureMessage, {
  Map<String, String>? environment,
}) async {
  final result = await _runCaptured(
    executable,
    args,
    environment: environment,
    timeout: const Duration(minutes: 2),
  );
  if (result.exitCode != 0) {
    throw _CliError(failureMessage);
  }
}

Future<Map<String, String>> _prepareCocoaPodsEnvironment(
  Map<String, String> baseEnvironment, {
  required bool includeParentEnvironment,
}) async {
  final prefix = await _runCaptured(
    'brew',
    const ['--prefix', 'ruby@3.4'],
    environment: baseEnvironment,
    includeParentEnvironment: includeParentEnvironment,
  );
  if (prefix.exitCode != 0) {
    throw const _CliError(
      'The network-compatible Ruby runtime is missing; run '
      '`brew install ruby@3.4`.',
    );
  }
  final rubyBin = '${prefix.stdout.trim()}/bin';
  final gemHome = Directory('.work/cocoapods-1.16.2').absolute.path;
  final pod = '$gemHome/bin/pod';
  if (!File(pod).existsSync()) {
    await Directory(gemHome).create(recursive: true);
    final install = await _runCaptured(
      '$rubyBin/gem',
      [
        'install',
        'cocoapods',
        '-v',
        '1.16.2',
        '--no-document',
        '--install-dir',
        gemHome,
      ],
      environment: baseEnvironment,
      includeParentEnvironment: includeParentEnvironment,
      timeout: const Duration(minutes: 5),
    );
    if (install.exitCode != 0) {
      throw const _CliError(
        'Could not install isolated CocoaPods 1.16.2 with Ruby 3.4.',
      );
    }
  }
  final environment = Map<String, String>.of(baseEnvironment);
  environment['GEM_HOME'] = gemHome;
  environment['GEM_PATH'] = gemHome;
  environment['PATH'] =
      '$gemHome/bin:$rubyBin:${environment['PATH'] ?? '/usr/bin:/bin'}';
  final version = await _runCaptured(
    pod,
    const ['--version'],
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
  );
  if (version.exitCode != 0 || version.stdout.trim() != '1.16.2') {
    throw const _CliError('Isolated CocoaPods 1.16.2 validation failed.');
  }
  return environment;
}

Future<void> _requireCommand(
  String executable,
  List<String> args,
  String label, {
  Duration timeout = const Duration(seconds: 30),
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
}) async {
  final result = await _runCaptured(
    executable,
    args,
    timeout: timeout,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
  );
  if (result.exitCode != 0) {
    throw _CliError('$label is unavailable. Install/configure it and retry.');
  }
}

Future<int> _runInherited(
  String executable,
  List<String> args, {
  Duration? timeout,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
}) async {
  final process = await Process.start(
    executable,
    args,
    mode: ProcessStartMode.inheritStdio,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
  );
  try {
    return timeout == null
        ? await process.exitCode
        : await process.exitCode.timeout(timeout);
  } on TimeoutException {
    await _stopProcess(process);
    throw _CliError(
      '$executable did not finish within ${timeout!.inMinutes} minutes.',
    );
  }
}

Future<int> _runRedacted(
  String executable,
  List<String> args, {
  required List<String> secrets,
  required Duration timeout,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
}) async {
  final process = await Process.start(
    executable,
    args,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
  );
  final subscriptions = <StreamSubscription<String>>[
    _pipeRedacted(process.stdout, stdout, secrets),
    _pipeRedacted(process.stderr, stderr, secrets),
  ];
  final outputs = subscriptions.map(_observeDrain).toList();
  try {
    final code = await process.exitCode.timeout(timeout);
    await _settleOutput(subscriptions, outputs);
    return code;
  } on TimeoutException {
    await _stopProcess(process);
    await _settleOutput(subscriptions, outputs);
    throw _CliError(
      '$executable did not finish within ${timeout.inMinutes} minutes.',
    );
  } catch (_) {
    await _stopProcess(process);
    await _settleOutput(subscriptions, outputs);
    rethrow;
  }
}

StreamSubscription<String> _pipeRedacted(
  Stream<List<int>> source,
  IOSink destination,
  List<String> secrets,
) => source
    .transform(utf8.decoder)
    .transform(const LineSplitter())
    .listen((line) => destination.writeln(_redact(line, secrets)));

Future<void> _observeDrain(StreamSubscription<String> subscription) async {
  try {
    await subscription.asFuture<void>();
  } catch (_) {
    // The caller validates any required output after the stream closes.
  }
}

Future<void> _settleOutput(
  List<StreamSubscription<String>> subscriptions,
  List<Future<void>> drains,
) async {
  try {
    await Future.wait(drains).timeout(const Duration(seconds: 3));
    return;
  } catch (_) {
    for (final subscription in subscriptions) {
      try {
        await subscription.cancel().timeout(const Duration(seconds: 1));
      } catch (_) {
        // Output shutdown is best-effort after the bounded drain.
      }
    }
  }
}

Future<void> _stopProcess(Process process) async {
  process.kill(ProcessSignal.sigterm);
  try {
    await process.exitCode.timeout(const Duration(seconds: 3));
    return;
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
  }
  try {
    await process.exitCode.timeout(const Duration(seconds: 2));
  } on TimeoutException {
    // The caller still exits nonzero; no unbounded shutdown wait is allowed.
  }
}

String _redact(String input, List<String> exactSecrets) {
  var value = input;
  for (final secret in exactSecrets) {
    if (secret.isNotEmpty) value = value.replaceAll(secret, '[REDACTED]');
  }
  value = value.replaceAll(
    RegExp(r'https?://\S*(?:/r/|%2Fr%2F)\S*', caseSensitive: false),
    '[REDACTED_COLLAB_LINK]',
  );
  value = value.replaceAll(
    RegExp(
      r'(?:wss?|https?)://[^\s#]+/r/[A-Za-z0-9_-]{10,64}(?:[.#][A-Za-z0-9_-]+)?',
    ),
    '[REDACTED_COLLAB_LINK]',
  );
  value = value.replaceAll(
    RegExp(r'\b[A-Za-z0-9_-]{43}(?:[A-Za-z0-9_-]{21,22})?\b'),
    '[REDACTED_SECRET]',
  );
  return value;
}

final class _CliError implements Exception {
  const _CliError(this.message, [this.exitCode = 1]);
  final String message;
  final int exitCode;
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
