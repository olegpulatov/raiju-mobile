import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../harness/collab_link.dart';
import '../shared/theme/theme_provider.dart';

const collabRelayPreferenceKey = 'raiju.collab.default-relay.v1';

/// Used only when a user manually enters a bare room/key code.
final collabRelayProvider = NotifierProvider<CollabRelayNotifier, String>(
  CollabRelayNotifier.new,
);

class CollabRelayNotifier extends Notifier<String> {
  @override
  String build() {
    final stored = ref
        .read(savedPrefsProvider)
        .getString(collabRelayPreferenceKey);
    if (stored == null) return defaultCollabRelay;
    try {
      return validateCollabRelay(stored);
    } on CollabLinkException {
      return defaultCollabRelay;
    }
  }

  Future<void> setRelay(String input) async {
    final relay = validateCollabRelay(input);
    if (!await ref
        .read(savedPrefsProvider)
        .setString(collabRelayPreferenceKey, relay)) {
      throw StateError('Could not save the default collaboration relay.');
    }
    state = relay;
  }
}
