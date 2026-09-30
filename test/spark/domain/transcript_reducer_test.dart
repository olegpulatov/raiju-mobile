import 'package:raiju_mobile/spark/spark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'partial is replaced by authoritative final and final ignores duplicates',
    () {
      final reducer = SparkTranscriptReducer();
      var entries = <SparkTranscriptEntry>[];
      entries = reducer.reduce(entries, {
        'type': 'transcript',
        'id': 'a',
        'role': 'assistant',
        'text': 'hel',
        'final': false,
      });
      entries = reducer.reduce(entries, {
        'type': 'transcript',
        'id': 'a',
        'role': 'assistant',
        'text': 'hello',
        'final': true,
      });
      entries = reducer.reduce(entries, {
        'type': 'transcript',
        'id': 'a',
        'role': 'assistant',
        'text': 'duplicate',
        'final': true,
      });
      expect(entries, hasLength(1));
      expect(entries.single.text, 'hello');
      expect(entries.single.isFinal, isTrue);
    },
  );
  test('id-less partial and empty final coalesce one turn', () {
    final reducer = SparkTranscriptReducer();
    var entries = <SparkTranscriptEntry>[];
    entries = reducer.reduce(entries, {
      'type': 'transcript',
      'role': 'user',
      'text': 'hello',
      'final': false,
    });
    entries = reducer.reduce(entries, {
      'type': 'transcript',
      'role': 'user',
      'text': '',
      'final': true,
    });
    expect(entries, hasLength(1));
    expect(entries.single.text, 'hello');
    expect(entries.single.isFinal, isTrue);
  });

  test('mixed delta and turn ids accumulate then finalize one entry', () {
    final reducer = SparkTranscriptReducer();
    var entries = <SparkTranscriptEntry>[];
    entries = reducer.reduce(entries, {
      'type': 'transcript',
      'id': 'output-1',
      'role': 'assistant',
      'text': 'on it',
      'final': false,
    });
    entries = reducer.reduce(entries, {
      'type': 'transcript',
      'id': 'output-1',
      'role': 'assistant',
      'text': ', checking the auth module',
      'final': false,
    });
    entries = reducer.reduce(entries, {
      'type': 'transcript',
      'id': 'turn-2',
      'role': 'assistant',
      'text': 'On it, checking the auth module.',
      'final': true,
    });
    expect(entries, hasLength(1));
    expect(entries.single.text, 'On it, checking the auth module.');
    expect(entries.single.isFinal, isTrue);
  });

  test('empty final with distinct turn id finalizes accumulated delta', () {
    final reducer = SparkTranscriptReducer();
    var entries = <SparkTranscriptEntry>[];
    entries = reducer.reduce(entries, {
      'type': 'transcript',
      'id': 'item-1',
      'role': 'user',
      'text': 'spoken words',
      'final': false,
    });
    entries = reducer.reduce(entries, {
      'type': 'transcript',
      'id': 'turn-9',
      'role': 'user',
      'text': '',
      'final': true,
    });
    expect(entries, hasLength(1));
    expect(entries.single.text, 'spoken words');
    expect(entries.single.isFinal, isTrue);
  });

  test(
    'duplicate final alias is ignored and typed append preserves voice turn',
    () {
      final reducer = SparkTranscriptReducer();
      var entries = <SparkTranscriptEntry>[];
      entries = reducer.reduce(entries, {
        'type': 'transcript',
        'id': 'item-1',
        'role': 'user',
        'text': 'voice ',
        'final': false,
      });
      entries = reducer.appendFinal(
        entries,
        id: 'typed-1',
        role: SparkTranscriptRole.user,
        text: 'typed',
      );
      entries = reducer.reduce(entries, {
        'type': 'transcript',
        'id': 'turn-1',
        'role': 'user',
        'text': 'voice final',
        'final': true,
      });
      entries = reducer.reduce(entries, {
        'type': 'transcript',
        'id': 'turn-1',
        'role': 'user',
        'text': 'voice final',
        'final': true,
      });
      expect(entries, hasLength(2));
      expect(
        entries.where((entry) => entry.text == 'voice final'),
        hasLength(1),
      );
      expect(entries.where((entry) => entry.text == 'typed'), hasLength(1));
    },
  );

  test('retains every finalized turn regardless of display bounds', () {
    final reducer = SparkTranscriptReducer(maxEntries: 2);
    var entries = <SparkTranscriptEntry>[];
    for (var i = 0; i < 3; i++) {
      entries = reducer.reduce(entries, {
        'type': 'transcript',
        'id': '$i',
        'role': 'user',
        'text': '$i',
        'final': true,
      });
    }
    expect(entries.map((e) => e.id), ['0', '1', '2']);
  });

  test(
    'full finalized history cannot evict an active empty-final fallback',
    () {
      final reducer = SparkTranscriptReducer(maxEntries: 2, maxCharacters: 4);
      var entries = <SparkTranscriptEntry>[];
      for (final id in ['first', 'second']) {
        entries = reducer.reduce(entries, {
          'type': 'transcript',
          'id': id,
          'role': 'assistant',
          'text': id,
          'final': true,
        });
      }
      entries = reducer.reduce(entries, {
        'type': 'transcript',
        'id': 'delta-3',
        'role': 'user',
        'text': 'long recognized phrase',
        'final': false,
      });
      expect(entries, hasLength(3));
      expect(
        entries.last.text,
        hasLength(4),
      ); // Only provisional UI is bounded.
      entries = reducer.reduce(entries, {
        'type': 'transcript',
        'id': 'final-3',
        'role': 'user',
        'text': '',
        'final': true,
      });
      expect(entries.map((entry) => entry.id), ['first', 'second', 'delta-3']);
      expect(entries.last.text, 'long recognized phrase');
      expect(entries.last.isFinal, isTrue);
    },
  );
  test('user partial gate remains active until differently-IDed final', () {
    final reducer = SparkTranscriptReducer();
    var entries = <SparkTranscriptEntry>[];
    expect(reducer.hasActiveUserTurn, isFalse);
    entries = reducer.reduce(entries, {
      'type': 'transcript',
      'role': 'user',
      'id': 'partial',
      'text': 'Check ',
      'final': false,
    });
    expect(reducer.hasActiveUserTurn, isTrue);
    entries = reducer.reduce(entries, {
      'type': 'transcript',
      'role': 'assistant',
      'id': 'ack',
      'text': 'Working',
      'final': true,
    });
    expect(reducer.hasActiveUserTurn, isTrue);
    entries = reducer.reduce(entries, {
      'type': 'transcript',
      'role': 'user',
      'id': 'final-alias',
      'text': 'Check now',
      'final': true,
    });
    expect(reducer.hasActiveUserTurn, isFalse);
    expect(
      entries.where((item) => item.role == SparkTranscriptRole.user).single.id,
      'partial',
    );
    reducer.resetSession();
    expect(reducer.hasActiveUserTurn, isFalse);
  });
}
