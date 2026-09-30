import 'models.dart';

/// Reduces provider deltas and authoritative finals without evicting dialogue.
class SparkTranscriptReducer {
  SparkTranscriptReducer({this.maxEntries = 200, this.maxCharacters = 40000});

  /// Legacy display-count hint, retained for caller compatibility. Finalized
  /// turns cannot be evicted; the two active roles cannot safely be evicted.
  final int maxEntries;

  /// Per-active-turn provisional display cap (at most 20,000 characters).
  /// Complete deltas remain in memory until finalization or resetSession.
  final int maxCharacters;
  int _anonymousId = 0;
  final Map<SparkTranscriptRole, String> _activeTurn = {};
  // Full deltas are needed if the provider's final transcript is empty. Only
  // the provisional display entry is shortened; never shorten a final turn.
  final Map<SparkTranscriptRole, String> _activeText = {};
  final Map<String, String> _finalAliases = {};

  /// Provider final IDs can differ from the partial ID; only the active
  /// user role determines whether sealing an intent must wait.
  bool get hasActiveUserTurn =>
      _activeTurn.containsKey(SparkTranscriptRole.user);

  void resetSession() {
    _activeTurn.clear();
    _activeText.clear();
    _finalAliases.clear();
  }

  List<SparkTranscriptEntry> appendFinal(
    List<SparkTranscriptEntry> current, {
    required String id,
    required SparkTranscriptRole role,
    required String text,
  }) {
    if (text.isEmpty ||
        current.any((entry) => entry.id == id && entry.role == role)) {
      return current;
    }
    return immutableList([
      ...current,
      SparkTranscriptEntry(id: id, role: role, text: text, isFinal: true),
    ]);
  }

  List<SparkTranscriptEntry> reduce(
    List<SparkTranscriptEntry> current,
    Map<String, Object?> event,
  ) {
    if (event['type'] != 'transcript') return current;
    final role = switch (event['role']) {
      'user' => SparkTranscriptRole.user,
      'assistant' => SparkTranscriptRole.assistant,
      _ => null,
    };
    final text = event['text'];
    final isFinal = event['final'];
    if (role == null || text is! String || isFinal is! bool) return current;
    final candidate = event['${'i'}d'];
    final providerId = candidate is String && candidate.isNotEmpty
        ? candidate
        : null;
    if (isFinal &&
        providerId != null &&
        _finalAliases.containsKey(providerId)) {
      return current;
    }
    final entries = List<SparkTranscriptEntry>.of(current);

    if (!isFinal) {
      final id =
          _activeTurn[role] ??
          providerId ??
          'local-${role.name}-${_anonymousId++}';
      _activeTurn[role] = id;
      final index = entries.indexWhere(
        (entry) => entry.id == id && entry.role == role && !entry.isFinal,
      );
      if (text.isEmpty) return current;
      final accumulated =
          '${_activeText[role] ?? (index >= 0 ? entries[index].text : '')}$text';
      _activeText[role] = accumulated;
      final partial = SparkTranscriptEntry(
        id: id,
        role: role,
        text: _bounded(accumulated),
        isFinal: false,
      );
      if (index >= 0) {
        entries[index] = partial;
      } else {
        entries.add(partial);
      }
      // Finalized turns are durable conversation state; display bounds cannot
      // evict the live partial needed by an empty authoritative final.
      return immutableList(entries);
    }

    final activeId = _activeTurn.remove(role);
    final accumulated = _activeText.remove(role);
    final id = activeId ?? providerId ?? 'local-${role.name}-${_anonymousId++}';
    if (providerId != null) _finalAliases[providerId] = id;
    final index = entries.indexWhere(
      (entry) => entry.id == id && entry.role == role,
    );
    if (index >= 0 && entries[index].isFinal) return current;
    final authoritative = text;
    final finalText = authoritative.isNotEmpty
        ? authoritative
        : (accumulated ?? (index >= 0 ? entries[index].text : ''));
    if (finalText.isEmpty) return current;
    final finalEntry = SparkTranscriptEntry(
      id: id,
      role: role,
      text: finalText,
      isFinal: true,
    );
    if (index >= 0) {
      entries[index] = finalEntry;
    } else {
      entries.add(finalEntry);
    }
    return immutableList(entries);
  }

  // Bound each provisional display entry independently of finalized history.
  // Complete active text remains available for an empty final.
  String _bounded(String text) {
    final limit = maxCharacters > 0 && maxCharacters < 20000
        ? maxCharacters
        : 20000;
    return text.length > limit ? text.substring(0, limit) : text;
  }
}
