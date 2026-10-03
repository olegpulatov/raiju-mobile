import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../spark/spark.dart';
import 'companion_provider.dart';

/// Live collaboration or daemon chats, or a connected Spark voice session.
/// Connecting/reconnecting is not online; read-only live chats still are.
final connectionOnlineProvider = Provider<bool>((ref) {
  final chatOnline = ref.watch(
    companionControllerProvider.select(
      (controller) => controller.hasLiveConnection,
    ),
  );
  final sparkOnline = ref.watch(
    sparkControllerProvider.select(
      (controller) => switch (controller.snapshot.phase) {
        SparkPhase.listening ||
        SparkPhase.working ||
        SparkPhase.speaking ||
        SparkPhase.muted => true,
        SparkPhase.idle || SparkPhase.connecting || SparkPhase.error => false,
      },
    ),
  );
  return chatOnline || sparkOnline;
});
