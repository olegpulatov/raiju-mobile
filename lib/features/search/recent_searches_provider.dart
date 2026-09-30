// MODIFIED FOR RAIJU: recent search text remains memory-only so private OMP
// conversation queries are never copied into plaintext preferences.
import 'dart:async';

import '../../shared/theme/theme_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _maxRecentSearches = 6;

/// Process-local history of explicitly submitted searches, newest first.
class RecentSearchesNotifier extends Notifier<List<String>> {

  @override
  List<String> build() {
    final prefs = ref.read(savedPrefsProvider);
    for (final key in prefs.getKeys()) {
      if (key == 'recent_searches_v1' ||
          key.startsWith('recent_searches_v1:')) {
        unawaited(prefs.remove(key));
      }
    }
    return const [];
  }

  /// Records [query] in memory after trimming whitespace.
  void record(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;

    final normalized = trimmed.toLowerCase();
    final next = [
      trimmed,
      ...state.where((item) => item.toLowerCase() != normalized),
    ].take(_maxRecentSearches).toList(growable: false);
    _persist(next);
  }

  /// Clears the in-memory history.
  void clear() => _persist(const []);

  void _persist(List<String> searches) {
    state = List.unmodifiable(searches);
  }
}

/// Provides memory-only recent searches for the current app process.
final recentSearchesProvider =
    NotifierProvider<RecentSearchesNotifier, List<String>>(
      RecentSearchesNotifier.new,
    );
