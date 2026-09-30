import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:buzz/harness/harness.dart';
import 'package:buzz/harness/voice_directive.dart';
import 'package:buzz/storage/chat_store.dart';
import 'package:buzz/storage/encrypted_file_chat_store.dart';
import 'package:buzz/storage/voice_transcript.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EncryptedFileChatStore', () {
    test('round trips private state without plaintext at rest', () async {
      final files = MemoryCiphertextBackend();
      final keys = MemoryKeyBackend();
      final store = EncryptedFileChatStore(ciphertext: files, keys: keys);

      await store.save(<StoredChat>[_chat()]);

      final disk = utf8.decode(files.bytes!);
      expect(disk, isNot(contains('secret-room-token')));
      expect(disk, isNot(contains('private draft')));
      expect(keys.bytes, hasLength(32));
      final restored = await store.load();
      expect(restored.single.link, 'https://relay/join#secret-room-token');
      expect(restored.single.draft, 'private draft');
      expect(restored.single.snapshot.messages.single.text, 'cached answer');
    });

    test(
      'undelegated voice survives store recreation without remote delivery',
      () async {
        final files = MemoryCiphertextBackend();
        final keys = MemoryKeyBackend();
        final first = EncryptedFileChatStore(ciphertext: files, keys: keys);
        final turns = List<VoiceTurn>.generate(
          250,
          (index) => VoiceTurn(
            id: 'local-$index',
            sequence: index,
            origin: index.isEven ? VoiceTurnOrigin.user : VoiceTurnOrigin.spark,
            text: 'unsent private dialogue $index',
            createdAt: DateTime.utc(2026, 9, 29, 10, 0, index % 60),
          ),
        );
        final base = _chat();
        await first.save([
          StoredChat(
            id: base.id,
            link: base.link,
            label: base.label,
            draft: base.draft,
            reconnect: base.reconnect,
            snapshot: base.snapshot,
            voiceTurns: turns,
          ),
        ]);
        expect(
          utf8.decode(files.bytes!),
          isNot(contains('unsent private dialogue')),
        );
        final restored = (await EncryptedFileChatStore(
          ciphertext: files,
          keys: keys,
        ).load()).single;
        expect(restored.voiceTurns, hasLength(250));
        expect(restored.voiceTurns.last.text, 'unsent private dialogue 249');
        expect(
          restored.voiceTurns.last.createdAt,
          DateTime.utc(2026, 9, 29, 10, 0, 249 % 60),
        );
        expect(restored.voiceTurns.last.delivery, VoiceDelivery.pending);
      },
    );

    test(
      'session date, explicit label, and routing provenance survive recreation',
      () async {
        final files = MemoryCiphertextBackend();
        final keys = MemoryKeyBackend();
        final base = _chat();
        final start = DateTime.utc(2020, 3, 4, 5);
        final connected = DateTime.utc(2026, 9, 25, 12);
        await EncryptedFileChatStore(ciphertext: files, keys: keys).save([
          StoredChat(
            id: base.id,
            link: base.link,
            label: 'Local label',
            localLabel: true,
            createdAt: connected,
            draft: base.draft,
            reconnect: false,
            snapshot: StoredSnapshot(
              title: '',
              sessionStartedAt: start,
              endpoint: base.snapshot.endpoint,
              model: base.snapshot.model,
              readOnly: true,
              messages: base.snapshot.messages,
            ),
            voiceTurns: const [
              VoiceTurn(
                id: 'request-1',
                sequence: 1,
                origin: VoiceTurnOrigin.user,
                text: '',
                delivery: VoiceDelivery.uncertain,
                routingPurpose: VoiceTurnPurpose.request,
                routingRequestId: 'local-request-1',
                routingRequestText: '',
                routingPackageText: 'User: context',
                routingSourceTurnId: 'user-1',
                routingAwaitingSource: true,
                precedingHostEntryId: 'entry-1',
              ),
            ],
          ),
        ]);
        final restored = (await EncryptedFileChatStore(
          ciphertext: files,
          keys: keys,
        ).load()).single;
        expect(restored.createdAt, connected);
        expect(restored.localLabel, isTrue);
        expect(restored.snapshot.sessionStartedAt, start);
        final reservation = restored.voiceTurns.single;
        expect(reservation.routingPurpose, VoiceTurnPurpose.request);
        expect(reservation.routingRequestId, 'local-request-1');
        expect(reservation.routingRequestText, '');
        expect(reservation.routingPackageText, 'User: context');
        expect(reservation.routingSourceTurnId, 'user-1');
        expect(reservation.routingAwaitingSource, isTrue);
        expect(reservation.precedingHostEntryId, 'entry-1');
      },
    );

    test('older payload defaults and voice maps remain readable', () async {
      final files = MemoryCiphertextBackend();
      final keys = MemoryKeyBackend();
      final base = _chat();
      await EncryptedFileChatStore(ciphertext: files, keys: keys).save([
        StoredChat(
          id: base.id,
          link: base.link,
          label: base.label,
          draft: base.draft,
          reconnect: false,
          snapshot: base.snapshot,
          voiceTurns: const [
            VoiceTurn(
              id: 'legacy-voice',
              sequence: 1,
              origin: VoiceTurnOrigin.user,
              text: 'unsent',
            ),
          ],
        ),
      ]);
      final stored = (await EncryptedFileChatStore(
        ciphertext: files,
        keys: keys,
      ).load()).single;
      expect(stored.createdAt, isNull);
      expect(stored.localLabel, isNull);
      expect(stored.snapshot.sessionStartedAt, isNull);
      expect(
        stored.voiceTurns.single.routingPurpose,
        VoiceTurnPurpose.dialogue,
      );
      final oldVoice = VoiceTurn.fromJson({
        'id': 'legacy-voice',
        'sequence': 1,
        'origin': 'user',
        'text': 'unsent',
        'delivery': 'pending',
        'hostEntryId': null,
        'precedingHostEntryId': null,
        'precedingRenderedEntryId': null,
        'typedEcho': false,
        'echoRemainder': null,
      });
      expect(oldVoice.routingPurpose, VoiceTurnPurpose.dialogue);
      expect(oldVoice.routingAwaitingSource, isFalse);
      expect(oldVoice.createdAt, isNull);
      expect(
        () => VoiceTurn.fromJson({...oldVoice.toJson(), 'createdAt': 123}),
        throwsFormatException,
      );
      expect(
        () => VoiceTurn.fromJson({...oldVoice.toJson(), 'sequence': -1}),
        throwsFormatException,
      );
      expect(
        () => VoiceTurn.fromJson({...oldVoice.toJson(), 'typedEcho': 'true'}),
        throwsFormatException,
      );
      expect(stored.voiceTurns.single.routingAwaitingSource, isFalse);
    });

    test('typed echo provenance survives encrypted reload', () async {
      final files = MemoryCiphertextBackend();
      final keys = MemoryKeyBackend();
      final base = _chat();
      await EncryptedFileChatStore(ciphertext: files, keys: keys).save([
        StoredChat(
          id: base.id,
          link: base.link,
          label: base.label,
          draft: base.draft,
          reconnect: false,
          snapshot: base.snapshot,
          voiceTurns: const [
            VoiceTurn(
              id: 'typed-1',
              sequence: 1,
              origin: VoiceTurnOrigin.typedUser,
              text: 'Typed in Spark',
              delivery: VoiceDelivery.delivered,
              hostEntryId: 'host-1',
              precedingHostEntryId: 'prior-1',
              precedingRenderedEntryId: 'visible-prior',
              echoRemainder: 'actual typed suffix',
              typedEcho: true,
            ),
          ],
        ),
      ]);
      final turn = (await EncryptedFileChatStore(
        ciphertext: files,
        keys: keys,
      ).load()).single.voiceTurns.single;
      expect(turn.origin, VoiceTurnOrigin.typedUser);
      expect(turn.typedEcho, isTrue);
      expect(turn.hostEntryId, 'host-1');
      expect(turn.precedingHostEntryId, 'prior-1');
      expect(turn.precedingRenderedEntryId, 'visible-prior');
      expect(turn.echoRemainder, 'actual typed suffix');
    });

    test(
      'cached source and prose retain identity without display fallback',
      () async {
        final files = MemoryCiphertextBackend();
        final keys = MemoryKeyBackend();
        final base = _chat();
        await EncryptedFileChatStore(ciphertext: files, keys: keys).save([
          StoredChat(
            id: base.id,
            link: base.link,
            label: base.label,
            draft: base.draft,
            reconnect: false,
            snapshot: const StoredSnapshot(
              title: 'chat',
              endpoint: 'relay',
              model: 'model',
              readOnly: false,
              rawEntries: [
                {'type': 'compaction', 'id': 'actual-boundary'},
              ],
              messages: [
                ChatMessage(
                  id: 'assistant-entry',
                  role: MessageRole.assistant,
                  text: 'Spoken\\nUsing read…',
                  prose: 'Spoken',
                  source: {
                    'role': 'assistant',
                    'content': [
                      {'type': 'text', 'text': 'Spoken'},
                      {'type': 'toolCall', 'name': 'read'},
                    ],
                  },
                  origin: ChatMessageOrigin.remoteAssistant,
                ),
              ],
            ),
          ),
        ]);
        final restored = (await EncryptedFileChatStore(
          ciphertext: files,
          keys: keys,
        ).load()).single.snapshot;
        expect(restored.messages.single.prose, 'Spoken');
        expect(
          restored.messages.single.origin,
          ChatMessageOrigin.remoteAssistant,
        );
        expect(restored.messages.single.source!['role'], 'assistant');
        expect(restored.rawEntries.single['id'], 'actual-boundary');
      },
    );
    test(
      'oversized cached echo keeps exact confirmed suffix in voice overlay',
      () async {
        final files = MemoryCiphertextBackend();
        final keys = MemoryKeyBackend();
        final prefix = List<String>.filled(21000, 'v').join();
        const suffix = 'exact typed message after oversized dialogue';
        final base = _chat();
        await EncryptedFileChatStore(ciphertext: files, keys: keys).save([
          StoredChat(
            id: base.id,
            link: base.link,
            label: base.label,
            draft: base.draft,
            reconnect: false,
            snapshot: StoredSnapshot(
              title: 'chat',
              endpoint: 'relay',
              model: 'model',
              readOnly: false,
              messages: [
                ChatMessage(
                  id: 'echo-1',
                  role: MessageRole.user,
                  text: '$prefix$suffix',
                  prose: '$prefix$suffix',
                  source: {
                    'type': 'custom_message',
                    'content': '$prefix$suffix',
                  },
                  origin: ChatMessageOrigin.collabUser,
                ),
              ],
            ),
            voiceTurns: const [
              VoiceTurn(
                id: 'local-1',
                sequence: 1,
                origin: VoiceTurnOrigin.user,
                text: 'voice',
                delivery: VoiceDelivery.delivered,
                hostEntryId: 'echo-1',
                typedEcho: true,
                echoRemainder: suffix,
              ),
            ],
          ),
        ]);
        final restored = (await EncryptedFileChatStore(
          ciphertext: files,
          keys: keys,
        ).load()).single;
        expect(restored.snapshot.messages.single.source, isNull);
        expect(
          restored.snapshot.messages.single.origin,
          ChatMessageOrigin.collabUser,
        );
        expect(restored.snapshot.messages.single.text, hasLength(20000));
        expect(restored.voiceTurns.single.echoRemainder, suffix);
      },
    );

    test(
      'oversized compaction does not revive a pre-compaction marker',
      () async {
        final files = MemoryCiphertextBackend();
        final keys = MemoryKeyBackend();
        final base = _chat();
        await EncryptedFileChatStore(ciphertext: files, keys: keys).save([
          StoredChat(
            id: base.id,
            link: base.link,
            label: base.label,
            draft: '',
            reconnect: false,
            snapshot: StoredSnapshot(
              title: 'chat',
              endpoint: 'relay',
              model: '',
              readOnly: false,
              messages: const [],
              rawEntries: [
                {
                  'type': 'custom_message',
                  'id': 'before',
                  'customType': 'collab-prompt',
                  'content': VoiceDirective.decorate('real', 'two models'),
                },
                {
                  'type': 'compaction',
                  'id': 'large',
                  'summary': List<String>.filled(260000, 'c').join(),
                },
                {
                  'type': 'message',
                  'id': 'after',
                  'message': {'role': 'user', 'content': 'after'},
                },
              ],
            ),
          ),
        ]);
        final entries = (await EncryptedFileChatStore(
          ciphertext: files,
          keys: keys,
        ).load()).single.snapshot.rawEntries;
        expect(entries.map((entry) => entry['id']), ['after']);
        expect(VoiceDirective.isPresent(entries), isFalse);
      },
    );

    test('a different device key cannot decrypt the file', () async {
      final files = MemoryCiphertextBackend();
      final firstKeys = MemoryKeyBackend();
      await EncryptedFileChatStore(
        ciphertext: files,
        keys: firstKeys,
      ).save(<StoredChat>[_chat()]);

      final isolatedKeys = MemoryKeyBackend()
        ..bytes = Uint8List.fromList(List<int>.filled(32, 7));
      final isolated = EncryptedFileChatStore(
        ciphertext: files,
        keys: isolatedKeys,
      );
      final original = Uint8List.fromList(files.bytes!);

      await expectLater(
        isolated.load(),
        throwsA(
          isA<ChatStoreException>().having(
            (error) => error.failure,
            'failure',
            ChatStoreFailure.corrupt,
          ),
        ),
      );
      await expectLater(
        isolated.save(<StoredChat>[_chat(draft: 'replacement')]),
        throwsA(
          isA<ChatStoreException>().having(
            (error) => error.failure,
            'failure',
            ChatStoreFailure.corrupt,
          ),
        ),
      );
      expect(files.bytes, orderedEquals(original));
      expect(files.bytes, isNotNull);
    });

    test('missing key does not replace existing ciphertext', () async {
      final files = MemoryCiphertextBackend();
      final keys = MemoryKeyBackend();
      final store = EncryptedFileChatStore(ciphertext: files, keys: keys);
      await store.save(<StoredChat>[_chat()]);
      final original = Uint8List.fromList(files.bytes!);
      keys.bytes = null;

      await expectLater(
        store.load(),
        throwsA(
          isA<ChatStoreException>().having(
            (error) => error.failure,
            'failure',
            ChatStoreFailure.keyUnavailable,
          ),
        ),
      );
      await expectLater(
        store.save(<StoredChat>[_chat(draft: 'replacement')]),
        throwsA(
          isA<ChatStoreException>().having(
            (error) => error.failure,
            'failure',
            ChatStoreFailure.keyUnavailable,
          ),
        ),
      );
      expect(files.bytes, orderedEquals(original));
    });

    test('corruption is surfaced and retained', () async {
      final files = MemoryCiphertextBackend();
      final store = EncryptedFileChatStore(
        ciphertext: files,
        keys: MemoryKeyBackend(),
      );
      await store.save(<StoredChat>[_chat()]);
      files.bytes![files.bytes!.length ~/ 2] ^= 0xff;
      final corrupted = Uint8List.fromList(files.bytes!);

      await expectLater(
        store.load(),
        throwsA(
          isA<ChatStoreException>().having(
            (error) => error.failure,
            'failure',
            ChatStoreFailure.corrupt,
          ),
        ),
      );
      await expectLater(
        store.save(<StoredChat>[_chat(draft: 'replacement')]),
        throwsA(
          isA<ChatStoreException>().having(
            (error) => error.failure,
            'failure',
            ChatStoreFailure.corrupt,
          ),
        ),
      );
      expect(files.bytes, orderedEquals(corrupted));
    });

    test('serializes concurrent writes and last write wins', () async {
      final files = MemoryCiphertextBackend(
        writeDelay: const Duration(milliseconds: 5),
      );
      final keys = MemoryKeyBackend();
      final store = EncryptedFileChatStore(ciphertext: files, keys: keys);

      await Future.wait(<Future<void>>[
        store.save(<StoredChat>[_chat(draft: 'first')]),
        store.save(<StoredChat>[_chat(draft: 'second')]),
        store.save(<StoredChat>[_chat(draft: 'last')]),
      ]);

      expect(files.maximumConcurrentWrites, 1);
      expect((await store.load()).single.draft, 'last');
    });

    test(
      'preserves full drafts and keeps only newest cached messages',
      () async {
        final store = EncryptedFileChatStore(
          ciphertext: MemoryCiphertextBackend(),
          keys: MemoryKeyBackend(),
        );
        final messages = List<ChatMessage>.generate(
          250,
          (index) => ChatMessage(
            id: '$index',
            role: MessageRole.assistant,
            text: 'message',
          ),
        );
        await store.save(<StoredChat>[
          StoredChat(
            id: 'bounded',
            link: 'secret',
            label: 'room',
            draft: List<String>.filled(100005, 'd').join(),
            reconnect: true,
            snapshot: StoredSnapshot(
              title: 'room',
              endpoint: 'relay',
              model: 'model',
              readOnly: false,
              messages: messages,
            ),
          ),
        ]);

        final restored = (await store.load()).single;
        expect(restored.draft, hasLength(100005));
        expect(
          restored.snapshot.messages,
          hasLength(EncryptedFileChatStore.maxMessagesPerChat),
        );
        expect(restored.snapshot.messages.first.id, '50');
        expect(restored.snapshot.messages.last.id, '249');
      },
    );

    test('rejects chat overflow instead of silently truncating', () async {
      final store = EncryptedFileChatStore(
        ciphertext: MemoryCiphertextBackend(),
        keys: MemoryKeyBackend(),
      );
      final chats = List<StoredChat>.generate(
        EncryptedFileChatStore.maxChats + 1,
        (index) => _chat(id: '$index'),
      );

      await expectLater(
        store.save(chats),
        throwsA(
          isA<ChatStoreException>().having(
            (error) => error.failure,
            'failure',
            ChatStoreFailure.capacity,
          ),
        ),
      );
    });

    test(
      'in-place key migration retains ciphertext and old key bytes',
      () async {
        final storage = _MigratingSecureStorage();
        final files = MemoryCiphertextBackend();
        final keys = SecureStorageChatKeyBackend(
          storage,
          migrate: () async => storage.migrated = true,
        );
        final store = EncryptedFileChatStore(ciphertext: files, keys: keys);
        await store.save([_chat()]);
        final encrypted = Uint8List.fromList(files.bytes!);
        final oldKey = storage.value;
        storage.migrated = false;
        expect((await store.load()).single.draft, 'private draft');
        expect(files.bytes, orderedEquals(encrypted));
        expect(storage.value, oldKey);
        expect(storage.lastAccessibility, KeychainAccessibility.first_unlock);
      },
    );

    test('failed key migration never replaces ciphertext or secret', () async {
      final files = MemoryCiphertextBackend();
      final storage = _MigratingSecureStorage();
      var failed = false;
      final keys = SecureStorageChatKeyBackend(
        storage,
        migrate: () async {
          if (failed) throw StateError('locked');
          storage.migrated = true;
        },
      );
      final store = EncryptedFileChatStore(ciphertext: files, keys: keys);
      await store.save([_chat()]);
      final encrypted = Uint8List.fromList(files.bytes!);
      final oldKey = storage.value;
      failed = true;
      await expectLater(
        store.load(),
        throwsA(
          isA<ChatStoreException>().having(
            (error) => error.failure,
            'failure',
            ChatStoreFailure.keyUnavailable,
          ),
        ),
      );
      await expectLater(
        store.save([_chat(draft: 'must not replace')]),
        throwsA(
          isA<ChatStoreException>().having(
            (error) => error.failure,
            'failure',
            ChatStoreFailure.keyUnavailable,
          ),
        ),
      );
      expect(files.bytes, orderedEquals(encrypted));
      expect(storage.value, oldKey);
    });

    test('protection covers existing file and atomic replacement', () async {
      final directory = await Directory.systemTemp.createTemp(
        'protected-chats',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/private-chats.v1.enc');
      final protected = <String>[];
      final backend = AppSupportCiphertextBackend(
        file,
        protect: (candidate) async => protected.add(candidate.path),
      );
      await backend.writeAtomic(Uint8List.fromList([1]));
      await backend.read();
      await backend.writeAtomic(Uint8List.fromList([2]));
      expect(protected.where((path) => path == file.path), hasLength(3));
      expect(
        protected.where((path) => path.startsWith('${file.path}.tmp-')),
        hasLength(2),
      );
      expect(await backend.read(), orderedEquals([2]));
    });

    test(
      'failed file protection leaves previous ciphertext untouched',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'protected-chats',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/private-chats.v1.enc');
        await file.writeAsBytes([1, 2, 3]);
        final backend = AppSupportCiphertextBackend(
          file,
          protect: (_) async => throw StateError('protection unavailable'),
        );
        await expectLater(backend.read(), throwsA(isA<ChatStoreException>()));
        await expectLater(
          backend.writeAtomic(Uint8List.fromList([4])),
          throwsA(isA<ChatStoreException>()),
        );
        expect(await file.readAsBytes(), orderedEquals([1, 2, 3]));
      },
    );

    test('file backend atomically replaces its target', () async {
      final directory = await Directory.systemTemp.createTemp(
        'buzz-chat-store',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/chats.enc');
      final backend = AppSupportCiphertextBackend(file, protect: (_) async {});
      await backend.writeAtomic(Uint8List.fromList(<int>[1, 2, 3]));
      await backend.writeAtomic(Uint8List.fromList(<int>[4, 5]));

      expect(await backend.read(), orderedEquals(<int>[4, 5]));
      expect(directory.listSync().map((entry) => entry.path), <String>[
        file.path,
      ]);
    });
  });
}

StoredChat _chat({String id = '1', String draft = 'private draft'}) =>
    StoredChat(
      id: id,
      link: 'https://relay/join#secret-room-token',
      label: 'Saved room',
      draft: draft,
      reconnect: true,
      snapshot: const StoredSnapshot(
        title: 'Saved room',
        endpoint: 'wss://relay',
        model: 'model',
        readOnly: false,
        messages: <ChatMessage>[
          ChatMessage(
            id: 'm1',
            role: MessageRole.assistant,
            text: 'cached answer',
          ),
        ],
      ),
    );

class MemoryCiphertextBackend implements ChatCiphertextBackend {
  MemoryCiphertextBackend({this.writeDelay = Duration.zero});

  Uint8List? bytes;
  final Duration writeDelay;
  int _concurrentWrites = 0;
  int maximumConcurrentWrites = 0;

  @override
  Future<Uint8List?> read() async =>
      bytes == null ? null : Uint8List.fromList(bytes!);

  @override
  Future<void> writeAtomic(Uint8List value) async {
    _concurrentWrites++;
    if (_concurrentWrites > maximumConcurrentWrites) {
      maximumConcurrentWrites = _concurrentWrites;
    }
    await Future<void>.delayed(writeDelay);
    bytes = Uint8List.fromList(value);
    _concurrentWrites--;
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

class _MigratingSecureStorage extends Fake implements FlutterSecureStorage {
  String? value;
  bool migrated = false;
  KeychainAccessibility? lastAccessibility;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
    AppleOptions? mOptions,
  }) async {
    if (!migrated) throw StateError('key locked');
    lastAccessibility = iOptions?.accessibility;
    return value;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    WindowsOptions? wOptions,
    AppleOptions? mOptions,
  }) async {
    if (!migrated) throw StateError('key locked');
    lastAccessibility = iOptions?.accessibility;
    this.value = value;
  }
}
