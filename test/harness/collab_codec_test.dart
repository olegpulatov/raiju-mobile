import 'dart:typed_data';

import 'package:raiju_mobile/harness/collab_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('matches NIST AES-256-GCM empty-plaintext vector', () async {
    // NIST SP 800-38D AES-256-GCM: K=0^256, IV=0^96, P/A empty.
    final codec = CollabCodec(Uint8List(32));
    final sealed = await codec.sealBytes(const [], nonce: Uint8List(12));
    expect(
      _hex(sealed),
      '000000000000000000000000530f8afbc74536b9a963b4f1c4cb738b',
    );
    expect(await codec.openBytes(sealed), isEmpty);
  });

  test('round trips unicode JSON with nonce/ciphertext/tag layout', () async {
    final codec = CollabCodec(List<int>.generate(32, (index) => index));
    final sealed = await codec.seal(const {
      't': 'prompt',
      'text': 'hello 雷獣',
    }, nonce: List<int>.generate(12, (index) => index + 1));
    expect(sealed.take(12), List<int>.generate(12, (index) => index + 1));
    expect(sealed.length, greaterThan(12 + 16));
    expect(await codec.open(sealed), const {'t': 'prompt', 'text': 'hello 雷獣'});
  });

  test('rejects tampering and a wrong key', () async {
    final codec = CollabCodec(List<int>.generate(32, (index) => index));
    final sealed = await codec.seal(const {'t': 'abort'}, nonce: Uint8List(12));
    final tampered = Uint8List.fromList(sealed)..[12] ^= 1;
    await expectLater(
      codec.open(tampered),
      throwsA(isA<CollabCodecException>()),
    );
    final wrong = CollabCodec(List<int>.filled(32, 7));
    await expectLater(wrong.open(sealed), throwsA(isA<CollabCodecException>()));
  });
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
