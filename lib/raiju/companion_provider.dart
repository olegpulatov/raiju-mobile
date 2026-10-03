import 'dart:async';

import 'package:hooks_riverpod/legacy.dart';

import '../companion_controller.dart';
import '../harness/collab_link.dart';
import '../harness/harness.dart';
import '../harness/omp_collab_client.dart';
import '../harness/ompd_client.dart';
import '../harness/ompd_connection.dart';
import '../storage/chat_store.dart';
import '../storage/encrypted_file_chat_store.dart';
import 'collab_relay_preference.dart';

/// Only a currently visible chat can start a new Spark voice session.
/// The active Spark session keeps its own bound chat when this selection changes.
final viewedCompanionChatProvider = StateProvider<String?>((ref) => null);

/// Original Buzz widgets consume this local state instead of a Buzz account.
final companionControllerProvider = ChangeNotifierProvider<CompanionController>(
  (ref) {
    final controller = CompanionController(
      clientFactory: () => OmpCollabClient.withOptions(
        OmpCollabClientOptions(defaultRelay: ref.read(collabRelayProvider)),
      ),
      connectionClientFactory: (input) => OmpdConnection.isOmpd(input)
          ? OmpdClient()
          : OmpCollabClient.withOptions(
              OmpCollabClientOptions(
                defaultRelay: ref.read(collabRelayProvider),
              ),
            ),
      joinInputResolver: (input) {
        if (OmpdConnection.isOmpd(input)) {
          return OmpdConnection.parse(input).encode();
        }
        try {
          return pinBareCollabLink(
            input,
            defaultRelay: ref.read(collabRelayProvider),
          );
        } on CollabLinkException catch (error) {
          throw HarnessException(error.message);
        }
      },
      store: _DeferredProductionStore(),
    );
    unawaited(controller.initialize());
    return controller;
  },
);

/// Plugin/storage initialization must not block the no-login first screen.
class _DeferredProductionStore implements ChatStore {
  Future<EncryptedFileChatStore>? _store;
  Future<EncryptedFileChatStore> get _ready =>
      _store ??= EncryptedFileChatStore.production();

  @override
  Future<List<StoredChat>> load() async => (await _ready).load();

  @override
  Future<void> save(List<StoredChat> chats) async => (await _ready).save(chats);
}
