import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'models.dart';

class SparkStoreException implements Exception {
  const SparkStoreException(this.message);
  final String message;
  @override
  String toString() => message;
}

class StoredSparkSettings {
  const StoredSparkSettings({
    required this.settings,
    required this.hasBrokerToken,
  });
  final SparkSettings settings;
  final bool hasBrokerToken;
}

abstract interface class SparkSettingsStore {
  Future<StoredSparkSettings> load();
  Future<void> save(SparkSettings settings, {String? brokerToken});
  Future<String?> readBrokerToken();
}

abstract interface class SparkProtectedStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSparkProtectedStorage implements SparkProtectedStorage {
  FlutterSparkProtectedStorage([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// One protected record makes broker URL/token updates atomic at this boundary.
/// No transcript, provider snapshot, access token, SDP, or audio is written.
class SecureSparkSettingsStore implements SparkSettingsStore {
  SecureSparkSettingsStore({SparkProtectedStorage? storage})
    : _storage = storage ?? FlutterSparkProtectedStorage();
  final SparkProtectedStorage _storage;
  static const _recordKey = 'raiju.spark.protected.v1';
  bool _corrupt = false;
  Future<void> _operations = Future<void>.value();

  @override
  Future<StoredSparkSettings> load() => _serialized(() async {
    try {
      final record = await _readRecord();
      if (record == null) {
        return const StoredSparkSettings(
          settings: SparkSettings(),
          hasBrokerToken: false,
        );
      }
      final settings = SparkSettings.fromJson(
        (record['settings'] as Map).cast<String, Object?>(),
      );
      final token = record['brokerToken'];
      validateSparkSettings(settings);
      return StoredSparkSettings(
        settings: settings,
        hasBrokerToken: token is String && token.isNotEmpty,
      );
    } catch (_) {
      _corrupt = true;
      throw const SparkStoreException(
        'Spark settings are unavailable or corrupt. Existing data was not reset.',
      );
    }
  });

  @override
  Future<void> save(SparkSettings settings, {String? brokerToken}) =>
      _serialized(() async {
        if (_corrupt) {
          throw const SparkStoreException(
            'Spark settings are corrupt. Existing data was not reset.',
          );
        }
        try {
          validateSparkSettings(settings);
        } catch (_) {
          throw const SparkStoreException(
            'Spark settings are invalid and were not saved.',
          );
        }
        Map<String, Object?>? current;
        try {
          current = await _readRecord();
        } catch (_) {
          _corrupt = true;
          throw const SparkStoreException(
            'Spark settings are corrupt. Existing data was not reset.',
          );
        }
        final existingToken = current?['brokerToken'];
        final token = brokerToken == null
            ? existingToken
            : (brokerToken.trim().isEmpty ? null : brokerToken.trim());
        try {
          await _storage.write(
            _recordKey,
            jsonEncode({
              'version': 1,
              'settings': settings.toJson(),
              if (token is String) 'brokerToken': token,
            }),
          );
        } catch (_) {
          throw const SparkStoreException(
            'Spark settings could not be saved. Existing data was not reset.',
          );
        }
      });

  @override
  Future<String?> readBrokerToken() => _serialized(() async {
    if (_corrupt) {
      throw const SparkStoreException('The Spark broker token is unavailable.');
    }
    try {
      final token = (await _readRecord())?['brokerToken'];
      return token is String && token.isNotEmpty ? token : null;
    } catch (_) {
      _corrupt = true;
      throw const SparkStoreException('The Spark broker token is unavailable.');
    }
  });

  Future<Map<String, Object?>?> _readRecord() async {
    final encoded = await _storage.read(_recordKey);
    if (encoded == null) return null;
    final decoded = jsonDecode(encoded);
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['settings'] is! Map) {
      throw const FormatException('Invalid protected Spark record');
    }
    final record = decoded.cast<String, Object?>();
    final token = record['brokerToken'];
    if (token != null && token is! String) {
      throw const FormatException('Invalid protected Spark token');
    }
    validateSparkSettings(
      SparkSettings.fromJson(
        (record['settings'] as Map).cast<String, Object?>(),
      ),
    );
    return record;
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _operations.then((_) => action());
    _operations = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}
