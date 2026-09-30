import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../harness/harness.dart';
import '../storage/voice_transcript.dart';
import 'companion_provider.dart';

/// Harmless, local-only dialogue for the normal-entrypoint restart probe.
List<VoiceTurn> acceptanceVoiceTurns(String replyDigest, int firstSequence) => [
  VoiceTurn(
    id: 'raiju-acceptance-$replyDigest-1',
    sequence: firstSequence,
    origin: VoiceTurnOrigin.user,
    text: 'Synthetic spoken request, not delegated',
  ),
  VoiceTurn(
    id: 'raiju-acceptance-$replyDigest-2',
    sequence: firstSequence + 1,
    origin: VoiceTurnOrigin.spark,
    text: 'Synthetic local voice response',
  ),
  VoiceTurn(
    id: 'raiju-acceptance-$replyDigest-3',
    sequence: firstSequence + 2,
    origin: VoiceTurnOrigin.user,
    text: 'Synthetic spoken follow-up, not delegated',
    delivery: VoiceDelivery.uncertain,
  ),
];

String acceptanceVoiceCanonical(List<VoiceTurn> turns) => jsonEncode([
  for (final turn in turns)
    [
      turn.id,
      turn.sequence - turns.first.sequence,
      turn.origin.name,
      turn.text,
      turn.delivery.name,
      turn.hostEntryId,
      turn.precedingHostEntryId,
    ],
]);

({bool text, bool origin, bool delivery, bool ordering})
inspectAcceptanceVoiceTurns(List<VoiceTurn> turns, String replyDigest) {
  final prefix = 'raiju-acceptance-$replyDigest-';
  final matched = turns.where((turn) => turn.id.startsWith(prefix)).toList();
  if (matched.length != 3) {
    return (text: false, origin: false, delivery: false, ordering: false);
  }
  final expected = acceptanceVoiceTurns(replyDigest, matched.first.sequence);
  return (
    text: List.generate(
      3,
      (i) => matched[i].text == expected[i].text,
    ).every((match) => match),
    origin: List.generate(
      3,
      (i) => matched[i].origin == expected[i].origin,
    ).every((match) => match),
    delivery: List.generate(
      3,
      (i) =>
          matched[i].delivery == expected[i].delivery &&
          matched[i].hostEntryId == null &&
          matched[i].precedingHostEntryId == null,
    ).every((match) => match),
    ordering:
        matched.first.sequence >= 0 &&
        List.generate(
          3,
          (i) =>
              matched[i].id == expected[i].id &&
              matched[i].sequence == expected[i].sequence &&
              turns.indexOf(matched[i]) == turns.indexOf(matched.first) + i,
        ).every((match) => match),
  );
}

const acceptancePreviousProcessKey = 'raiju.acceptance.previous-process.v1';
const acceptanceProbeFileName = 'raiju-acceptance-probe.json';

final class RaijuAcceptanceProbeConfiguration {
  const RaijuAcceptanceProbeConfiguration({
    required this.expectedDraftDigest,
    required this.expectedReplyDigest,
    required this.expectedVoiceDigest,
  });

  final String expectedDraftDigest;
  final String expectedReplyDigest;
  final String expectedVoiceDigest;

  static RaijuAcceptanceProbeConfiguration? fromEnvironment() {
    const active = bool.fromEnvironment('RAIJU_ACCEPTANCE_PROBE');
    if (!kDebugMode || !active) return null;
    const draft = String.fromEnvironment('RAIJU_EXPECTED_DRAFT_SHA256');
    const reply = String.fromEnvironment('RAIJU_EXPECTED_REPLY_SHA256');
    const voice = String.fromEnvironment('RAIJU_EXPECTED_VOICE_SHA256');
    final digestPattern = RegExp(r'^[0-9a-f]{64}$');
    if (!digestPattern.hasMatch(draft) ||
        !digestPattern.hasMatch(reply) ||
        !digestPattern.hasMatch(voice)) {
      return null;
    }
    return const RaijuAcceptanceProbeConfiguration(
      expectedDraftDigest: draft,
      expectedReplyDigest: reply,
      expectedVoiceDigest: voice,
    );
  }
}

final class RaijuAcceptanceProbe extends ConsumerStatefulWidget {
  const RaijuAcceptanceProbe({
    required this.configuration,
    required this.child,
    super.key,
  });

  final RaijuAcceptanceProbeConfiguration configuration;
  final Widget child;

  @override
  ConsumerState<RaijuAcceptanceProbe> createState() =>
      _RaijuAcceptanceProbeState();
}

final class _RaijuAcceptanceProbeState
    extends ConsumerState<RaijuAcceptanceProbe> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  Widget build(BuildContext context) => widget.child;

  Future<void> _run() async {
    final directory = await getApplicationSupportDirectory();
    final output = File('${directory.path}/$acceptanceProbeFileName');
    if (await output.exists()) await output.delete();
    final temporary = File('${output.path}.tmp');
    if (await temporary.exists()) await temporary.delete();

    final preferences = await SharedPreferences.getInstance();
    final previousProcess = preferences.getInt(acceptancePreviousProcessKey);
    await preferences.remove(acceptancePreviousProcessKey);
    final newProcess = previousProcess != null && previousProcess != pid;
    final controller = ref.read(companionControllerProvider);
    await controller.initialize();

    var restoredSession = false;
    var draftDigestMatches = false;
    var transcriptDigestMatches = false;
    var liveReconnect = false;
    var voiceTextMatches = false;
    var voiceOriginMatches = false;
    var voiceDeliveryMatches = false;
    var voiceOrderingMatches = false;
    var voiceDigestMatches = false;
    var chatCount = 0;
    var messageCount = 0;
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (mounted && DateTime.now().isBefore(deadline)) {
      final chats = controller.chats;
      chatCount = chats.length;
      for (final chat in chats) {
        final draftMatches =
            await _digest(chat.draft) ==
            widget.configuration.expectedDraftDigest;
        final replyMatches = await _containsDigest(
          chat.snapshot.messages.map((message) => message.text),
          widget.configuration.expectedReplyDigest,
        );
        if (draftMatches && replyMatches) {
          restoredSession = true;
          draftDigestMatches = true;
          transcriptDigestMatches = true;
          final voice = inspectAcceptanceVoiceTurns(
            chat.voiceTurns,
            widget.configuration.expectedReplyDigest,
          );
          voiceTextMatches = voice.text;
          voiceOriginMatches = voice.origin;
          voiceDeliveryMatches = voice.delivery;
          voiceOrderingMatches = voice.ordering;
          final voiceTurns = chat.voiceTurns
              .where(
                (turn) => turn.id.startsWith(
                  'raiju-acceptance-${widget.configuration.expectedReplyDigest}-',
                ),
              )
              .toList();
          voiceDigestMatches =
              voiceTurns.isNotEmpty &&
              await _digest(acceptanceVoiceCanonical(voiceTurns)) ==
                  widget.configuration.expectedVoiceDigest;
          liveReconnect = chat.snapshot.phase == ConnectionPhase.live;
          messageCount = chat.snapshot.messages.length;
          break;
        }
      }
      if (restoredSession &&
          liveReconnect &&
          newProcess &&
          voiceTextMatches &&
          voiceOriginMatches &&
          voiceDeliveryMatches &&
          voiceOrderingMatches &&
          voiceDigestMatches) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    final result = <String, Object>{
      'restoredSession': restoredSession,
      'draftDigestMatches': draftDigestMatches,
      'transcriptDigestMatches': transcriptDigestMatches,
      'voiceTextMatches': voiceTextMatches,
      'voiceOriginMatches': voiceOriginMatches,
      'voiceDeliveryMatches': voiceDeliveryMatches,
      'voiceOrderingMatches': voiceOrderingMatches,
      'voiceDigestMatches': voiceDigestMatches,
      'liveReconnect': liveReconnect,
      'storageAvailable': controller.storageError == null,
      'newProcess': newProcess,
      'chatCount': chatCount,
      'messageCount': messageCount,
      'runDigest': widget.configuration.expectedReplyDigest,
    };
    await temporary.writeAsString(jsonEncode(result), flush: true);
    await temporary.rename(output.path);
  }
}

Future<bool> _containsDigest(Iterable<String> values, String expected) async {
  for (final value in values) {
    if (await _digest(value.trim()) == expected) return true;
  }
  return false;
}

Future<String> _digest(String value) async {
  final hash = await Sha256().hash(utf8.encode(value));
  return hash.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}
