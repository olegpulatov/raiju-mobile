import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/legacy.dart';
import '../raiju/companion_provider.dart';

import 'chat_bridge.dart';
import 'companion_chat_bridge.dart';
import 'controller.dart';
import 'credential_broker.dart';
import 'settings_store.dart';
import 'voice_session.dart';

final sparkVoiceSessionProvider = Provider<VoiceSession>((ref) {
  final session = MethodChannelVoiceSession();
  ref.onDispose(session.dispose);
  return session;
});
final sparkCredentialSourceProvider = Provider<SparkCredentialSource>(
  (ref) => OmpBrokerCredentialSource(),
);
final sparkSettingsStoreProvider = Provider<SparkSettingsStore>(
  (ref) => SecureSparkSettingsStore(),
);
final sparkChatBridgeProvider = Provider<SparkChatBridge>(
  (ref) => CompanionSparkChatBridge(ref.read(companionControllerProvider)),
);
final sparkControllerProvider = ChangeNotifierProvider<SparkController>((ref) {
  final controller = SparkController(
    session: ref.watch(sparkVoiceSessionProvider),
    credentials: ref.watch(sparkCredentialSourceProvider),
    store: ref.watch(sparkSettingsStoreProvider),
    chatBridge: ref.watch(sparkChatBridgeProvider),
  );
  controller.initialize();
  return controller;
});
