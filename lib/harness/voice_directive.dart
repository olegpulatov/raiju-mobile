/// Mobile presentation marker; the actual collab prompt remains visible on host.
/// Never create a separate activation prompt.
abstract final class VoiceDirective {
  static const start = '<!-- raiju:spark:two-model:start -->';
  static const end = '<!-- raiju:spark:two-model:end -->';
  static final RegExp _addition = RegExp(
    '${RegExp.escape(start)}[\\s\\S]*?${RegExp.escape(end)}',
  );

  static String decorate(String prompt, String directive) =>
      '$prompt\n\n$start\n$directive\n$end';

  static String strip(String text) => text.replaceAll(_addition, '').trim();

  /// Actual compaction entries delimit context. Activity notices do not.
  static bool isPresent(List<Map<String, Object?>> entries) {
    var boundary = 0;
    for (var i = 0; i < entries.length; i++) {
      if (entries[i]['type'] == 'compaction') boundary = i + 1;
    }
    for (final entry in entries.skip(boundary)) {
      final message = entry['message'];
      final content =
          entry['type'] == 'custom_message' &&
              entry['customType'] == 'collab-prompt'
          ? entry['content']
          : entry['type'] == 'message' &&
                message is Map &&
                message['role'] == 'user'
          ? message['content']
          : null;
      if (_containsMarker(content)) {
        return true;
      }
    }
    return false;
  }

  static bool _containsMarker(Object? value) {
    if (value is String) return _addition.hasMatch(value);
    if (value is List) {
      return value.any(
        (block) =>
            block is Map &&
            block['type'] == 'text' &&
            _containsMarker(block['text']),
      );
    }
    return false;
  }
}
