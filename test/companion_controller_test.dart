import 'dart:async';
import 'dart:typed_data';

import 'package:raiju_mobile/companion_controller.dart';
import 'package:raiju_mobile/features/channels/channels_provider.dart';
import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/storage/chat_store.dart';
import 'package:raiju_mobile/harness/ompd_connection.dart';
import 'package:raiju_mobile/storage/encrypted_file_chat_store.dart';
import 'package:raiju_mobile/storage/voice_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'input-aware factory keeps collab and restores encrypted daemon identity',
    () async {
      final disk = MemoryCiphertextBackend();
      final keys = MemoryKeyBackend();
      final connection = OmpdConnection(
        endpoint: OmpdEndpoint.parse('relay.example:7420'),
        instance: 'synthetic-worker',
        sessionId: 'synthetic-session-identity',
        sessionFile: '/synthetic/worker.jsonl',
        trustedNetwork: true,
      ).encode();
      final collab = FakeClient(connectedSnapshot: _snapshot(['collab']));
      final daemon = FakeClient(
        connectedSnapshot: const HarnessSnapshot(
          phase: ConnectionPhase.live,
          title: 'Daemon conversation',
          sessionId: 'synthetic-session-identity',
          readOnly: false,
        ),
      );
      final firstInputs = <String>[];
      final first = CompanionController(
        clientFactory: () =>
            throw StateError('Legacy fallback must not override routing'),
        connectionClientFactory: (input) {
          firstInputs.add(input);
          return OmpdConnection.isOmpd(input) ? daemon : collab;
        },
        store: _store(disk, keys),
        writeDebounce: Duration.zero,
      );
      await first.initialize();
      await first.join('synthetic-collab-link');
      final chat = await first.join(connection);
      first.updateDraft(chat.id, 'private daemon draft');
      await first.flush();
      expect(firstInputs, ['synthetic-collab-link', connection]);
      expect(first.lastOmpdEndpoint.toString(), 'relay.example:7420');
      final ciphertext = String.fromCharCodes(disk.bytes!);
      expect(ciphertext, isNot(contains('synthetic-session-identity')));
      expect(ciphertext, isNot(contains('private daemon draft')));
      expect(ciphertext, isNot(contains('/synthetic/worker.jsonl')));
      first.dispose();

      final gate = Completer<void>();
      final restoredCollab = FakeClient(
        connectedSnapshot: _snapshot(['collab']),
      );
      final restoredDaemon = FakeClient(
        connectedSnapshot: daemon.connectedSnapshot,
        gate: gate,
      );
      final restoredInputs = <String>[];
      final restored = CompanionController(
        clientFactory: () =>
            throw StateError('Legacy fallback must not override routing'),
        connectionClientFactory: (input) {
          restoredInputs.add(input);
          return OmpdConnection.isOmpd(input) ? restoredDaemon : restoredCollab;
        },
        store: _store(disk, keys),
      );
      await restored.initialize();
      expect(restoredInputs, firstInputs);
      expect(
        OmpdConnection.parse(restoredInputs.last).sessionFile,
        '/synthetic/worker.jsonl',
      );
      final restoredChat = restored.chat(chat.id)!;
      expect(restoredChat.draft, 'private daemon draft');
      expect(restoredChat.snapshot.sessionId, 'synthetic-session-identity');
      expect(restoredDaemon.connectedInputs, [connection]);
      expect(restoredCollab.connectedInputs, ['synthetic-collab-link']);
      expect(restoredDaemon.sentPrompts, isEmpty);
      gate.complete();
      await _settle();
      expect(restoredChat.snapshot.sessionId, 'synthetic-session-identity');
      await restored.disconnect(chat.id);
      expect(restoredDaemon.abortCalls, 0);
      restored.dispose();
    },
  );

  test(
    'daemon takeover persists viewer intent without changing collab restore',
    () async {
      final disk = MemoryCiphertextBackend();
      final keys = MemoryKeyBackend();
      final connection = OmpdConnection(
        endpoint: OmpdEndpoint.parse('relay.example:7420'),
        instance: 'synthetic-worker',
        sessionId: 'synthetic-session-identity',
        sessionFile: '/synthetic/worker.jsonl',
        trustedNetwork: true,
      ).encode();
      const writable = HarnessSnapshot(
        phase: ConnectionPhase.live,
        title: 'Daemon conversation',
        sessionId: 'synthetic-session-identity',
        readOnly: false,
      );
      const viewer = HarnessSnapshot(
        phase: ConnectionPhase.live,
        title: 'Daemon conversation',
        sessionId: 'synthetic-session-identity',
        readOnly: true,
      );
      final daemon = FakeClient(connectedSnapshot: writable);
      final collab = FakeClient(connectedSnapshot: _snapshot(['collab']));
      final first = CompanionController(
        clientFactory: () => throw StateError('Use input routing'),
        connectionClientFactory: (input) =>
            OmpdConnection.isOmpd(input) ? daemon : collab,
        store: _store(disk, keys),
        writeDebounce: const Duration(days: 1),
      );
      await first.initialize();
      final daemonChat = await first.join(connection);
      final collabChat = await first.join('synthetic-collab-link');
      first.updateDraft(daemonChat.id, 'viewer draft');
      final takeoverWrite = Completer<void>();
      disk.writeEntered = takeoverWrite;
      daemon.emit(viewer);
      collab.emit(viewer);
      expect(daemonChat.snapshot.phase, ConnectionPhase.live);
      expect(daemonChat.snapshot.readOnly, isTrue);
      expect(daemon.abortCalls, 0);
      // No flush: ownership loss must write before the ordinary debounce.
      await takeoverWrite.future.timeout(const Duration(seconds: 1));
      await _settle();
      final saved = await _store(disk, keys).load();
      expect(
        saved.singleWhere((chat) => chat.id == daemonChat.id).reconnect,
        isFalse,
      );
      expect(
        saved.singleWhere((chat) => chat.id == collabChat.id).reconnect,
        isTrue,
      );
      first.dispose();

      final restoredDaemon = FakeClient(connectedSnapshot: writable);
      final restoredCollab = FakeClient(
        connectedSnapshot: _snapshot(['collab']),
      );
      final restored = CompanionController(
        clientFactory: () => throw StateError('Use input routing'),
        connectionClientFactory: (input) =>
            OmpdConnection.isOmpd(input) ? restoredDaemon : restoredCollab,
        store: _store(disk, keys),
      );
      await restored.initialize();
      await _settle();
      expect(restoredDaemon.connectCalls, 0);
      expect(restoredCollab.connectCalls, 1);
      expect(restored.chat(daemonChat.id)!.draft, 'viewer draft');
      expect(
        restored.chat(daemonChat.id)!.snapshot.phase,
        ConnectionPhase.disconnected,
      );
      expect(
        restored.chat(daemonChat.id)!.snapshot.sessionId,
        'synthetic-session-identity',
      );
      await restored.reconnect(daemonChat.id);
      expect(restoredDaemon.connectCalls, 1);
      expect(restoredDaemon.connectedInputs, [connection]);
      expect(restored.chat(daemonChat.id)!.snapshot.readOnly, isFalse);
      expect(
        (await _store(
          disk,
          keys,
        ).load()).singleWhere((chat) => chat.id == daemonChat.id).reconnect,
        isTrue,
      );
      restored.dispose();
    },
  );

  test(
    'takeover during daemon restore bootstrap disables future auto-attach',
    () async {
      final disk = MemoryCiphertextBackend();
      final keys = MemoryKeyBackend();
      final connection = OmpdConnection(
        endpoint: OmpdEndpoint.parse('relay.example:7420'),
        instance: 'synthetic-worker',
        sessionId: 'synthetic-session-identity',
        sessionFile: '/synthetic/worker.jsonl',
        trustedNetwork: true,
      ).encode();
      const writable = HarnessSnapshot(
        phase: ConnectionPhase.live,
        title: 'Daemon conversation',
        sessionId: 'synthetic-session-identity',
        readOnly: false,
      );
      final seed = _controller(disk, keys, [
        FakeClient(connectedSnapshot: writable),
      ]);
      await seed.initialize();
      final chat = await seed.join(connection);
      seed.updateDraft(chat.id, 'bootstrap draft');
      await seed.flush();
      seed.dispose();

      final gate = Completer<void>();
      final client = FakeControlLossClient(
        connectedSnapshot: writable,
        gate: gate,
        connectError: const HarnessException(
          'Control changed during bootstrap.',
        ),
      );
      final restoring = _controller(disk, keys, [client]);
      await restoring.initialize();
      client.controlLost = true;
      client.emit(
        const HarnessSnapshot(
          phase: ConnectionPhase.syncing,
          sessionId: 'synthetic-session-identity',
          readOnly: true,
        ),
      );
      gate.complete();
      await _settle();
      await restoring.flush();
      expect(restoring.chat(chat.id)!.snapshot.phase, ConnectionPhase.error);
      expect((await _store(disk, keys).load()).single.reconnect, isFalse);
      restoring.dispose();

      final nextClient = FakeClient(connectedSnapshot: writable);
      final nextLaunch = _controller(disk, keys, [nextClient]);
      await nextLaunch.initialize();
      await _settle();
      expect(nextClient.connectCalls, 0);
      expect(nextLaunch.chat(chat.id)!.draft, 'bootstrap draft');
      expect(
        nextLaunch.chat(chat.id)!.snapshot.sessionId,
        'synthetic-session-identity',
      );
      nextLaunch.dispose();
    },
  );

  test(
    'cancel pending join disposes only its client before late connect completes',
    () async {
      final disk = MemoryCiphertextBackend();
      final keys = MemoryKeyBackend();
      final existingClient = FakeClient(
        connectedSnapshot: _snapshot(['existing']),
      );
      final gate = Completer<void>();
      final pendingClient = FakeClient(
        connectedSnapshot: _snapshot(['pending']),
        gate: gate,
      );
      final controller = _controller(disk, keys, [
        existingClient,
        pendingClient,
      ]);
      await controller.initialize();
      final existing = await controller.join('synthetic-collab-link');
      final cancellation = ChatJoinCancellation();
      final connection = OmpdConnection(
        endpoint: OmpdEndpoint.parse('relay.example:7420'),
        instance: 'worker',
        sessionId: 'session-one',
        sessionFile: '/synthetic/worker.jsonl',
        trustedNetwork: true,
      ).encode();
      final joining = controller.join(connection, cancellation: cancellation);
      final failed = expectLater(joining, throwsA(isA<HarnessException>()));
      await _settle();
      expect(pendingClient.connectCalls, 1);
      cancellation.cancel();
      expect(pendingClient.disposed, isTrue);
      expect(existingClient.disposed, isFalse);
      expect(controller.chats.single.id, existing.id);
      gate.complete();
      await failed;
      await controller.flush();
      expect((await _store(disk, keys).load()).single.id, existing.id);
      expect(pendingClient.abortCalls, 0);
      controller.dispose();
    },
  );

  test(
    'cancel join during encrypted save removes only that pending saved record',
    () async {
      final disk = MemoryCiphertextBackend();
      final keys = MemoryKeyBackend();
      final existingClient = FakeClient(
        connectedSnapshot: _snapshot(['existing']),
      );
      final pendingClient = FakeClient(
        connectedSnapshot: _snapshot(['pending']),
      );
      final controller = _controller(disk, keys, [
        existingClient,
        pendingClient,
      ]);
      await controller.initialize();
      final existing = await controller.join('synthetic-collab-link');
      final cancellation = ChatJoinCancellation();
      final writeGate = Completer<void>();
      final writeEntered = Completer<void>();
      disk.pendingWrite = writeGate;
      disk.writeEntered = writeEntered;
      final connection = OmpdConnection(
        endpoint: OmpdEndpoint.parse('relay.example:7420'),
        instance: 'worker',
        sessionId: 'session-one',
        sessionFile: '/synthetic/worker.jsonl',
        trustedNetwork: true,
      ).encode();
      final joining = controller.join(connection, cancellation: cancellation);
      final failed = expectLater(joining, throwsA(isA<HarnessException>()));
      await writeEntered.future;
      cancellation.cancel();
      expect(controller.chats.single.id, existing.id);
      expect(pendingClient.disposed, isTrue);
      expect(existingClient.disposed, isFalse);
      disk.pendingWrite = null;
      writeGate.complete();
      await failed;
      await controller.flush();
      expect((await _store(disk, keys).load()).single.id, existing.id);
      expect(pendingClient.abortCalls, 0);
      controller.dispose();
    },
  );

  group('CompanionController persistence', () {
    test(
      'restores draft and cache before background reconnect completes',
      () async {
        final disk = MemoryCiphertextBackend();
        final keys = MemoryKeyBackend();
        final firstClient = FakeClient(
          connectedSnapshot: _snapshot(<String>['old-1']),
        );
        final first = _controller(disk, keys, <FakeClient>[firstClient]);
        await first.initialize();
        final joined = await first.join('https://relay/join#private');
        firstClient.emit(_snapshot(<String>['old-1', 'old-2']));
        first.updateDraft(joined.id, 'unfinished thought');
        await first.flush();
        first.dispose();

        final reconnectGate = Completer<void>();
        final restoredClient = FakeClient(
          gate: reconnectGate,
          connectedSnapshot: _snapshot(<String>['fresh']),
        );
        final restored = _controller(disk, keys, <FakeClient>[restoredClient]);
        await restored.initialize();

        expect(restored.isLoading, isFalse);
        expect(restored.chats.single.draft, 'unfinished thought');
        expect(
          restored.chats.single.snapshot.messages.map((message) => message.id),
          <String>['old-1', 'old-2'],
        );
        expect(restoredClient.connectCalls, 1);

        reconnectGate.complete();
        await _settle();
        expect(
          restored.chats.single.snapshot.messages.map((message) => message.id),
          <String>['fresh'],
        );
        restored.dispose();
      },
    );

    test(
      'explicit disconnect survives relaunch and reconnect reenables intent',
      () async {
        final disk = MemoryCiphertextBackend();
        final keys = MemoryKeyBackend();
        final originalClient = FakeClient(
          connectedSnapshot: _snapshot(<String>['m']),
        );
        final original = _controller(disk, keys, <FakeClient>[originalClient]);
        await original.initialize();
        final joined = await original.join('link-secret');
        await original.disconnect(joined.id);
        original.dispose();

        final disconnectedClient = FakeClient(
          connectedSnapshot: _snapshot(<String>['m2']),
        );
        final relaunched = _controller(disk, keys, <FakeClient>[
          disconnectedClient,
        ]);
        await relaunched.initialize();
        await _settle();
        expect(disconnectedClient.connectCalls, 0);

        await relaunched.reconnect(relaunched.chats.single.id);
        expect(disconnectedClient.connectCalls, 1);
        relaunched.dispose();

        final activeAgainClient = FakeClient(
          connectedSnapshot: _snapshot(<String>['m3']),
        );
        final activeAgain = _controller(disk, keys, <FakeClient>[
          activeAgainClient,
        ]);
        await activeAgain.initialize();
        await _settle();
        expect(activeAgainClient.connectCalls, 1);
        activeAgain.dispose();
      },
    );

    test('disconnect fences a late background reconnect result', () async {
      final disk = MemoryCiphertextBackend();
      final keys = MemoryKeyBackend();
      final seed = _controller(disk, keys, <FakeClient>[
        FakeClient(connectedSnapshot: _snapshot(<String>['cached'])),
      ]);
      await seed.initialize();
      await seed.join('saved-link');
      seed.dispose();

      final gate = Completer<void>();
      final reconnectingClient = FakeClient(
        gate: gate,
        connectedSnapshot: _snapshot(<String>['late-live']),
      );
      final restored = _controller(disk, keys, <FakeClient>[
        reconnectingClient,
      ]);
      await restored.initialize();
      await restored.disconnect(restored.chats.single.id);
      gate.complete();
      await _settle();

      expect(
        restored.chats.single.snapshot.phase,
        ConnectionPhase.disconnected,
      );
      restored.dispose();

      final nextClient = FakeClient(
        connectedSnapshot: _snapshot(<String>['unexpected']),
      );
      final nextLaunch = _controller(disk, keys, <FakeClient>[nextClient]);
      await nextLaunch.initialize();
      await _settle();
      expect(nextClient.connectCalls, 0);
      nextLaunch.dispose();
    });

    test('forget removes encrypted credential and restored state', () async {
      final disk = MemoryCiphertextBackend();
      final keys = MemoryKeyBackend();
      final client = FakeClient(connectedSnapshot: _snapshot(<String>['m']));
      final controller = _controller(disk, keys, <FakeClient>[client]);
      await controller.initialize();
      final joined = await controller.join('credential-to-forget');

      await controller.forget(joined.id);
      expect(controller.chats, isEmpty);
      expect(client.disposed, isTrue);
      expect(client.abortCalls, 0);
      controller.dispose();

      final recreated = _controller(disk, keys, <FakeClient>[]);
      await recreated.initialize();
      expect(recreated.chats, isEmpty);
      recreated.dispose();
    });

    test('transport cleanup failure cannot undo durable forget', () async {
      final disk = MemoryCiphertextBackend();
      final keys = MemoryKeyBackend();
      final client = FakeClient(
        connectedSnapshot: _snapshot(['m']),
        throwOnDispose: true,
      );
      final controller = _controller(disk, keys, [client]);
      await controller.initialize();
      final chat = await controller.join('synthetic-credential');
      await controller.forget(chat.id);
      expect(controller.chats, isEmpty);
      expect((await _store(disk, keys).load()), isEmpty);
      controller.dispose();
    });

    test(
      'forget waits behind an in-flight save without resurrecting chat',
      () async {
        final disk = MemoryCiphertextBackend();
        final keys = MemoryKeyBackend();
        final client = FakeClient(connectedSnapshot: _snapshot(['m']));
        final controller = _controller(disk, keys, [client]);
        await controller.initialize();
        final chat = await controller.join('synthetic-credential');
        controller.upsertVoiceTurn(
          chat.id,
          const VoiceTurn(
            id: 'spoken',
            sequence: 1,
            origin: VoiceTurnOrigin.user,
            text: 'local voice',
          ),
        );
        await controller.flush();
        disk.pendingWrite = Completer<void>();
        final writeEntered = Completer<void>();
        disk.writeEntered = writeEntered;
        controller.updateDraft(chat.id, 'last draft');
        final pendingSave = controller.flush();
        await writeEntered.future;
        final removing = controller.forget(chat.id);
        await _settle();
        // Pending deletion hides chat(id), but the thread stays in memory until
        // the encrypted omission commits (and is restored on write failure).
        expect(controller.chats.single, same(chat));
        expect(controller.chat(chat.id), isNull);
        disk.pendingWrite!.complete();
        await pendingSave;
        await removing;
        expect(controller.chats, isEmpty);
        expect(client.abortCalls, 0);
        expect((await _store(disk, keys).load()), isEmpty);
        controller.dispose();
        final restored = _controller(disk, keys, <FakeClient>[]);
        await restored.initialize();
        expect(restored.chats, isEmpty);
        restored.dispose();
      },
    );

    test('failed forget keeps credential, draft, and voice to retry', () async {
      final disk = MemoryCiphertextBackend();
      final keys = MemoryKeyBackend();
      final client = FakeClient(connectedSnapshot: _snapshot(['m']));
      final controller = _controller(disk, keys, [client]);
      await controller.initialize();
      final chat = await controller.join('synthetic-credential');
      controller.updateDraft(chat.id, 'unsent draft');
      controller.upsertVoiceTurn(
        chat.id,
        const VoiceTurn(
          id: 'spoken',
          sequence: 1,
          origin: VoiceTurnOrigin.user,
          text: 'local voice',
        ),
      );
      await controller.flush();
      disk.failWrite = true;
      await expectLater(
        controller.forget(chat.id),
        throwsA(isA<ChatStoreException>()),
      );
      expect(controller.chat(chat.id), same(chat));
      expect(controller.storageError, isNotNull);
      expect(client.disposed, isFalse);
      disk.failWrite = false;
      await controller.flush();
      final saved = (await _store(disk, keys).load()).single;
      expect(saved.link, 'synthetic-credential');
      expect(saved.draft, 'unsent draft');
      expect(saved.voiceTurns.single.text, 'local voice');
      controller.dispose();
    });

    test(
      'offline saved room remains visible with cached transcript and retry',
      () async {
        final disk = MemoryCiphertextBackend();
        final keys = MemoryKeyBackend();
        final seed = _controller(disk, keys, <FakeClient>[
          FakeClient(connectedSnapshot: _snapshot(<String>['cached'])),
        ]);
        await seed.initialize();
        await seed.join('saved-room-link');
        seed.dispose();

        final offline = FakeClient(
          connectedSnapshot: _snapshot(<String>['remote']),
          connectError: const HarnessException('Room is unavailable.'),
        );
        final restored = _controller(disk, keys, <FakeClient>[offline]);
        await restored.initialize();
        await _settle();

        expect(restored.chats, hasLength(1));
        expect(restored.chats.single.snapshot.phase, ConnectionPhase.error);
        expect(restored.chats.single.snapshot.messages.single.id, 'cached');
        offline.connectError = null;
        await restored.reconnect(restored.chats.single.id);
        expect(restored.chats.single.snapshot.phase, ConnectionPhase.live);
        expect(restored.chats.single.snapshot.messages.single.id, 'remote');
        restored.dispose();
      },
    );

    test('forget fences a stale in-flight join result', () async {
      final disk = MemoryCiphertextBackend();
      final keys = MemoryKeyBackend();
      final gate = Completer<void>();
      final client = FakeClient(
        gate: gate,
        connectedSnapshot: _snapshot(<String>['late']),
      );
      final controller = _controller(disk, keys, <FakeClient>[client]);
      await controller.initialize();

      final joining = controller.join('stale-secret');
      await _settle();
      expect(controller.chats.single.id, '1');
      await controller.remove('1');
      gate.complete();

      await expectLater(joining, throwsA(isA<HarnessException>()));
      expect(controller.chats, isEmpty);
      expect((await _store(disk, keys).load()), isEmpty);
      controller.dispose();
    });

    test('failed durable join is not presented as saved', () async {
      final store = FailingSaveStore();
      final client = FakeClient(connectedSnapshot: _snapshot(<String>['m']));
      final controller = CompanionController(
        clientFactory: () => client,
        store: store,
        writeDebounce: Duration.zero,
      );
      await controller.initialize();

      await expectLater(
        controller.join('never-saved-secret'),
        throwsA(isA<ChatStoreException>()),
      );
      expect(controller.chats, isEmpty);
      expect(controller.storageError, isNotNull);
      controller.dispose();
    });

    test(
      'failed connection is disposed before join reports the error',
      () async {
        final disk = MemoryCiphertextBackend();
        final keys = MemoryKeyBackend();
        final client = FakeClient(
          connectedSnapshot: _snapshot(const <String>[]),
          connectError: const HarnessException('bad link'),
        );
        final controller = _controller(disk, keys, <FakeClient>[client]);
        await controller.initialize();

        await expectLater(
          controller.join('invalid-capability'),
          throwsA(isA<HarnessException>()),
        );
        expect(client.disposed, isTrue);
        expect(controller.chats, isEmpty);
        controller.dispose();
      },
    );

    test('corruption is surfaced without overwriting ciphertext', () async {
      final disk = MemoryCiphertextBackend()
        ..bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final original = Uint8List.fromList(disk.bytes!);
      final keys = MemoryKeyBackend()
        ..bytes = Uint8List.fromList(List<int>.filled(32, 1));
      final controller = _controller(disk, keys, <FakeClient>[]);

      await controller.initialize();

      expect(controller.isLoading, isFalse);
      expect(controller.storageError, isNotNull);
      expect(controller.chats, isEmpty);
      expect(disk.bytes, orderedEquals(original));
      await expectLater(controller.flush(), throwsA(isA<ChatStoreException>()));
      expect(disk.bytes, orderedEquals(original));
      controller.dispose();
    });
    test(
      'sending does not clear a draft edited while send is in flight',
      () async {
        final disk = MemoryCiphertextBackend();
        final keys = MemoryKeyBackend();
        final sendGate = Completer<void>();
        final client = FakeClient(
          connectedSnapshot: _snapshot(<String>['m']),
          sendGate: sendGate,
        );
        final controller = _controller(disk, keys, <FakeClient>[client]);
        await controller.initialize();
        final thread = await controller.join('draft-link');
        controller.updateDraft(thread.id, 'first draft');

        final sending = controller.sendPrompt(thread.id, 'first draft');
        controller.updateDraft(thread.id, 'new draft while sending');
        sendGate.complete();
        await sending;
        await controller.flush();
        controller.dispose();

        final reconnectGate = Completer<void>();
        final restored = _controller(disk, keys, <FakeClient>[
          FakeClient(
            connectedSnapshot: _snapshot(<String>['remote']),
            gate: reconnectGate,
          ),
        ]);
        await restored.initialize();
        expect(restored.chats.single.draft, 'new draft while sending');
        restored.dispose();
        reconnectGate.complete();
      },
    );
    test('persists unsent dialogue independently of remote refresh', () async {
      final disk = MemoryCiphertextBackend();
      final keys = MemoryKeyBackend();
      final original = _controller(disk, keys, [
        FakeClient(connectedSnapshot: _snapshot(['original'])),
      ]);
      await original.initialize();
      final thread = await original.join('synthetic-link');
      original.upsertVoiceTurn(
        thread.id,
        const VoiceTurn(
          id: 'voice-1',
          sequence: 1,
          origin: VoiceTurnOrigin.user,
          text: 'still unsent',
        ),
      );
      await original.flush();
      original.dispose();
      final refreshedClient = FakeClient(connectedSnapshot: _snapshot(['new']));
      final restored = _controller(disk, keys, [refreshedClient]);
      await restored.initialize();
      expect(restored.chats.single.voiceTurns.single.text, 'still unsent');
      expect(
        restored.chats.single.voiceTurns.single.delivery,
        VoiceDelivery.pending,
      );
      await _settle();
      expect(restored.chats.single.snapshot.messages.single.id, 'new');
      expect(restored.chats.single.voiceTurns.single.id, 'voice-1');
      restored.dispose();
    });

    test(
      'directive attaches only to a real prepared outgoing prompt',
      () async {
        final disk = MemoryCiphertextBackend();
        final keys = MemoryKeyBackend();
        final client = FakeClient(connectedSnapshot: _snapshot([]));
        final controller = _controller(disk, keys, [client]);
        await controller.initialize();
        final thread = await controller.join('synthetic-link');
        controller.activateVoiceDirective(thread.id, 'two models');
        controller.setPromptPreparer(
          thread.id,
          (text) async => 'User: spoken\\n\\n$text',
        );
        expect(client.sentPrompts, isEmpty);
        final sent = await controller.sendPrompt(thread.id, 'typed');
        expect(sent, contains('User: spoken'));
        expect(sent, contains('two models'));
        final second = await controller.sendPrompt(thread.id, 'next typed');
        expect(second, isNot(contains('two models')));
        client.emit(
          HarnessSnapshot(
            phase: ConnectionPhase.live,
            readOnly: false,
            rawEntries: const [
              {'type': 'compaction', 'id': 'compact-1'},
            ],
          ),
        );
        final afterCompaction = await controller.sendPrompt(thread.id, 'after');
        expect(afterCompaction, contains('two models'));
        expect(client.sentPrompts, [sent, second, afterCompaction]);
        controller.dispose();
      },
    );
    test(
      'delegation leaves the composer draft and typed preparer untouched',
      () async {
        final client = FakeClient(connectedSnapshot: _snapshot([]));
        final controller = _controller(
          MemoryCiphertextBackend(),
          MemoryKeyBackend(),
          [client],
        );
        await controller.initialize();
        final thread = await controller.join('synthetic-link');
        controller.updateDraft(thread.id, 'unfinished typed message');
        controller.setPromptPreparer(
          thread.id,
          (text) async => 'typed-only $text',
        );
        final sent = await controller.sendPrompt(
          thread.id,
          'User: spoken',
          fromComposer: false,
        );
        expect(sent, 'User: spoken');
        expect(thread.draft, 'unfinished typed message');
        controller.dispose();
      },
    );

    test(
      'concurrent prompts are rejected, not queued for later replay',
      () async {
        final gate = Completer<void>();
        final client = FakeClient(
          connectedSnapshot: _snapshot([]),
          sendGate: gate,
        );
        final controller = _controller(
          MemoryCiphertextBackend(),
          MemoryKeyBackend(),
          [client],
        );
        await controller.initialize();
        final thread = await controller.join('synthetic-link');
        final first = controller.sendPrompt(thread.id, 'first');
        await _settle();
        await expectLater(
          controller.sendPrompt(thread.id, 'second'),
          throwsA(isA<HarnessException>()),
        );
        gate.complete();
        await first;
        expect(client.sentPrompts, ['first']);
        controller.dispose();
      },
    );

    test('missing marker after resync rearms next real prompt', () async {
      final client = FakeClient(connectedSnapshot: _snapshot([]));
      final controller = _controller(
        MemoryCiphertextBackend(),
        MemoryKeyBackend(),
        [client],
      );
      await controller.initialize();
      final thread = await controller.join('synthetic-link');
      controller.activateVoiceDirective(thread.id, 'two models');
      expect(
        await controller.sendPrompt(thread.id, 'first'),
        contains('two models'),
      );
      client.emit(const HarnessSnapshot(phase: ConnectionPhase.reconnecting));
      client.emit(
        const HarnessSnapshot(phase: ConnectionPhase.live, readOnly: false),
      );
      expect(
        await controller.sendPrompt(thread.id, 'next'),
        contains('two models'),
      );
      controller.dispose();
    });
    test(
      'host start date survives missing title, reconnect, and recreation',
      () async {
        final disk = MemoryCiphertextBackend();
        final keys = MemoryKeyBackend();
        final hostStart = DateTime(2020, 3, 4, 5);
        final original = _controller(disk, keys, [
          FakeClient(
            connectedSnapshot: HarnessSnapshot(
              phase: ConnectionPhase.live,
              title: 'OMP chat',
              sessionStartedAt: hostStart,
              readOnly: false,
              messages: [
                ChatMessage(
                  id: 'recent',
                  role: MessageRole.assistant,
                  text: 'Recent answer',
                  timestamp: DateTime(2026, 9, 25),
                ),
              ],
            ),
          ),
        ]);
        await original.initialize();
        final chat = await original.join('synthetic-link');
        expect(chat.title, '20-03-04 05 (OMP chat)');
        expect(channelFromChatThread(chat).createdAt, hostStart);
        await original.flush();
        original.dispose();

        final client = FakeClient(
          connectedSnapshot: const HarnessSnapshot(
            phase: ConnectionPhase.live,
            title: 'OMP chat',
            readOnly: false,
          ),
        );
        final restored = _controller(disk, keys, [client]);
        await restored.initialize();
        expect(restored.chats.single.title, '20-03-04 05 (OMP chat)');
        await _settle();
        expect(restored.chats.single.title, '20-03-04 05 (OMP chat)');
        client.emit(
          const HarnessSnapshot(
            phase: ConnectionPhase.error,
            title: 'OMP chat',
          ),
        );
        expect(restored.chats.single.title, '20-03-04 05 (OMP chat)');
        expect(
          channelFromChatThread(
            restored.chats.single,
          ).createdAt.isAtSameMomentAs(hostStart),
          isTrue,
        );
        await restored.flush();
        restored.dispose();
        final offline = _controller(disk, keys, [
          FakeClient(
            connectedSnapshot: const HarnessSnapshot(
              phase: ConnectionPhase.live,
              title: 'OMP chat',
              readOnly: false,
            ),
            connectError: const HarnessException('Host offline.'),
          ),
        ]);
        await offline.initialize();
        await _settle();
        expect(offline.chats.single.title, '20-03-04 05 (OMP chat)');
        expect(
          channelFromChatThread(
            offline.chats.single,
          ).createdAt.isAtSameMomentAs(hostStart),
          isTrue,
        );
        offline.dispose();
      },
    );

    test(
      'legacy labels survive while auto host names can rename and clear',
      () async {
        final disk = MemoryCiphertextBackend();
        final keys = MemoryKeyBackend();
        final hostStart = DateTime(2020, 3, 4, 5);
        await _store(disk, keys).save([
          StoredChat(
            id: '1',
            link: 'synthetic-1',
            label: 'Local bookmark',
            draft: '',
            reconnect: false,
            snapshot: StoredSnapshot(
              title: 'Old host',
              sessionStartedAt: hostStart,
              endpoint: '',
              model: '',
              readOnly: false,
              messages: const [],
            ),
          ),
          StoredChat(
            id: '2',
            link: 'synthetic-2',
            label: 'Old host',
            draft: '',
            reconnect: false,
            snapshot: StoredSnapshot(
              title: 'Old host',
              sessionStartedAt: hostStart,
              endpoint: '',
              model: '',
              readOnly: false,
              messages: const [],
            ),
          ),
        ]);
        final firstClient = FakeClient(connectedSnapshot: _snapshot([]));
        final secondClient = FakeClient(connectedSnapshot: _snapshot([]));
        final restored = _controller(disk, keys, [firstClient, secondClient]);
        await restored.initialize();
        expect(restored.chat('1')!.title, 'Local bookmark');
        expect(restored.chat('2')!.title, 'Old host');
        await restored.reconnect('1');
        await restored.reconnect('2');
        expect(restored.chat('1')!.title, 'Local bookmark');
        firstClient.emit(
          const HarnessSnapshot(
            phase: ConnectionPhase.live,
            title: '',
            readOnly: false,
          ),
        );
        expect(restored.chat('1')!.title, 'Local bookmark');
        expect(restored.chat('2')!.title, 'Remote room');
        secondClient.emit(
          const HarnessSnapshot(
            phase: ConnectionPhase.live,
            title: '',
            readOnly: false,
          ),
        );
        expect(restored.chat('2')!.title, '20-03-04 05 (OMP chat)');
        await restored.flush();
        expect(
          (await _store(
            disk,
            keys,
          ).load()).singleWhere((chat) => chat.id == '2').snapshot.title,
          isEmpty,
        );
        restored.dispose();

        final reconnectGate = Completer<void>();
        final recreated = _controller(disk, keys, [
          FakeClient(connectedSnapshot: _snapshot([])),
          FakeClient(gate: reconnectGate, connectedSnapshot: _snapshot([])),
        ]);
        await recreated.initialize();
        expect(recreated.chat('1')!.title, 'Local bookmark');
        // A connecting client's provisional name cannot undo the saved clear.
        expect(recreated.chat('2')!.title, '20-03-04 05 (OMP chat)');
        reconnectGate.complete();
        await _settle();
        // A subsequent live rename cannot replace a local label.
        expect(recreated.chat('1')!.title, 'Local bookmark');
        expect(recreated.chat('2')!.title, 'Remote room');
        recreated.dispose();
      },
    );

    test(
      'a legacy stale host label does not survive a cleared title',
      () async {
        final disk = MemoryCiphertextBackend();
        final keys = MemoryKeyBackend();
        final created = DateTime(2020, 3, 4, 5);
        await _store(disk, keys).save([
          StoredChat(
            id: '1',
            link: 'synthetic',
            label: 'Former host title',
            draft: '',
            reconnect: false,
            createdAt: created,
            snapshot: const StoredSnapshot(
              title: '',
              endpoint: '',
              model: '',
              readOnly: false,
              messages: [],
            ),
          ),
        ]);
        final client = FakeClient(connectedSnapshot: _snapshot([]));
        final controller = _controller(disk, keys, [client]);
        await controller.initialize();
        expect(controller.chat('1')!.title, '20-03-04 05 (OMP chat)');
        await controller.reconnect('1');
        expect(controller.chat('1')!.title, 'Remote room');
        client.emit(
          const HarnessSnapshot(phase: ConnectionPhase.live, title: ''),
        );
        expect(controller.chat('1')!.title, '20-03-04 05 (OMP chat)');
        await controller.flush();
        final saved = (await _store(disk, keys).load()).single;
        expect(saved.label, 'Former host title');
        expect(saved.localLabel, isFalse);
        controller.dispose();
      },
    );

    test('late host timestamp cannot change a persisted fallback', () async {
      final disk = MemoryCiphertextBackend();
      final keys = MemoryKeyBackend();
      final created = DateTime(2020, 3, 4, 5);
      await _store(disk, keys).save([
        StoredChat(
          id: '1',
          link: 'synthetic',
          label: 'OMP chat',
          draft: '',
          reconnect: false,
          createdAt: created,
          snapshot: const StoredSnapshot(
            title: 'OMP chat',
            endpoint: '',
            model: '',
            readOnly: false,
            messages: [],
          ),
        ),
      ]);
      final client = FakeClient(
        connectedSnapshot: HarnessSnapshot(
          phase: ConnectionPhase.live,
          title: 'OMP chat',
          sessionStartedAt: DateTime(1990, 1, 1),
        ),
      );
      final controller = _controller(disk, keys, [client]);
      await controller.initialize();
      expect(controller.chat('1')!.title, '20-03-04 05 (OMP chat)');
      await controller.reconnect('1');
      expect(controller.chat('1')!.title, '20-03-04 05 (OMP chat)');
      expect(controller.chat('1')!.createdAt.isAtSameMomentAs(created), isTrue);
      await controller.flush();
      controller.dispose();
      final other = _controller(disk, keys, [
        FakeClient(
          connectedSnapshot: const HarnessSnapshot(
            phase: ConnectionPhase.live,
            title: 'OMP chat',
          ),
        ),
      ]);
      await other.initialize();
      expect(other.chat('1')!.title, '20-03-04 05 (OMP chat)');
      other.dispose();
    });

    test(
      'failed reconnect keeps named chats with or without messages',
      () async {
        for (final cachedMessages in [
          const <ChatMessage>[],
          const [ChatMessage(id: 'm', role: MessageRole.user, text: 'cached')],
        ]) {
          final disk = MemoryCiphertextBackend();
          final keys = MemoryKeyBackend();
          await _store(disk, keys).save([
            StoredChat(
              id: '1',
              link: 'synthetic',
              label: 'Old host',
              draft: '',
              reconnect: false,
              snapshot: StoredSnapshot(
                title: 'Old host',
                endpoint: '',
                model: '',
                readOnly: false,
                messages: cachedMessages,
              ),
            ),
          ]);
          final client = FakeClient(
            connectedSnapshot: _snapshot([]),
            connectError: const HarnessException('Host offline.'),
          );
          final controller = _controller(disk, keys, [client]);
          await controller.initialize();
          await expectLater(
            controller.reconnect('1'),
            throwsA(isA<HarnessException>()),
          );
          expect(controller.chats.single.title, 'Old host');
          await controller.flush();
          expect(
            (await _store(disk, keys).load()).single.snapshot.title,
            'Old host',
          );
          controller.dispose();
        }
      },
    );

    test(
      'legacy generic chat gets a persisted connection date, not a message date',
      () async {
        final disk = MemoryCiphertextBackend();
        final keys = MemoryKeyBackend();
        await _store(disk, keys).save([
          StoredChat(
            id: '1',
            link: 'synthetic',
            label: 'OMP chat',
            draft: '',
            reconnect: false,
            snapshot: StoredSnapshot(
              title: 'OMP chat',
              endpoint: '',
              model: '',
              readOnly: false,
              messages: [
                ChatMessage(
                  id: 'old',
                  role: MessageRole.user,
                  text: 'old',
                  timestamp: DateTime.utc(2000, 1, 1),
                ),
              ],
            ),
          ),
        ]);
        final client = FakeClient(connectedSnapshot: _snapshot([]));
        final first = _controller(disk, keys, [client]);
        await first.initialize();
        final title = first.chats.single.title;
        expect(title, matches(RegExp(r'^\d\d-\d\d-\d\d \d\d \(OMP chat\)$')));
        expect(
          channelFromChatThread(first.chats.single).createdAt.year,
          DateTime.now().year,
        );
        client.emit(
          HarnessSnapshot(
            phase: ConnectionPhase.live,
            title: 'OMP chat',
            messages: [
              ChatMessage(
                id: 'new',
                role: MessageRole.assistant,
                text: 'new answer',
                timestamp: DateTime.utc(2040, 1, 1),
              ),
            ],
          ),
        );
        expect(first.chats.single.title, title);
        await first.flush();
        first.dispose();
        final second = _controller(disk, keys, [
          FakeClient(connectedSnapshot: _snapshot([])),
        ]);
        await second.initialize();
        expect(second.chats.single.title, title);
        second.dispose();
      },
    );

    test(
      'voice capacity rejects one chat without blocking other drafts',
      () async {
        final disk = MemoryCiphertextBackend();
        final keys = MemoryKeyBackend();
        const cached = StoredSnapshot(
          title: 'saved',
          endpoint: 'relay',
          model: '',
          readOnly: false,
          messages: [],
        );
        await _store(disk, keys).save([
          StoredChat(
            id: '1',
            link: 'synthetic-1',
            label: 'full',
            draft: '',
            reconnect: false,
            snapshot: cached,
            voiceTurns: List<VoiceTurn>.generate(
              maxStoredVoiceTurnsPerChat,
              (index) => VoiceTurn(
                id: 'turn-$index',
                sequence: index,
                origin: VoiceTurnOrigin.user,
                text: 'pending',
              ),
            ),
          ),
          const StoredChat(
            id: '2',
            link: 'synthetic-2',
            label: 'other',
            draft: '',
            reconnect: false,
            snapshot: cached,
          ),
        ]);
        final controller = _controller(disk, keys, [
          FakeClient(connectedSnapshot: _snapshot([])),
          FakeClient(connectedSnapshot: _snapshot([])),
        ]);
        await controller.initialize();
        expect(
          () => controller.upsertVoiceTurn(
            '1',
            const VoiceTurn(
              id: 'overflow',
              sequence: maxStoredVoiceTurnsPerChat,
              origin: VoiceTurnOrigin.user,
              text: 'do not drop',
            ),
          ),
          throwsA(isA<ChatStoreException>()),
        );
        controller.updateDraft('2', 'other chat persists');
        await controller.flush();
        final restored = await _store(disk, keys).load();
        expect(
          restored.first.voiceTurns,
          hasLength(maxStoredVoiceTurnsPerChat),
        );
        expect(restored.last.draft, 'other chat persists');
        controller.dispose();
      },
    );
  });
}

CompanionController _controller(
  MemoryCiphertextBackend disk,
  MemoryKeyBackend keys,
  List<FakeClient> clients,
) {
  var index = 0;
  return CompanionController(
    clientFactory: () => clients[index++],
    store: _store(disk, keys),
    writeDebounce: Duration.zero,
  );
}

EncryptedFileChatStore _store(
  MemoryCiphertextBackend disk,
  MemoryKeyBackend keys,
) => EncryptedFileChatStore(ciphertext: disk, keys: keys);

HarnessSnapshot _snapshot(List<String> ids) => HarnessSnapshot(
  phase: ConnectionPhase.live,
  title: 'Remote room',
  endpoint: 'wss://relay.example',
  model: 'model',
  readOnly: false,
  messages: ids
      .map(
        (id) => ChatMessage(
          id: id,
          role: MessageRole.assistant,
          text: 'message $id',
        ),
      )
      .toList(),
);

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class FakeControlLossClient extends FakeClient implements OmpdControlStatus {
  FakeControlLossClient({
    required super.connectedSnapshot,
    super.gate,
    super.connectError,
  });

  @override
  bool controlLost = false;
}

class FakeClient implements HarnessClient {
  FakeClient({
    required this.connectedSnapshot,
    this.gate,
    this.sendGate,
    this.connectError,
    this.throwOnDispose = false,
  });

  final HarnessSnapshot connectedSnapshot;
  final Completer<void>? sendGate;
  final Completer<void>? gate;
  HarnessException? connectError;
  final bool throwOnDispose;
  final StreamController<HarnessSnapshot> _changes =
      StreamController<HarnessSnapshot>.broadcast(sync: true);
  HarnessSnapshot _snapshot = const HarnessSnapshot();
  int connectCalls = 0;
  int abortCalls = 0;
  bool disposed = false;
  final List<String> sentPrompts = [];
  final List<String> connectedInputs = [];

  @override
  HarnessSnapshot get snapshot => _snapshot;

  @override
  Stream<HarnessSnapshot> get changes => _changes.stream;

  void emit(HarnessSnapshot value) {
    _snapshot = value;
    _changes.add(value);
  }

  @override
  Future<void> connect(String input, {String displayName = 'raiju'}) async {
    connectCalls++;
    connectedInputs.add(input);
    _snapshot = HarnessSnapshot(
      phase: ConnectionPhase.connecting,
      sessionId: connectedSnapshot.sessionId,
      title: connectedSnapshot.title,
      endpoint: connectedSnapshot.endpoint,
      readOnly: true,
    );
    _changes.add(_snapshot);
    if (gate != null) await gate!.future;
    if (disposed) throw const HarnessException('Connection cancelled.');
    final error = connectError;
    if (error != null) throw error;
    _snapshot = connectedSnapshot;
    _changes.add(_snapshot);
  }

  @override
  Future<void> disconnect() async {
    _snapshot = HarnessSnapshot(
      phase: ConnectionPhase.disconnected,
      title: _snapshot.title,
      endpoint: _snapshot.endpoint,
      model: _snapshot.model,
      messages: _snapshot.messages,
      readOnly: true,
    );
    _changes.add(_snapshot);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _changes.close();
    if (throwOnDispose) throw StateError('simulated teardown failure');
  }

  @override
  Future<void> abort() async {
    abortCalls++;
  }

  @override
  Future<void> respond(int requestId, String? value) async {}

  @override
  Future<void> sendPrompt(String text) async {
    sentPrompts.add(text);
    if (sendGate != null) await sendGate!.future;
  }
}

class MemoryCiphertextBackend implements ChatCiphertextBackend {
  Uint8List? bytes;
  Completer<void>? pendingWrite;
  Completer<void>? writeEntered;
  bool failWrite = false;

  @override
  Future<Uint8List?> read() async =>
      bytes == null ? null : Uint8List.fromList(bytes!);

  @override
  Future<void> writeAtomic(Uint8List value) async {
    writeEntered?.complete();
    writeEntered = null;
    if (pendingWrite != null) await pendingWrite!.future;
    if (failWrite) throw StateError('simulated write failure');
    bytes = Uint8List.fromList(value);
  }
}

class MemoryKeyBackend implements ChatKeyBackend {
  Uint8List? bytes;

  @override
  Future<Uint8List?> read() async =>
      bytes == null ? null : Uint8List.fromList(bytes!);

  @override
  Future<void> write(Uint8List key) async {
    bytes = Uint8List.fromList(key);
  }
}

class FailingSaveStore implements ChatStore {
  @override
  Future<List<StoredChat>> load() async => const <StoredChat>[];

  @override
  Future<void> save(List<StoredChat> chats) async {
    throw const ChatStoreException(
      ChatStoreFailure.io,
      'Saved chats could not be written.',
    );
  }
}
