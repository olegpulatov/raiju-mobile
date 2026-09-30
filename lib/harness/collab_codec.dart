// OMP collab protocol v3 codec, translated for Raiju from
// @oh-my-pi/collab-web/src/lib/codec.ts. Layout is exactly
// [12-byte nonce][ciphertext][16-byte AES-GCM authentication tag].
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const int collabNonceBytes = 12;
const int collabTagBytes = 16;

final class CollabCodecException implements Exception {
  const CollabCodecException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract interface class CollabFrameCodec {
  Future<Uint8List> seal(Map<String, Object?> frame);
  Future<Map<String, Object?>> open(List<int> sealed);
}

final class CollabCodec implements CollabFrameCodec {
  CollabCodec(List<int> key, {Random? random})
    : _key = SecretKeyData(_validatedKey(key)),
      _random = random ?? Random.secure();

  final SecretKey _key;
  final Random _random;
  final AesGcm _algorithm = AesGcm.with256bits();

  @override
  Future<Uint8List> seal(Map<String, Object?> frame, {List<int>? nonce}) =>
      sealBytes(utf8.encode(jsonEncode(frame)), nonce: nonce);

  /// Raw-byte seam used to verify interoperability against published AES-GCM
  /// vectors; application frames use [seal].
  Future<Uint8List> sealBytes(List<int> clearText, {List<int>? nonce}) async {
    final actualNonce = Uint8List.fromList(
      nonce ??
          List<int>.generate(collabNonceBytes, (_) => _random.nextInt(256)),
    );
    if (actualNonce.length != collabNonceBytes) {
      throw const CollabCodecException('Invalid collaboration frame nonce.');
    }
    final box = await _algorithm.encrypt(
      clearText,
      secretKey: _key,
      nonce: actualNonce,
    );
    final result = Uint8List(
      collabNonceBytes + box.cipherText.length + collabTagBytes,
    );
    result.setRange(0, collabNonceBytes, actualNonce);
    result.setRange(
      collabNonceBytes,
      collabNonceBytes + box.cipherText.length,
      box.cipherText,
    );
    result.setRange(
      result.length - collabTagBytes,
      result.length,
      box.mac.bytes,
    );
    return result;
  }

  @override
  Future<Map<String, Object?>> open(List<int> sealed) async {
    try {
      final decoded = jsonDecode(utf8.decode(await openBytes(sealed)));
      if (decoded is! Map) {
        throw const FormatException('frame is not an object');
      }
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    } on FormatException {
      throw const CollabCodecException(
        'Invalid encrypted collaboration frame.',
      );
    }
  }

  /// Raw-byte counterpart to [sealBytes].
  Future<Uint8List> openBytes(List<int> sealed) async {
    if (sealed.length < collabNonceBytes + collabTagBytes) {
      throw const CollabCodecException(
        'Invalid encrypted collaboration frame.',
      );
    }
    final nonce = sealed.sublist(0, collabNonceBytes);
    final cipherText = sealed.sublist(
      collabNonceBytes,
      sealed.length - collabTagBytes,
    );
    final tag = sealed.sublist(sealed.length - collabTagBytes);
    try {
      return Uint8List.fromList(
        await _algorithm.decrypt(
          SecretBox(cipherText, nonce: nonce, mac: Mac(tag)),
          secretKey: _key,
        ),
      );
    } on SecretBoxAuthenticationError {
      throw const CollabCodecException(
        'Bad key or corrupted collaboration frame.',
      );
    }
  }
}

Uint8List _validatedKey(List<int> key) {
  if (key.length != 32) {
    throw const CollabCodecException('Invalid collaboration room key.');
  }
  return Uint8List.fromList(key);
}
