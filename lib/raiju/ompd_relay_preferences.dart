import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../shared/theme/theme_provider.dart';

const ompdRelayPreferencesKey = 'raiju.ompd.relay-preferences.v1';

class OmpdRelayPreferences {
  const OmpdRelayPreferences({this.endpoint, this.profile = ''});

  final String? endpoint;
  final String profile;
}

/// Relay form values belong to the app, not to a successfully attached chat.
final ompdRelayPreferencesProvider =
    NotifierProvider<OmpdRelayPreferencesNotifier, OmpdRelayPreferences>(
      OmpdRelayPreferencesNotifier.new,
    );

class OmpdRelayPreferencesNotifier extends Notifier<OmpdRelayPreferences> {
  Future<void> _pending = Future.value();

  @override
  OmpdRelayPreferences build() {
    final stored = ref
        .read(savedPrefsProvider)
        .getStringList(ompdRelayPreferencesKey);
    if (stored == null || stored.length != 2) {
      return const OmpdRelayPreferences();
    }
    return OmpdRelayPreferences(endpoint: stored[0], profile: stored[1]);
  }

  /// Preserve edits immediately, including an unfinished endpoint or profile.
  /// Serialize writes so a late earlier write cannot overwrite newer typing.
  Future<void> setDraft({String? endpoint, String? profile}) {
    final next = OmpdRelayPreferences(
      endpoint: endpoint ?? state.endpoint,
      profile: profile ?? state.profile,
    );
    state = next;
    final prefs = ref.read(savedPrefsProvider);
    final values = [next.endpoint ?? '', next.profile];
    final write = _pending.then((_) async {
      if (!await prefs.setStringList(ompdRelayPreferencesKey, values)) {
        throw StateError('Could not save relay settings.');
      }
    });
    // A failed write must not prevent later edits or an explicit Save retry.
    _pending = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }
}
