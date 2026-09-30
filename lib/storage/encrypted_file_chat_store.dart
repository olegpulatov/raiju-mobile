import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../harness/harness.dart';
import 'chat_store.dart';
import 'voice_transcript.dart';

const _chatProtectionChannel = MethodChannel('raiju/chat_store_protection');

Future<void> _protectChatFile(File file) async {
  if (Platform.isIOS) {
    await _chatProtectionChannel.invokeMethod<void>(
      'protectCiphertext',
      file.path,
    );
  }
}

Future<void> _migrateChatKey() async {
  if (Platform.isIOS) {
    await _chatProtectionChannel.invokeMethod<void>('migrateKey');
  }
}

abstract interface class ChatCiphertextBackend {
  Future<Uint8List?> read();
  Future<void> writeAtomic(Uint8List bytes);
}

abstract interface class ChatKeyBackend {
  Future<Uint8List?> read();
  Future<void> write(Uint8List key);
}

class AppSupportCiphertextBackend implements ChatCiphertextBackend {
  AppSupportCiphertextBackend(this.file, {Future<void> Function(File)? protect})
    : _protect = protect ?? _protectChatFile;

  final File file;
  final Future<void> Function(File) _protect;

  @override
  Future<Uint8List?> read() async {
    try {
      await _protect(file);
      if (!await file.exists()) return null;
      return file.readAsBytes();
    } catch (error) {
      throw ChatStoreException(
        ChatStoreFailure.io,
        'Saved chats could not be read.',
        error,
      );
    }
  }

  @override
  Future<void> writeAtomic(Uint8List bytes) async {
    final temporary = File(
      '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await _protect(file);
      await file.parent.create(recursive: true);
      await temporary.writeAsBytes(bytes, flush: true);
      await _protect(temporary);
      await temporary.rename(file.path);
    } catch (error) {
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {
        // Preserve the original actionable error.
      }
      throw ChatStoreException(
        ChatStoreFailure.io,
        'Saved chats could not be written.',
        error,
      );
    }
  }
}

class SecureStorageChatKeyBackend implements ChatKeyBackend {
  SecureStorageChatKeyBackend(
    this.storage, {
    Future<void> Function()? migrate,
    this.keyName = 'raiju.chat-store.aes-gcm.v1',
  }) : migrate =
           migrate ??
           (keyName == 'raiju.chat-store.aes-gcm.v1' ? _migrateChatKey : null);

  final FlutterSecureStorage storage;
  final Future<void> Function()? migrate;
  final String keyName;

  @override
  Future<Uint8List?> read() async {
    try {
      if (migrate != null) await migrate!();
      final encoded = await storage.read(
        key: keyName,
        iOptions: keyName == 'raiju.chat-store.aes-gcm.v1'
            ? const IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              )
            : const IOSOptions(),
      );
      if (encoded == null) return null;
      final key = base64Decode(encoded);
      if (key.length != 32) {
        throw const FormatException('Unexpected key length');
      }
      return Uint8List.fromList(key);
    } catch (error) {
      throw ChatStoreException(
        ChatStoreFailure.keyUnavailable,
        'The device key for saved chats is unavailable.',
        error,
      );
    }
  }

  @override
  Future<void> write(Uint8List key) async {
    try {
      if (migrate != null) await migrate!();
      await storage.write(
        key: keyName,
        value: base64Encode(key),
        iOptions: keyName == 'raiju.chat-store.aes-gcm.v1'
            ? const IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              )
            : const IOSOptions(),
      );
    } catch (error) {
      throw ChatStoreException(
        ChatStoreFailure.keyUnavailable,
        'The device key for saved chats could not be stored.',
        error,
      );
    }
  }
}

/// AES-GCM encrypted JSON store. Writes are serialized and replace the file
/// atomically. A missing/unavailable key never causes existing ciphertext to be
/// reset.
class EncryptedFileChatStore implements ChatStore {
  EncryptedFileChatStore({
    required ChatCiphertextBackend ciphertext,
    required ChatKeyBackend keys,
    AesGcm? cipher,
  }) : _ciphertext = ciphertext,
       _keys = keys,
       _cipher = cipher ?? AesGcm.with256bits();

  static const int maxChats = 100;
  static const int maxMessagesPerChat = 200;
  static const int maxMessageCharacters = 20000;
  static const int maxCachedSourceBytes = 256000;
  static const int maxVoiceTurnsPerChat = maxStoredVoiceTurnsPerChat;

  final ChatCiphertextBackend _ciphertext;
  final ChatKeyBackend _keys;
  final AesGcm _cipher;
  Future<void> _operations = Future<void>.value();

  static Future<EncryptedFileChatStore> production({
    FlutterSecureStorage? secureStorage,
  }) async {
    final directory = await getApplicationSupportDirectory();
    return EncryptedFileChatStore(
      ciphertext: AppSupportCiphertextBackend(
        File('${directory.path}/private-chats.v1.enc'),
      ),
      keys: SecureStorageChatKeyBackend(
        secureStorage ?? const FlutterSecureStorage(),
      ),
    );
  }

  @override
  Future<List<StoredChat>> load() => _serialized(() async {
    final encrypted = await _ciphertext.read();
    if (encrypted == null) return const <StoredChat>[];
    final keyBytes = await _keys.read();
    if (keyBytes == null) {
      throw const ChatStoreException(
        ChatStoreFailure.keyUnavailable,
        'Saved chats exist, but their device key is unavailable.',
      );
    }
    try {
      final envelope = jsonDecode(utf8.decode(encrypted));
      if (envelope is! Map<String, dynamic> || envelope['version'] != 1) {
        throw const FormatException('Unsupported envelope');
      }
      final box = SecretBox(
        base64Decode(_string(envelope, 'ciphertext')),
        nonce: base64Decode(_string(envelope, 'nonce')),
        mac: Mac(base64Decode(_string(envelope, 'mac'))),
      );
      final cleartext = await _cipher.decrypt(
        box,
        secretKey: SecretKey(keyBytes),
      );
      return _decodePayload(jsonDecode(utf8.decode(cleartext)));
    } on ChatStoreException {
      rethrow;
    } catch (error) {
      throw ChatStoreException(
        ChatStoreFailure.corrupt,
        'Saved chats are corrupt or cannot be decrypted.',
        error,
      );
    }
  });

  @override
  Future<void> save(List<StoredChat> chats) => _serialized(() async {
    final existing = await _ciphertext.read();
    var keyBytes = await _keys.read();
    if (keyBytes == null) {
      if (existing != null) {
        throw const ChatStoreException(
          ChatStoreFailure.keyUnavailable,
          'Saved chats exist, but their device key is unavailable.',
        );
      }
      keyBytes = Uint8List.fromList(
        await (await _cipher.newSecretKey()).extractBytes(),
      );
      await _keys.write(keyBytes);
    }
    if (existing != null) {
      await _authenticateExisting(existing, keyBytes);
    }
    try {
      final payload = utf8.encode(jsonEncode(_encodePayload(chats)));
      final box = await _cipher.encrypt(
        payload,
        secretKey: SecretKey(keyBytes),
        nonce: _cipher.newNonce(),
      );
      final envelope = utf8.encode(
        jsonEncode(<String, Object>{
          'version': 1,
          'nonce': base64Encode(box.nonce),
          'ciphertext': base64Encode(box.cipherText),
          'mac': base64Encode(box.mac.bytes),
        }),
      );
      await _ciphertext.writeAtomic(Uint8List.fromList(envelope));
    } on ChatStoreException {
      rethrow;
    } catch (error) {
      throw ChatStoreException(
        ChatStoreFailure.io,
        'Saved chats could not be encrypted.',
        error,
      );
    }
  });

  Future<void> _authenticateExisting(
    Uint8List encrypted,
    Uint8List keyBytes,
  ) async {
    try {
      final envelope = jsonDecode(utf8.decode(encrypted));
      if (envelope is! Map<String, dynamic> || envelope['version'] != 1) {
        throw const FormatException('Unsupported envelope');
      }
      final box = SecretBox(
        base64Decode(_string(envelope, 'ciphertext')),
        nonce: base64Decode(_string(envelope, 'nonce')),
        mac: Mac(base64Decode(_string(envelope, 'mac'))),
      );
      final cleartext = await _cipher.decrypt(
        box,
        secretKey: SecretKey(keyBytes),
      );
      _decodePayload(jsonDecode(utf8.decode(cleartext)));
    } catch (error) {
      throw ChatStoreException(
        ChatStoreFailure.corrupt,
        'Saved chats are corrupt or cannot be decrypted.',
        error,
      );
    }
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  static Map<String, Object> _encodePayload(List<StoredChat> chats) {
    if (chats.length > maxChats) {
      throw const ChatStoreException(
        ChatStoreFailure.capacity,
        'Up to 100 chats can be saved on this device.',
      );
    }
    return <String, Object>{
      'version': 1,
      'chats': chats.map((chat) {
        final messages = chat.snapshot.messages.length <= maxMessagesPerChat
            ? chat.snapshot.messages
            : chat.snapshot.messages.sublist(
                chat.snapshot.messages.length - maxMessagesPerChat,
              );
        if (chat.voiceTurns.length > maxVoiceTurnsPerChat) {
          throw const ChatStoreException(
            ChatStoreFailure.capacity,
            'Voice dialogue exceeds protected local storage capacity.',
          );
        }
        return <String, Object?>{
          'id': chat.id,
          'createdAt': chat.createdAt?.toUtc().toIso8601String(),
          'localLabel': chat.localLabel,
          'link': chat.link,
          'draft': chat.draft,
          'label': chat.label,
          'voiceTurns': chat.voiceTurns.map((turn) => turn.toJson()).toList(),
          'reconnect': chat.reconnect,
          'snapshot': <String, Object?>{
            'title': chat.snapshot.title,
            'sessionStartedAt': chat.snapshot.sessionStartedAt
                ?.toUtc()
                .toIso8601String(),
            'endpoint': chat.snapshot.endpoint,
            'model': chat.snapshot.model,
            'readOnly': chat.snapshot.readOnly,
            'messages': messages.map(_encodeMessage).toList(),
            'rawEntries': _boundedEntries(chat.snapshot.rawEntries),
          },
        };
      }).toList(),
    };
  }

  static List<StoredChat> _decodePayload(Object? value) {
    if (value is! Map<String, dynamic> || value['version'] != 1) {
      throw const FormatException('Unsupported payload');
    }
    final rawChats = value['chats'];
    if (rawChats is! List || rawChats.length > maxChats) {
      throw const FormatException('Invalid chats');
    }
    return rawChats
        .map((raw) {
          final chat = _map(raw);
          final snapshot = _map(chat['snapshot']);
          final rawMessages = snapshot['messages'];
          if (rawMessages is! List || rawMessages.length > maxMessagesPerChat) {
            throw const FormatException('Invalid messages');
          }
          final rawEntries = snapshot['rawEntries'] ?? const [];
          if (rawEntries is! List || rawEntries.length > maxMessagesPerChat) {
            throw const FormatException('Invalid cached source entries');
          }
          final rawVoiceTurns = chat['voiceTurns'] ?? const [];
          if (rawVoiceTurns is! List ||
              rawVoiceTurns.length > maxVoiceTurnsPerChat) {
            throw const FormatException('Invalid voice dialogue');
          }
          return StoredChat(
            id: _string(chat, 'id'),
            createdAt: _optionalDate(chat, 'createdAt'),
            localLabel: chat['localLabel'] == null
                ? null
                : _bool(chat, 'localLabel'),
            link: _string(chat, 'link'),
            label: _string(chat, 'label'),
            draft: _string(chat, 'draft'),
            reconnect: _bool(chat, 'reconnect'),
            snapshot: StoredSnapshot(
              title: _string(snapshot, 'title'),
              sessionStartedAt: _optionalDate(snapshot, 'sessionStartedAt'),
              endpoint: _string(snapshot, 'endpoint'),
              model: _string(snapshot, 'model'),
              readOnly: _bool(snapshot, 'readOnly'),
              messages: rawMessages.map(_decodeMessage).toList(growable: false),
              rawEntries: rawEntries
                  .map((entry) => _map(entry).cast<String, Object?>())
                  .toList(growable: false),
            ),
            voiceTurns: rawVoiceTurns
                .map((turn) => VoiceTurn.fromJson(_map(turn)))
                .toList(growable: false),
          );
        })
        .toList(growable: false);
  }

  static List<Map<String, Object?>> _boundedEntries(
    List<Map<String, Object?>> entries,
  ) {
    final selected = <Map<String, Object?>>[];
    var bytes = 0;
    for (final entry in entries.reversed) {
      final size = utf8.encode(jsonEncode(entry)).length;
      // Never bridge an omitted entry: it might be the context boundary.
      if (size > maxCachedSourceBytes) break;
      if (bytes + size > maxCachedSourceBytes ||
          selected.length >= maxMessagesPerChat) {
        break;
      }
      selected.add(entry);
      bytes += size;
    }
    return selected.reversed.toList(growable: false);
  }

  static Map<String, Object?> _encodeMessage(ChatMessage message) =>
      <String, Object?>{
        'id': message.id,
        'role': message.role.name,
        'text': _bounded(message.text, maxMessageCharacters),
        'author': message.author,
        'timestamp': message.timestamp?.toUtc().toIso8601String(),
        'thinking': _bounded(message.thinking, maxMessageCharacters),
        'isError': message.isError,
        'source': _boundedSource(message.source),
        'prose': message.prose == null
            ? null
            : _bounded(message.prose!, maxMessageCharacters),
        'origin': message.origin?.name,
      };

  static Map<String, Object?>? _boundedSource(Map<String, Object?>? source) {
    if (source == null) return null;
    return utf8.encode(jsonEncode(source)).length <= maxMessageCharacters
        ? source
        : null;
  }

  static ChatMessage _decodeMessage(Object? value) {
    final map = _map(value);
    final roleName = _string(map, 'role');
    final role = MessageRole.values
        .where((item) => item.name == roleName)
        .first;
    final timestamp = map['timestamp'];
    return ChatMessage(
      id: _string(map, 'id'),
      role: role,
      text: _bounded(_string(map, 'text'), maxMessageCharacters),
      author: map['author'] as String?,
      timestamp: timestamp == null ? null : DateTime.parse(timestamp as String),
      thinking: _bounded(_string(map, 'thinking'), maxMessageCharacters),
      isError: _bool(map, 'isError'),
      source: map['source'] == null ? null : _map(map['source']),
      prose: map['prose'] as String?,
      origin: map['origin'] == null
          ? null
          : ChatMessageOrigin.values.byName(map['origin'] as String),
    );
  }

  static Map<String, dynamic> _map(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Expected object');
    }
    return value;
  }

  static String _string(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! String) throw FormatException('Expected string: $key');
    return value;
  }

  static bool _bool(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! bool) throw FormatException('Expected bool: $key');
    return value;
  }

  static DateTime? _optionalDate(Map<String, dynamic> map, String key) {
    final value = map[key];
    return value == null ? null : DateTime.parse(_string(map, key));
  }

  static String _bounded(String value, int length) =>
      value.length <= length ? value : value.substring(0, length);
}
