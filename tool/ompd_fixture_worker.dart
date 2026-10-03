import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Synthetic-only OMP RPC v1 worker for ompd_smoke.dart. No provider imports,
/// network access, credentials, tools, or real OMP session-file support.
/// Envelopes/events follow coding-agent/src/modes/rpc/{rpc-mode,rpc-types,
/// rpc-session-events,rpc-prompt-results}.ts in the current OMP checkout.
Future<void> main(List<String> arguments) async {
  Timer? lifetime;
  _Worker? worker;
  try {
    String? resume;
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument == '--resume' && index + 1 < arguments.length) {
        resume = arguments[++index];
      } else if (argument.startsWith('--resume=')) {
        resume = argument.substring('--resume='.length);
      } else if (argument == '--mode' && index + 1 < arguments.length) {
        if (arguments[++index] != 'rpc') {
          throw StateError('only RPC v1 supported');
        }
      } else if (argument == '--no-ui' || argument == '--mode=rpc') {
        // ompd supplies these normal RPC launch flags.
      } else {
        throw StateError('unexpected synthetic worker launch argument');
      }
    }
    final sessionPath =
        resume ?? Platform.environment['RAIJU_OMPD_FIXTURE_SESSION'];
    final auditPath = Platform.environment['RAIJU_OMPD_FIXTURE_AUDIT'];
    if (sessionPath == null || auditPath == null) {
      throw StateError('worker must be launched by ompd_smoke.dart');
    }
    final fixture = Map<String, Object?>.from(
      jsonDecode(await File(sessionPath).readAsString()) as Map,
    );
    if (fixture['synthetic'] != true ||
        fixture['id'] is! String ||
        fixture['name'] is! String ||
        fixture['messages'] is! List) {
      throw StateError('only marked synthetic fixture files are supported');
    }
    // Each worker owns one audit file. FileMode.append alone does not make
    // concurrent open/seek/write operations from two processes atomic.
    final active = _Worker(sessionPath, File('$auditPath.$pid'), fixture);
    worker = active;
    active.record('started', {'resume': resume, 'pid': pid});
    lifetime = Timer(const Duration(seconds: 90), () {
      active.record('stopped', {'reason': 'lifetime deadline'});
      exit(1);
    });
    active.emit({
      'type': 'ready',
      'protocolVersion': 1,
      'supportedProtocolVersions': [1],
      'maxFrameBytes': 1048576,
      'maxReassembledFrameBytes': 67108864,
    });
    await stdout.flush();
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        continue;
      }
      if (line.length > 1048576) {
        throw StateError('synthetic request too large');
      }
      final request = Map<String, Object?>.from(jsonDecode(line) as Map);
      await active.handle(request);
      await stdout.flush();
    }
  } catch (_) {
    // Never dump requests, local environment, paths, or session contents.
    stderr.writeln('synthetic RPC worker failed');
    exitCode = 1;
  } finally {
    lifetime?.cancel();
    worker?.record('stopped', {'reason': 'stdin EOF or failure'});
  }
}

final class _Worker {
  _Worker(this.sessionPath, this.audit, Map<String, Object?> fixture)
    : sessionId = fixture['id'] as String,
      sessionName = fixture['name'] as String,
      messages = (fixture['messages'] as List)
          .map((message) => Map<String, Object?>.from(message as Map))
          .toList();
  final String sessionPath;
  final File audit;
  final String sessionId;
  final String sessionName;
  final List<Map<String, Object?>> messages;
  var messageSequence = 0;
  var promptSequence = 0;
  var streaming = false;

  void emit(Map<String, Object?> frame) => stdout.writeln(jsonEncode(frame));
  void record(String event, [Map<String, Object?> details = const {}]) {
    // No other process writes this file.
    final output = audit.openSync(mode: FileMode.append);
    try {
      output.writeStringSync(
        '${jsonEncode({'event': event, 'sessionId': sessionId, ...details})}\n',
      );
      output.flushSync();
    } finally {
      output.closeSync();
    }
  }

  void respond(Map<String, Object?> request, [Object? data]) => emit({
    if (request['id'] != null) 'id': request['id'],
    'type': 'response',
    'command': request['type'],
    'success': true,
    'data': ?data,
  });
  Future<void> handle(Map<String, Object?> request) async {
    switch (request['type']) {
      case 'set_event_filter':
        record('set_event_filter', {'id': request['id']});
        if (request['events'] != null ||
            (request['messageUpdates'] != null &&
                request['messageUpdates'] != 'full')) {
          emit({
            'id': request['id'],
            'type': 'response',
            'command': 'set_event_filter',
            'success': false,
            'error': 'synthetic worker requires full unfiltered events',
          });
          return;
        }
        respond(request, {'events': null, 'messageUpdates': 'full'});
      case 'get_state':
        record('get_state', {'id': request['id']});
        respond(request, {
          'thinkingLevel': 'off',
          'isStreaming': streaming,
          'isCompacting': false,
          'steeringMode': 'all',
          'followUpMode': 'all',
          'interruptMode': 'immediate',
          'sessionFile': sessionPath,
          'sessionId': sessionId,
          'sessionName': sessionName,
          'autoCompactionEnabled': false,
          'fastModeEnabled': false,
          'fastModeActive': false,
          'tokensPerSecond': null,
          'messageCount': messages.length,
          'queuedMessageCount': 0,
          'hasPendingAsyncWork': false,
          'isSettled': !streaming,
          'queuedMessages': {'steering': [], 'followUp': []},
          'todoPhases': [],
          'goal': null,
        });
      case 'get_messages':
        record('get_messages', {'id': request['id']});
        respond(request, {'messages': messages});
      case 'get_messages_page':
        record('get_messages_page', {'id': request['id']});
        final limit = request['limit'] as int? ?? 100;
        if (limit < 1 || limit > 256) {
          throw StateError('invalid synthetic message page limit');
        }
        var offset = 0;
        final cursor = request['cursor'];
        if (cursor is String) {
          final snapshot = Map<String, Object?>.from(
            jsonDecode(
                  utf8.decode(base64Url.decode(base64Url.normalize(cursor))),
                )
                as Map,
          );
          if (snapshot['version'] != 1 ||
              snapshot['sessionId'] != sessionId ||
              snapshot['messageCount'] != messages.length ||
              snapshot['leafId'] != 'synthetic-$promptSequence') {
            emit({
              'id': request['id'],
              'type': 'response',
              'command': 'get_messages_page',
              'success': false,
              'error': 'RPC message cursor is stale',
              'code': 'stale_cursor',
            });
            return;
          }
          offset = snapshot['offset'] as int;
        }
        if (offset < 0 || offset > messages.length) {
          throw StateError('invalid synthetic message page cursor');
        }
        final end = offset + limit < messages.length
            ? offset + limit
            : messages.length;
        respond(request, {
          'messages': messages.sublist(offset, end),
          'totalMessages': messages.length,
          if (end < messages.length)
            'nextCursor': base64Url
                .encode(
                  utf8.encode(
                    jsonEncode({
                      'version': 1,
                      'sessionId': sessionId,
                      'leafId': 'synthetic-$promptSequence',
                      'messageCount': messages.length,
                      'offset': end,
                    }),
                  ),
                )
                .replaceAll('=', ''),
        });
      case 'prompt':
        final text = request['message'];
        if (text is! String || text.isEmpty) {
          emit({
            'id': request['id'],
            'type': 'response',
            'command': 'prompt',
            'success': false,
            'error': 'synthetic prompt needs a message',
          });
          return;
        }
        record('prompt', {'id': request['id'], 'message': text});
        // Admission precedes all generation events and terminal prompt_result.
        respond(request);
        await stdout.flush();
        streaming = true;
        final timestamp = 1790000000000 + ++promptSequence;
        final user = <String, Object?>{
          'role': 'user',
          'content': text,
          'timestamp': timestamp,
        };
        messages.add(user);
        emit({'type': 'agent_start'});
        emit({'type': 'turn_start'});
        final userId = 'msg-${++messageSequence}';
        emit({'type': 'message_start', 'messageId': userId, 'message': user});
        emit({'type': 'message_end', 'messageId': userId, 'message': user});
        final assistantId = 'msg-${++messageSequence}';
        final partial = _assistant('', timestamp + 1);
        emit({
          'type': 'message_start',
          'messageId': assistantId,
          'message': partial,
        });
        await stdout.flush();
        await Future<void>.delayed(const Duration(milliseconds: 25));
        final reply = _assistant('synthetic reply: $text', timestamp + 1);
        emit({
          'type': 'message_update',
          'messageId': assistantId,
          'message': reply,
          'assistantMessageEvent': {
            'type': 'text_delta',
            'contentIndex': 0,
            'delta': 'synthetic reply: $text',
            'partial': reply,
          },
        });
        messages.add(reply);
        emit({
          'type': 'message_end',
          'messageId': assistantId,
          'message': reply,
        });
        emit({'type': 'turn_end', 'message': reply, 'toolResults': []});
        streaming = false;
        emit({
          'type': 'agent_end',
          'messages': [user, reply],
        });
        emit({
          'type': 'prompt_result',
          'id': request['id'],
          'agentInvoked': true,
          'status': 'completed',
          'sessionSettled': true,
        });
        // Fixture persistence is intentionally NOT the real OMP file format.
        await File(sessionPath).writeAsString(
          jsonEncode({
            'synthetic': true,
            'id': sessionId,
            'name': sessionName,
            'messages': messages,
          }),
        );
        record('completed', {'id': request['id'], 'message': text});
      case 'abort':
        respond(request);
      default:
        emit({
          'id': request['id'],
          'type': 'response',
          'command': request['type'],
          'success': false,
          'error': 'unsupported synthetic RPC command',
        });
    }
  }
}

Map<String, Object?> _assistant(String text, int timestamp) => {
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
  'timestamp': timestamp,
};
