import 'dart:convert';

import 'package:buzz/raiju/acceptance_probe.dart';
import 'package:buzz/storage/voice_transcript.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const runDigest = 'synthetic-run-digest';
  final seeded = acceptanceVoiceTurns(runDigest, 41);

  test('checks exact local voice text, origins, delivery and ordering', () {
    final intact = inspectAcceptanceVoiceTurns(seeded, runDigest);
    expect(intact.text, isTrue);
    expect(intact.origin, isTrue);
    expect(intact.delivery, isTrue);
    expect(intact.ordering, isTrue);

    final wrongText = [
      seeded.first,
      VoiceTurn(
        id: seeded[1].id,
        sequence: seeded[1].sequence,
        origin: seeded[1].origin,
        text: 'changed',
      ),
      seeded.last,
    ];
    expect(inspectAcceptanceVoiceTurns(wrongText, runDigest).text, isFalse);

    final wrongOrigin = [
      seeded.first,
      VoiceTurn(
        id: seeded[1].id,
        sequence: seeded[1].sequence,
        origin: VoiceTurnOrigin.user,
        text: seeded[1].text,
      ),
      seeded.last,
    ];
    expect(inspectAcceptanceVoiceTurns(wrongOrigin, runDigest).origin, isFalse);

    final delegated = [
      seeded.first.copyWith(
        delivery: VoiceDelivery.delivered,
        hostEntryId: 'host',
      ),
      seeded[1],
      seeded.last,
    ];
    expect(inspectAcceptanceVoiceTurns(delegated, runDigest).delivery, isFalse);
    final boundaryDrift = [
      seeded.first.copyWith(precedingHostEntryId: 'host'),
      seeded[1],
      seeded.last,
    ];
    expect(
      inspectAcceptanceVoiceTurns(boundaryDrift, runDigest).delivery,
      isFalse,
    );

    final outOfOrder = [seeded[1], seeded.first, seeded.last];
    expect(
      inspectAcceptanceVoiceTurns(outOfOrder, runDigest).ordering,
      isFalse,
    );
    expect(
      inspectAcceptanceVoiceTurns(seeded.take(2).toList(), runDigest).ordering,
      isFalse,
    );
  });

  test('relative canonical digest matches independent synthetic fixture', () {
    final later = acceptanceVoiceTurns(runDigest, 900);
    final expected = jsonEncode([
      [
        'raiju-acceptance-$runDigest-1',
        0,
        'user',
        'Synthetic spoken request, not delegated',
        'pending',
        null,
        null,
      ],
      [
        'raiju-acceptance-$runDigest-2',
        1,
        'spark',
        'Synthetic local voice response',
        'pending',
        null,
        null,
      ],
      [
        'raiju-acceptance-$runDigest-3',
        2,
        'user',
        'Synthetic spoken follow-up, not delegated',
        'uncertain',
        null,
        null,
      ],
    ]);
    final digest = sha256.convert(utf8.encode(expected));
    expect(
      sha256.convert(utf8.encode(acceptanceVoiceCanonical(seeded))),
      digest,
    );
    expect(
      sha256.convert(utf8.encode(acceptanceVoiceCanonical(later))),
      digest,
    );
  });
}
