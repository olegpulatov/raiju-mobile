import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:raiju_mobile/harness/harness.dart';
import 'package:raiju_mobile/harness/ompd_wire.dart';

import 'ompd_fixture.dart';

void main() {
  late OmpdFixture fixture;
  setUp(() async {
    fixture = OmpdFixture();
    await fixture.open();
  });
  tearDown(() => fixture.close());

  test('split UTF8 and multiple coalesced JSON lines retain framing', () async {
    final wire = await OmpdWire.connect(
      fixture.endpoint,
      timeout: const Duration(seconds: 1),
    );
    final received = <Map<String, Object?>>[];
    final subscription = wire.frames.listen(received.add);
    await waitFor(() => fixture.sockets.isNotEmpty);
    final socket = fixture.sockets.single;
    final bytes = utf8.encode('{"text":"привет"}\n');
    socket.add(
      bytes.sublist(0, 10),
    ); // Split inside the multibyte first letter.
    await socket.flush();
    socket.add([
      ...bytes.sublist(10),
      ...utf8.encode('{"next":2}\n{"last":3}\n'),
    ]);
    await socket.flush();
    await waitFor(() => received.length == 3);
    expect(received, [
      {'text': 'привет'},
      {'next': 2},
      {'last': 3},
    ]);
    await subscription.cancel();
    await wire.close();
  });

  test(
    'frame cap includes newline and rejects unbounded incomplete frames',
    () async {
      final wire = await OmpdWire.connect(
        fixture.endpoint,
        timeout: const Duration(seconds: 1),
        maxFrameBytes: 32,
      );
      final error = Completer<Object>();
      final subscription = wire.frames.listen((_) {}, onError: error.complete);
      await waitFor(() => fixture.sockets.isNotEmpty);
      fixture.sockets.single.add(List<int>.filled(33, 65));
      await fixture.sockets.single.flush();
      expect(
        await error.future.timeout(const Duration(seconds: 1)),
        isA<HarnessException>(),
      );
      await subscription.cancel();
      await wire.close();
    },
  );

  test('incomplete frame times out but idle stream does not', () async {
    final wire = await OmpdWire.connect(
      fixture.endpoint,
      timeout: const Duration(milliseconds: 100),
    );
    final errors = <Object>[];
    final subscription = wire.frames.listen((_) {}, onError: errors.add);
    await waitFor(() => fixture.sockets.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(errors, isEmpty);
    fixture.sockets.single.add(utf8.encode('{"partial":'));
    await fixture.sockets.single.flush();
    await waitFor(() => errors.isNotEmpty);
    expect(errors.single, isA<HarnessException>());
    await subscription.cancel();
    await wire.close();
  });

  test('invalid JSON errors never echo raw payload', () async {
    final wire = await OmpdWire.connect(
      fixture.endpoint,
      timeout: const Duration(seconds: 1),
    );
    final error = Completer<Object>();
    final subscription = wire.frames.listen((_) {}, onError: error.complete);
    await waitFor(() => fixture.sockets.isNotEmpty);
    fixture.sockets.single.add(utf8.encode('PRIVATE-INVALID-JSON\n'));
    await fixture.sockets.single.flush();
    expect(
      (await error.future).toString(),
      isNot(contains('PRIVATE-INVALID-JSON')),
    );
    await subscription.cancel();
    await wire.close();
  });

  test('oversized outgoing request is rejected before writing', () async {
    final wire = await OmpdWire.connect(
      fixture.endpoint,
      timeout: const Duration(seconds: 1),
      maxFrameBytes: 32,
    );
    expect(
      () => wire.send({'method': List<String>.filled(64, 'x').join()}),
      throwsA(isA<HarnessException>()),
    );
    expect(fixture.requests, isEmpty);
    await wire.close();
  });
}
