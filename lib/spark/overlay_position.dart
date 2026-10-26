import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../shared/theme/theme_provider.dart';

const sparkOverlayPositionKey = 'raiju.spark.overlay-position.v1';

class SparkOverlayPosition {
  const SparkOverlayPosition({required this.right, required this.fraction});

  final bool right;
  final double fraction;
}

/// Layout preferences are separate from private voice settings and credentials.
final sparkOverlayPositionProvider =
    NotifierProvider<SparkOverlayPositionNotifier, SparkOverlayPosition?>(
      SparkOverlayPositionNotifier.new,
    );

class SparkOverlayPositionNotifier extends Notifier<SparkOverlayPosition?> {
  Future<void> _pending = Future.value();

  @override
  SparkOverlayPosition? build() {
    final stored = ref
        .read(savedPrefsProvider)
        .getStringList(sparkOverlayPositionKey);
    if (stored == null || stored.length != 2) return null;
    final fraction = double.tryParse(stored[1]);
    if ((stored[0] != 'left' && stored[0] != 'right') ||
        fraction == null ||
        !fraction.isFinite) {
      return null;
    }
    return SparkOverlayPosition(
      right: stored[0] == 'right',
      fraction: fraction.clamp(0.0, 1.0),
    );
  }

  Future<void> save(SparkOverlayPosition position) {
    final next = SparkOverlayPosition(
      right: position.right,
      fraction: position.fraction.clamp(0.0, 1.0),
    );
    state = next;
    final prefs = ref.read(savedPrefsProvider);
    final write = _pending.then((_) async {
      if (!await prefs.setStringList(sparkOverlayPositionKey, [
        next.right ? 'right' : 'left',
        next.fraction.toString(),
      ])) {
        throw StateError('Spark position could not be saved.');
      }
    });
    _pending = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }
}
