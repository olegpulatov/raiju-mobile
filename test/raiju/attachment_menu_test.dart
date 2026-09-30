import 'dart:async';

import 'package:buzz/companion_controller.dart';
import 'package:buzz/features/channels/compose_bar.dart';
import 'package:buzz/features/channels/voice_note_recording.dart';
import 'package:buzz/harness/harness.dart';
import 'package:buzz/raiju/companion_provider.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/storage/chat_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:image_picker/image_picker.dart';

const _nativeAttachmentChannel = MethodChannel(
  'buzz/native_attachment_popover',
);

void main() {
  testWidgets(
    'companion composer uses native iOS attachment presentation without effects',
    (tester) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final nativeCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _nativeAttachmentChannel,
        (call) async {
          nativeCalls.add(call);
          return switch (call.method) {
            'isSupported' || 'present' => true,
            _ => null,
          };
        },
      );
      final effects = _AttachmentEffects();
      final fixture = await _Fixture.live(effects);

      try {
        await tester.pumpWidget(fixture.app());
        await tester.tap(find.byTooltip('Add attachment').hitTestable());
        await tester.pumpAndSettle();

        final present = nativeCalls.singleWhere(
          (call) => call.method == 'present',
        );
        expect(
          (present.arguments as Map<Object?, Object?>)['effectsEnabled'],
          isFalse,
        );
        expect(find.byKey(const ValueKey('attachment-menu')), findsNothing);

        for (final action in const [
          ('cameraCaptured', '/tmp/raiju-attachment-test.png'),
          ('photosSelected', <String>['/tmp/raiju-attachment-test.png']),
          ('pickAllPhotos', null),
          ('pickVideo', null),
          ('recordVoiceNote', null),
          ('pickFiles', null),
          ('unsupportedSelection', null),
        ]) {
          await _sendNativeCall(tester, action.$1, action.$2);
          await tester.pump();
          expect(
            find.text(
              'Attachments and voice notes are not available for OMP chats yet.',
            ),
            findsOneWidget,
            reason: action.$1,
          );
          expect(effects.calls, 0, reason: action.$1);
          expect(effects.recorder.started, isFalse, reason: action.$1);
          tester
              .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
              .removeCurrentSnackBar();
          await tester.pumpAndSettle();
        }

        expect(effects.calls, 0);
        expect(effects.recorder.started, isFalse);
      } finally {
        await _sendNativeCall(tester, 'dismissed');
        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          _nativeAttachmentChannel,
          null,
        );
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    },
  );

  testWidgets('unavailable native iOS presentation retains Flutter fallback', (
    tester,
  ) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    var presentCalls = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _nativeAttachmentChannel,
      (call) async {
        if (call.method == 'present') presentCalls += 1;
        return call.method == 'isSupported' ? false : null;
      },
    );
    final effects = _AttachmentEffects();
    final fixture = await _Fixture.live(effects);

    try {
      await tester.pumpWidget(fixture.app());
      await tester.tap(find.byTooltip('Add attachment').hitTestable());
      await tester.pumpAndSettle();

      expect(presentCalls, 0);
      expect(find.byKey(const ValueKey('attachment-menu')), findsOneWidget);
      expect(find.text('Voice note'), findsOneWidget);

      await tester.tap(find.text('Voice note'));
      await tester.pump();
      expect(
        find.text(
          'Attachments and voice notes are not available for OMP chats yet.',
        ),
        findsOneWidget,
      );
      expect(effects.calls, 0);
      expect(effects.recorder.started, isFalse);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _nativeAttachmentChannel,
        null,
      );
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
  });
}

Future<void> _sendNativeCall(
  WidgetTester tester,
  String method, [
  Object? arguments,
]) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    _nativeAttachmentChannel.name,
    _nativeAttachmentChannel.codec.encodeMethodCall(
      MethodCall(method, arguments),
    ),
    null,
  );
}

class _AttachmentEffects {
  int calls = 0;
  final recorder = _Recorder();

  late final MediaUploadService media = MediaUploadService(
    baseUrl: 'https://relay.invalid',
    nsec: null,
    pickGalleryImage: () async {
      calls += 1;
      return null;
    },
    pickCameraImage: () async {
      calls += 1;
      return null;
    },
    pickGalleryImages: () async {
      calls += 1;
      return const <XFile>[];
    },
    pickGalleryVideo: () async {
      calls += 1;
      return null;
    },
    pickAttachmentFile: () async {
      calls += 1;
      return null;
    },
  );
}

class _Fixture {
  const _Fixture(this.controller, this.effects, this.channelId);

  final CompanionController controller;
  final _AttachmentEffects effects;
  final String channelId;

  static Future<_Fixture> live(_AttachmentEffects effects) async {
    final controller = CompanionController(
      clientFactory: _Client.new,
      store: _Store(),
      writeDebounce: Duration.zero,
    );
    await controller.initialize();
    final thread = await controller.join('attachment-test');
    return _Fixture(controller, effects, thread.id);
  }

  Widget app() => ProviderScope(
    overrides: [
      companionControllerProvider.overrideWith((ref) => controller),
      mediaUploadServiceProvider.overrideWithValue(effects.media),
      voiceNoteRecorderFactoryProvider.overrideWithValue(
        () => effects.recorder,
      ),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: ComposeBar(
          channelId: channelId,
          companionMode: true,
          onSend: (content, mentions, {mediaTags = const []}) async {},
        ),
      ),
    ),
  );
}

class _Recorder implements VoiceNoteRecorder {
  bool started = false;

  @override
  Stream<double> get levels => const Stream<double>.empty();

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<VoiceNoteRecording> stop() => throw UnimplementedError();

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {}
}

class _Store implements ChatStore {
  List<StoredChat> records = const [];

  @override
  Future<List<StoredChat>> load() async => records;

  @override
  Future<void> save(List<StoredChat> chats) async {
    records = List<StoredChat>.of(chats);
  }
}

class _Client implements HarnessClient {
  final _changes = StreamController<HarnessSnapshot>.broadcast();

  @override
  HarnessSnapshot get snapshot => const HarnessSnapshot(
    phase: ConnectionPhase.live,
    title: 'Attachment test',
  );

  @override
  Stream<HarnessSnapshot> get changes => _changes.stream;

  @override
  Future<void> connect(String input, {String displayName = 'raiju'}) async {}

  @override
  Future<void> sendPrompt(String text) async {}

  @override
  Future<void> abort() async {}

  @override
  Future<void> respond(int requestId, String? value) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() => _changes.close();
}
