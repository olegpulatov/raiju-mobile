import 'dart:async';

import 'package:flutter/services.dart';

abstract interface class VoiceSession {
  Stream<Map<String, Object?>> get events;
  Future<void> start({
    required String accessToken,
    String? accountId,
    required String instructions,
    required String voice,
  });
  Future<void> stop();
  Future<void> setMuted(bool muted);
  Future<void> sendText(
    String text, {
    String? delegationId,
    String channel = 'speakable',
  });
  Future<void> dispose();
}

class MethodChannelVoiceSession implements VoiceSession {
  MethodChannelVoiceSession({
    MethodChannel? methods,
    EventChannel? eventChannel,
  }) : _methods = methods ?? const MethodChannel('raiju/spark/methods'),
       _eventChannel = eventChannel ?? const EventChannel('raiju/spark/events');
  final MethodChannel _methods;
  final EventChannel _eventChannel;
  Stream<Map<String, Object?>>? _events;
  bool _disposed = false;

  @override
  Stream<Map<String, Object?>> get events => _events ??= _eventChannel
      .receiveBroadcastStream()
      .where((value) => value is Map)
      .map((value) => Map<String, Object?>.from(value as Map));
  void _check() {
    if (_disposed) throw StateError('Spark voice session is closed.');
  }

  @override
  Future<void> start({
    required String accessToken,
    String? accountId,
    required String instructions,
    required String voice,
  }) async {
    _check();
    await _methods.invokeMethod<void>('start', {
      'accessToken': accessToken,
      'accountId': ?accountId,
      'instructions': instructions,
      'voice': voice,
    });
  }

  @override
  Future<void> stop() async {
    if (!_disposed) await _methods.invokeMethod<void>('stop');
  }

  @override
  Future<void> setMuted(bool muted) async {
    _check();
    await _methods.invokeMethod<void>('setMuted', {'muted': muted});
  }

  @override
  Future<void> sendText(
    String text, {
    String? delegationId,
    String channel = 'speakable',
  }) async {
    _check();
    await _methods.invokeMethod<void>('sendText', {
      'text': text,
      'delegationId': ?delegationId,
      'channel': channel,
    });
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    try {
      await stop();
    } finally {
      _disposed = true;
    }
  }
}
