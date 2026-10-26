import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../shared/theme/theme_provider.dart';

/// Local presentation only; author names remain visible when avatars are hidden.
class ChatAvatarsNotifier extends Notifier<bool> {
  static const preferenceKey = 'raiju_show_chat_avatars';

  @override
  bool build() => ref.read(savedPrefsProvider).getBool(preferenceKey) ?? false;

  Future<void> setVisible(bool visible) async {
    state = visible;
    await ref.read(savedPrefsProvider).setBool(preferenceKey, visible);
  }
}

final showChatAvatarsProvider = NotifierProvider<ChatAvatarsNotifier, bool>(
  ChatAvatarsNotifier.new,
);
