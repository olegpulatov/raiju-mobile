import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:raiju_mobile/harness/ompd_connection.dart';

/// Synthetic exact daemon JSONL schemas. No host credentials or files.
class OmpdFixture {
  final requests = <Map<String, Object?>>[];
  final sockets = <Socket>[];
  final attachments = <Socket>[];
  late final ServerSocket server;
  String sessionId = 'fixture-session';
  bool streaming = false;
  bool split = false;
  bool rejectControl = false;
  bool rejectRpc = false;
  bool ignoreRpc = false;
  bool closeOnRpc = false;
  bool paged = true;
  int nextClient = 0;
  int polls = 0;
  String sessionFile = '/synthetic/session.jsonl';
  List<Map<String, Object?>> messages = [];
  Future<void> Function(Socket, Map<String, Object?>, String)? onRpc;
  Future<void> Function(Socket, Map<String, Object?>)? onControl;

  OmpdEndpoint get endpoint => OmpdEndpoint.parse('127.0.0.1:${server.port}');
  String get encoded => OmpdConnection(
    endpoint: endpoint,
    instance: 'phone',
    sessionId: sessionId,
    sessionFile: sessionFile,
    trustedNetwork: true,
  ).encode();

  Future<void> open() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      sockets.add(socket);
      String? client;
      var chain = Future<void>.value();
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final request = Map<String, Object?>.from(jsonDecode(line) as Map);
            requests.add(request);
            chain = chain.then((_) async {
              if (request['method'] != null) {
                if (onControl != null) {
                  await onControl!(socket, request);
                  return;
                }
                if (rejectControl) {
                  await send(socket, {'error': 'PRIVATE-ERROR-TOKEN'});
                  return;
                }
                switch (request['method']) {
                  case 'status':
                    polls++;
                    await send(socket, {
                      'result': request['name'] == null ? [instance] : instance,
                    });
                    break;
                  case 'start':
                    await send(socket, {'result': instance});
                    break;
                  case 'attach':
                    client = 'c${++nextClient}';
                    attachments.add(socket);
                    await send(socket, {
                      'result': {
                        'name': 'phone',
                        'client_id': client,
                        'mode': 'control',
                        'generation': 1,
                        'ready': true,
                      },
                    });
                    break;
                }
              } else {
                if (onRpc != null) {
                  await onRpc!(socket, request, client!);
                  return;
                }
                if (ignoreRpc) return;
                if (closeOnRpc) {
                  socket.destroy();
                  return;
                }
                await rpc(socket, request, client!);
              }
            });
            // Keep fixture failures in the zone rather than dropping them.
            unawaited(chain);
          }, onError: (Object _) {});
    });
  }

  Map<String, Object?> get instance => {
    'name': 'phone',
    'state': 'running',
    'ready': true,
    'rpc': true,
    'generation': 1,
    'clients': {'controller': null, 'viewers': []},
    'session': {
      'id': sessionId,
      'name': 'Fixture chat',
      'file': sessionFile,
      'conflict': null,
    },
  };

  Map<String, Object?> get state => {
    'sessionId': sessionId,
    'sessionName': 'Fixture chat',
    'sessionFile': sessionFile,
    'model': {'id': 'fixture-model'},
    'isStreaming': streaming,
    'isCompacting': false,
    'isSettled': !streaming,
  };

  Future<void> rpc(
    Socket socket,
    Map<String, Object?> request,
    String client,
  ) async {
    if (request['type'] == 'extension_ui_response') return;
    if (rejectRpc || (request['type'] == 'get_messages_page' && !paged)) {
      await send(socket, response(request, client, success: false));
      return;
    }
    final data = switch (request['type']) {
      'get_state' => state,
      'get_messages' => <String, Object?>{'messages': messages},
      'get_messages_page' => <String, Object?>{
        'messages': messages,
        'totalMessages': messages.length,
      },
      _ => <String, Object?>{},
    };
    await send(socket, response(request, client, data: data));
  }

  Map<String, Object?> response(
    Map<String, Object?> request,
    String client, {
    bool success = true,
    Map<String, Object?> data = const {},
  }) => {
    'type': 'response',
    'id': '$client:${request['id']}',
    'command': request['type'],
    'success': success,
    if (success) 'data': data else 'error': 'PRIVATE-ERROR-TOKEN',
  };

  Future<void> send(Socket socket, Map<String, Object?> frame) async {
    final bytes = utf8.encode('${jsonEncode(frame)}\n');
    if (split && bytes.length > 1) {
      final mid = bytes.length ~/ 2;
      socket.add(bytes.sublist(0, mid));
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 1));
      socket.add(bytes.sublist(mid));
    } else {
      socket.add(bytes);
    }
    await socket.flush();
  }

  Future<void> coalesce(
    Socket socket,
    List<Map<String, Object?>> frames,
  ) async {
    socket.add(
      utf8.encode(frames.map((frame) => '${jsonEncode(frame)}\n').join()),
    );
    await socket.flush();
  }

  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
  }
}

Future<void> waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('fixture condition timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
