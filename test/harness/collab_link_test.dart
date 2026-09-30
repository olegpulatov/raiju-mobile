import 'dart:typed_data';

import 'package:buzz/harness/collab_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = Uint8List.fromList(List<int>.generate(32, (index) => index));
  final token = Uint8List.fromList(
    List<int>.generate(16, (index) => 32 + index),
  );
  const room = 'AbCdEf123456_-Xy';

  group('collab links', () {
    test('parses bare dot and legacy hash links', () {
      final secret = encodeBase64Url(key);
      for (final separator in ['.', '#']) {
        final parsed = parseCollabLink('$room$separator$secret');
        expect(parsed.socketUri.toString(), 'wss://ompc.home.arpa/r/$room');
        expect(parsed.key, key);
        expect(parsed.writeToken, isNull);
      }
    });

    test('bare code uses preference and pins full link with both secrets', () {
      final secret = encodeBase64Url([...key, ...token]);
      final bare = '$room.$secret';
      final pinned = pinBareCollabLink(
        bare,
        defaultRelay: 'wss://preferred.example:9443',
      );
      final parsed = parseCollabLink(
        pinned,
        defaultRelay: 'wss://different.example',
      );
      expect(
        parsed.socketUri.toString(),
        'wss://preferred.example:9443/r/$room',
      );
      expect(parsed.key, key);
      expect(parsed.writeToken, token);
      expect(pinned, isNot(contains('different.example')));
      final wrapper = 'https://viewer.example/#$bare';
      final pinnedWrapper = pinBareCollabLink(
        wrapper,
        defaultRelay: 'wss://preferred.example:9443',
      );
      expect(
        parseCollabLink(
          pinnedWrapper,
          defaultRelay: 'wss://different.example',
        ).socketUri.toString(),
        'wss://preferred.example:9443/r/$room',
      );
      expect(pinnedWrapper, isNot(contains('viewer.example')));
    });

    test('full QR link ignores even an invalid default relay', () {
      final secret = encodeBase64Url(key);
      final full = 'wss://qr.example/r/$room#$secret';
      expect(
        parseCollabLink(
          full,
          defaultRelay: 'ws://remote.example',
        ).socketUri.host,
        'qr.example',
      );
      expect(
        pinBareCollabLink(full, defaultRelay: 'ws://remote.example'),
        full,
      );
      expect(
        parseCollabLink(
          'https://viewer.example/#$full',
          defaultRelay: 'wss://preferred.example',
        ).socketUri.host,
        'qr.example',
      );
      final wrapperWithFullLink = 'https://viewer.example/#$full';
      expect(
        pinBareCollabLink(
          wrapperWithFullLink,
          defaultRelay: 'wss://preferred.example',
        ),
        wrapperWithFullLink,
      );
      expect(
        parseCollabLink(
          'https://viewer.example/#$room.$secret',
          defaultRelay: 'wss://preferred.example',
        ).socketUri.host,
        'preferred.example',
      );
    });

    test('validates safe relay origins without credentials or paths', () {
      expect(
        validateCollabRelay(' WSS://relay.example:9443 '),
        'wss://relay.example:9443',
      );
      expect(validateCollabRelay('ws://localhost:8787'), 'ws://localhost:8787');
      for (final origin in [
        'ws://remote.example',
        'https://relay.example',
        'wss://user:pass@relay.example',
        'wss://relay.example/r/room',
        'wss://relay.example/?secret=123',
        'wss://relay.example/#secret',
      ]) {
        expect(
          () => validateCollabRelay(origin),
          throwsA(isA<CollabLinkException>()),
        );
      }
    });

    test('parses full key and token without exposing either', () {
      final secret = encodeBase64Url([...key, ...token]);
      final parsed = parseCollabLink('relay.example/r/$room.$secret');
      expect(parsed.socketUri.toString(), 'wss://relay.example/r/$room');
      expect(parsed.key, key);
      expect(parsed.writeToken, token);
      expect(parsed.toString(), isNot(contains(secret)));
    });

    test('parses browser wrappers and percent-mangled legacy forms', () {
      final secret = encodeBase64Url(key);
      expect(
        parseCollabLink('https://viewer.example/#$room.$secret').roomId,
        room,
      );
      expect(
        parseCollabLink('https://my.omp.sh/r/$room%23$secret').roomId,
        room,
      );
      expect(
        parseCollabLink(
          'https://viewer.example/#https://relay.example/r/$room.$secret',
        ).socketUri.host,
        'relay.example',
      );
    });

    test('allows local ws and rejects insecure remote ws', () {
      final secret = encodeBase64Url(key);
      expect(
        parseCollabLink('ws://localhost:8787/r/$room#$secret').socketUri.scheme,
        'ws',
      );
      expect(
        () => parseCollabLink('ws://relay.example/r/$room#$secret'),
        throwsA(isA<CollabLinkException>()),
      );
    });

    test('rejects malformed paths and secret lengths with safe errors', () {
      for (final input in [
        'https://relay.example/not-a-room#${encodeBase64Url(key)}',
        '$room.${encodeBase64Url(key.take(31).toList())}',
      ]) {
        expect(
          () => parseCollabLink(input),
          throwsA(
            isA<CollabLinkException>().having(
              (error) => error.toString(),
              'safe message',
              isNot(contains(input)),
            ),
          ),
        );
      }
    });
  });

  group('wire envelope', () {
    test('uses unsigned big-endian peer prefix', () {
      final packed = packCollabEnvelope(0x01020304, [9, 8, 7]);
      expect(packed, [1, 2, 3, 4, 9, 8, 7]);
      final unpacked = unpackCollabEnvelope(packed)!;
      expect(unpacked.peerId, 0x01020304);
      expect(unpacked.payload, [9, 8, 7]);
    });

    test('rejects truncated prefix', () {
      expect(unpackCollabEnvelope([0, 1, 2]), isNull);
    });
  });
}
