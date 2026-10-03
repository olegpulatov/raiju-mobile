import 'package:flutter_test/flutter_test.dart';
import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/harness/ompd_api.dart';

import 'ompd_fixture.dart';

void main() {
  late OmpdFixture fixture;
  setUp(() async {
    fixture = OmpdFixture();
    await fixture.open();
  });
  tearDown(() => fixture.close());

  test(
    'status decodes exact daemon nested session fields with split lines',
    () async {
      fixture.split = true;
      final rows = await const OmpdApi().status(fixture.endpoint);
      expect(rows.single.name, 'phone');
      expect(rows.single.sessionId, 'fixture-session');
      expect(rows.single.sessionName, 'Fixture chat');
      expect(rows.single.sessionFile, '/synthetic/session.jsonl');
      expect(rows.single.generation, 1);
      expect(rows.single.ready && rows.single.rpc, isTrue);
    },
  );

  test(
    'start forwards only explicit remote profile cwd and resume reference',
    () async {
      const api = OmpdApi();
      await api.start(
        fixture.endpoint,
        name: 'phone',
        profile: 'dev',
        cwd: '/synthetic/work',
        session: '/synthetic/saved.jsonl',
      );
      expect(fixture.requests.single, {
        'method': 'start',
        'name': 'phone',
        'profile': 'dev',
        'cwd': '/synthetic/work',
        'session': '/synthetic/saved.jsonl',
      });
      fixture.requests.clear();
      await api.start(fixture.endpoint, name: 'phone', cwd: '/synthetic/work');
      expect(fixture.requests.single.containsKey('session'), isFalse);
    },
  );

  test(
    'profileless start requires absolute remote cwd before networking',
    () async {
      await expectLater(
        const OmpdApi().start(fixture.endpoint, name: 'phone'),
        throwsA(isA<HarnessException>()),
      );
      await expectLater(
        const OmpdApi().start(
          fixture.endpoint,
          name: 'bad\nname',
          cwd: '/work',
        ),
        throwsA(isA<HarnessException>()),
      );
      expect(fixture.requests, isEmpty);
    },
  );

  test(
    'readiness polls ready-but-metadata-pending and returns session-safe status',
    () async {
      var poll = 0;
      fixture.onControl = (socket, request) async {
        poll++;
        final result = Map<String, Object?>.from(fixture.instance);
        if (poll == 1) {
          result['ready'] = false;
          result['state'] = 'starting';
        }
        if (poll < 3) {
          result['session'] = {'id': null, 'name': null, 'file': null};
        }
        await fixture.send(socket, {'result': result});
      };
      const api = OmpdApi(pollInterval: Duration(milliseconds: 2));
      expect(
        (await api.waitUntilReady(fixture.endpoint, 'phone')).sessionId,
        'fixture-session',
      );
      expect(poll, 3);
      expect(
        fixture.requests.every((request) => request['method'] == 'status'),
        isTrue,
      );
    },
  );

  test(
    'ready session id still waits for asynchronous canonical file metadata',
    () async {
      var poll = 0;
      fixture.onControl = (socket, request) async {
        final result = Map<String, Object?>.from(fixture.instance);
        if (++poll == 1) {
          result['session'] = {'id': fixture.sessionId, 'file': null};
        }
        await fixture.send(socket, {'result': result});
      };
      const api = OmpdApi(pollInterval: Duration(milliseconds: 2));
      final ready = await api.waitUntilReady(fixture.endpoint, 'phone');
      expect(ready.sessionFile, fixture.sessionFile);
      expect(poll, 2);
      expect(
        fixture.requests.where((request) => request['method'] == 'start'),
        isEmpty,
      );
    },
  );

  test('readiness has bounded timeout and rejects stopped worker', () async {
    fixture.onControl = (socket, request) async {
      final result = Map<String, Object?>.from(fixture.instance)
        ..['ready'] = false;
      await fixture.send(socket, {'result': result});
    };
    const api = OmpdApi(
      readinessTimeout: Duration(milliseconds: 100),
      timeout: Duration(milliseconds: 100),
      pollInterval: Duration(milliseconds: 5),
    );
    await expectLater(
      api.waitUntilReady(fixture.endpoint, 'phone'),
      throwsA(isA<HarnessException>()),
    );
    fixture.onControl = (socket, request) async {
      final result = Map<String, Object?>.from(fixture.instance)
        ..['ready'] = false
        ..['state'] = 'exited';
      await fixture.send(socket, {'result': result});
    };
    await expectLater(
      api.waitUntilReady(fixture.endpoint, 'phone'),
      throwsA(isA<HarnessException>()),
    );
  });

  test(
    'raw control errors timeout and premature close are sanitized',
    () async {
      fixture.rejectControl = true;
      try {
        await const OmpdApi().status(fixture.endpoint);
        fail('accepted server error');
      } on HarnessException catch (error) {
        expect(error.message, isNot(contains('PRIVATE-ERROR-TOKEN')));
      }
      fixture.rejectControl = false;
      fixture.onControl = (socket, request) async {
        socket.destroy();
      };
      await expectLater(
        const OmpdApi().status(fixture.endpoint),
        throwsA(isA<HarnessException>()),
      );
      fixture.onControl = (socket, request) async {};
      await expectLater(
        const OmpdApi(
          timeout: Duration(milliseconds: 100),
        ).status(fixture.endpoint),
        throwsA(isA<HarnessException>()),
      );
    },
  );
}
