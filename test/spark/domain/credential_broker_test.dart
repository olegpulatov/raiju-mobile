import 'dart:async';
import 'dart:convert';

import 'package:raiju_mobile/spark/spark.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const settings = SparkSettings(brokerUrl: 'https://broker.example/');
  test('sanitizes broker authentication failure', () async {
    final source = OmpBrokerCredentialSource(
      client: MockClient(
        (_) async => http.Response('private provider body', 401),
      ),
    );
    await expectLater(
      source.acquire(settings, 'synthetic-broker-token'),
      throwsA(
        isA<SparkBrokerException>().having(
          (e) => e.message,
          'message',
          'Broker authentication failed. Check the saved broker token.',
        ),
      ),
    );
  });

  test('asks broker to refresh a near-expiry OAuth credential', () async {
    var refreshes = 0;
    final source = OmpBrokerCredentialSource(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/refresh')) {
          refreshes++;
          return http.Response(
            jsonEncode({'entry': _entry(expires: 900000)}),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'generation': 1,
            'generatedAt': 1,
            'serverNowMs': 1000,
            'refresher': {
              'enabled': true,
              'intervalMs': 60000,
              'skewMs': 300000,
              'nextSweepInMs': 1,
            },
            'credentials': [_entry(expires: 2000)],
          }),
          200,
        );
      }),
    );
    final result = await source.acquire(settings, 'synthetic-broker-token');
    expect(refreshes, 1);
    expect(result.credential?.id, '7');
  });

  test('requires selection when several accounts are eligible', () async {
    final source = OmpBrokerCredentialSource(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'generation': 1,
            'generatedAt': 1,
            'serverNowMs': 1000,
            'refresher': {
              'enabled': true,
              'intervalMs': 1,
              'skewMs': 1,
              'nextSweepInMs': 1,
            },
            'credentials': [_entry(id: 7), _entry(id: 8)],
          }),
          200,
        ),
      ),
    );
    final result = await source.acquire(settings, 'synthetic-broker-token');
    expect(result.credential, isNull);
    expect(result.choices, hasLength(2));
  });

  test(
    'stale saved selection returns replacement choices without choosing',
    () async {
      final source = OmpBrokerCredentialSource(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'generation': 1,
              'generatedAt': 1,
              'serverNowMs': 1000,
              'refresher': {
                'enabled': true,
                'intervalMs': 1,
                'skewMs': 1,
                'nextSweepInMs': 1,
              },
              'credentials': [_entry(id: 8)],
            }),
            200,
          ),
        ),
      );
      final result = await source.acquire(
        settings.copyWith(selectedCredentialId: 'retired'),
        'synthetic-broker-token',
      );
      expect(result.credential, isNull);
      expect(result.choices.single.id, '8');
    },
  );

  test('cancellation closes an in-flight broker request', () async {
    final client = _PendingClient();
    final source = OmpBrokerCredentialSource(client: client);
    final cancellation = SparkCancellation();
    final future = source.acquireCancellable(
      settings,
      'synthetic-broker-token',
      cancellation,
    );
    cancellation.cancel();
    await expectLater(future, throwsA(isA<SparkBrokerException>()));
    expect(client.closed, isTrue);
  });
}

Map<String, Object?> _entry({int id = 7, int expires = 900000}) => {
  'id': id,
  'provider': 'openai-codex',
  'identityKey': 'synthetic:$id',
  'rotatesInMs': null,
  'credential': {
    'type': 'oauth',
    'refresh': '<remote>',
    'access': 'synthetic-access-$id',
    'expires': expires,
    'accountId': 'acct-$id',
  },
};

class _PendingClient extends http.BaseClient {
  final Completer<http.StreamedResponse> _response =
      Completer<http.StreamedResponse>();
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _response.future;
  @override
  void close() {
    closed = true;
    if (!_response.isCompleted) _response.completeError(StateError('closed'));
  }
}
