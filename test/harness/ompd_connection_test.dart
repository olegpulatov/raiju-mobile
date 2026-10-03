import 'package:flutter_test/flutter_test.dart';
import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/harness/ompd_connection.dart';

void main() {
  test('raw TCP endpoint accepts DNS IPv4 IPv6 and default port', () {
    expect(
      OmpdEndpoint.parse('Relay.Example').toString(),
      'relay.example:7420',
    );
    expect(OmpdEndpoint.parse('127.0.0.1:8123').port, 8123);
    expect(OmpdEndpoint.parse('[::1]:8123').host, '::1');
    expect(OmpdEndpoint.parse('::1').toString(), '[::1]:7420');
    expect(OmpdEndpoint.parse('tcp://[::1]:8123').toString(), '[::1]:8123');
  });

  test('endpoint rejects credentials other transports and injected fields', () {
    for (final text in [
      '',
      'https://relay.example',
      'tcp://user:secret@relay.example',
      'relay:0',
      'relay:65536',
      'relay/path',
      'tcp://relay?secret=x',
      'tcp://relay/#fragment',
      'relay\nother',
      '[not-ip]:12',
      '-relay',
      'relay..example',
    ]) {
      expect(
        () => OmpdEndpoint.parse(text),
        throwsA(isA<HarnessException>()),
        reason: text,
      );
    }
  });

  test(
    'saved relay connections preserve bound identity and explicit consent',
    () {
      final connection = OmpdConnection(
        endpoint: OmpdEndpoint.parse('[::1]:9000'),
        instance: 'phone',
        sessionId: 'fixture/session?',
        sessionFile: '/synthetic/private session.jsonl',
        trustedNetwork: true,
      );
      final decoded = OmpdConnection.parse(connection.encode());
      expect(decoded.endpoint.toString(), '[::1]:9000');
      expect(decoded.instance, 'phone');
      expect(decoded.sessionId, connection.sessionId);
      expect(decoded.sessionFile, connection.sessionFile);
      expect(decoded.trustedNetwork, isTrue);
      expect(connection.toString(), isNot(contains(connection.sessionId!)));
      expect(connection.toString(), isNot(contains(connection.sessionFile!)));
      expect(OmpdConnection.isOmpd(connection.encode()), isTrue);
      final untrusted = OmpdConnection(
        endpoint: decoded.endpoint,
        instance: 'phone',
        trustedNetwork: false,
      );
      expect(OmpdConnection.parse(untrusted.encode()).trustedNetwork, isFalse);
    },
  );

  test('connection errors never echo invalid input', () {
    for (final text in [
      'ompd://secret@relay/phone?trusted=1',
      'ompd://relay/phone?trusted=1&trusted=0',
      'ompd://relay/phone?trusted=1&token=secret',
      'ompd://relay/../?trusted=1',
      'ompd://relay/phone',
      'ompd://relay/phone?trusted=yes',
    ]) {
      try {
        OmpdConnection.parse(text);
        fail('accepted invalid connection');
      } on HarnessException catch (error) {
        expect(error.message, isNot(contains('secret')));
      }
    }
  });
}
