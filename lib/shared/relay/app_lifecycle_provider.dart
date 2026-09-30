// MODIFIED FOR RAIJU: app lifecycle state remains available to local UI/media,
// but no connectivity listener or Buzz relay resume/pause bootstrap remains.

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';


/// Tracks the app lifecycle state and drives websocket connect/disconnect
/// behavior for mobile battery efficiency.
class AppLifecycleNotifier extends Notifier<AppLifecycleState> {
  AppLifecycleListener? _listener;

  @override
  AppLifecycleState build() {
    _listener = AppLifecycleListener(onStateChange: _onStateChange);
    ref.onDispose(() => _listener?.dispose());
    return AppLifecycleState.resumed;
  }

  void _onStateChange(AppLifecycleState newState) {
    state = newState;
  }
}

final appLifecycleProvider =
    NotifierProvider<AppLifecycleNotifier, AppLifecycleState>(
      AppLifecycleNotifier.new,
    );
