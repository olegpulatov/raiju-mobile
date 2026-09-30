// MODIFIED FOR RAIJU: legacy Buzz credential storage is sealed. Existing
// values are neither read nor migrated; new values cannot be persisted.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'community.dart';
import '../relay/backend_disabled.dart';

class CommunityStorage {


  CommunityStorage({FlutterSecureStorage? secure});

  /// Buzz credentials are intentionally ignored by Raiju.
  Future<List<Community>> loadAll() async => const [];

  Future<void> save(Community community) =>
      Future.error(buzzBackendUnavailable);

  /// Legacy bulk writes are unavailable in Raiju.
  Future<void> saveAll(List<Community> communities) =>
      Future.error(buzzBackendUnavailable);

  Future<void> remove(String id) => Future.error(buzzBackendUnavailable);

  Future<String?> loadActiveId() async => null;

  Future<void> saveActiveId(String id) =>
      Future.error(buzzBackendUnavailable);

  Future<void> clearActiveId() => Future.error(buzzBackendUnavailable);

}
