/// Reject new turns beyond this capacity rather than evicting pending dialogue.
const int maxStoredVoiceTurnsPerChat = 10000;

/// Local voice turns are separate from the authoritative remote replica.
enum VoiceTurnOrigin { user, spark, typedUser }

enum VoiceDelivery { pending, uncertain, delivered }

/// Routing provenance is local metadata, not a claim about provider identity.
enum VoiceTurnPurpose {
  dialogue,
  acknowledgement,
  resultFeedback,
  request,
  lateContext,
}

class VoiceTurn {
  const VoiceTurn({
    required this.id,
    required this.sequence,
    required this.origin,
    required this.text,
    this.createdAt,
    this.precedingHostEntryId,
    this.precedingRenderedEntryId,
    this.delivery = VoiceDelivery.pending,
    this.hostEntryId,
    this.echoRemainder,
    this.typedEcho = false,
    this.routingPurpose = VoiceTurnPurpose.dialogue,
    this.routingRequestId,
    this.routingRequestText,
    this.routingPackageText,
    this.routingSourceTurnId,
    this.routingAwaitingSource = false,
  });

  final String id;
  final int sequence;
  final VoiceTurnOrigin origin;
  final String text;

  /// Capture time of this local event; older saved turns may not have one.
  final DateTime? createdAt;
  final VoiceDelivery delivery;
  final VoiceTurnPurpose routingPurpose;

  /// Synthetic, user-derived request reservation, never an observed human turn.
  final String? routingRequestId;
  final String? routingRequestText;
  final String? routingPackageText;
  final String? routingSourceTurnId;
  final bool routingAwaitingSource;

  /// Only an actually observed host entry ID; never inferred from a timestamp.
  final String? hostEntryId;

  /// Latest actually observed host entry when the local turn was finalized.
  final String? precedingHostEntryId;

  /// Nearest actually rendered remote entry when this turn was finalized;
  /// supports cache-window ordering if the raw predecessor is not rendered.
  final String? precedingRenderedEntryId;

  /// True only after this voice turn was confirmed inside a typed prompt echo.
  final bool typedEcho;

  /// Exact visible suffix after collapsing a confirmed host echo. Null means
  /// unknown; empty string means the entire echo was local dialogue.
  final String? echoRemainder;

  VoiceTurn copyWith({
    String? text,
    DateTime? createdAt,
    VoiceDelivery? delivery,
    String? hostEntryId,
    String? precedingHostEntryId,
    String? precedingRenderedEntryId,
    bool? typedEcho,
    String? echoRemainder,
    VoiceTurnPurpose? routingPurpose,
    String? routingRequestId,
    String? routingRequestText,
    String? routingPackageText,
    String? routingSourceTurnId,
    bool? routingAwaitingSource,
  }) => VoiceTurn(
    id: id,
    sequence: sequence,
    origin: origin,
    text: text ?? this.text,
    createdAt: createdAt ?? this.createdAt,
    delivery: delivery ?? this.delivery,
    hostEntryId: hostEntryId ?? this.hostEntryId,
    precedingHostEntryId: precedingHostEntryId ?? this.precedingHostEntryId,
    precedingRenderedEntryId:
        precedingRenderedEntryId ?? this.precedingRenderedEntryId,
    echoRemainder: echoRemainder ?? this.echoRemainder,
    typedEcho: typedEcho ?? this.typedEcho,
    routingPurpose: routingPurpose ?? this.routingPurpose,
    routingRequestId: routingRequestId ?? this.routingRequestId,
    routingRequestText: routingRequestText ?? this.routingRequestText,
    routingPackageText: routingPackageText ?? this.routingPackageText,
    routingSourceTurnId: routingSourceTurnId ?? this.routingSourceTurnId,
    routingAwaitingSource: routingAwaitingSource ?? this.routingAwaitingSource,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'sequence': sequence,
    'origin': origin.name,
    'text': text,
    'createdAt': createdAt?.toUtc().toIso8601String(),
    'delivery': delivery.name,
    'hostEntryId': hostEntryId,
    'precedingHostEntryId': precedingHostEntryId,
    'precedingRenderedEntryId': precedingRenderedEntryId,
    'typedEcho': typedEcho,
    'echoRemainder': echoRemainder,
    'routingPurpose': routingPurpose.name,
    'routingRequestId': routingRequestId,
    'routingRequestText': routingRequestText,
    'routingPackageText': routingPackageText,
    'routingSourceTurnId': routingSourceTurnId,
    'routingAwaitingSource': routingAwaitingSource,
  };

  factory VoiceTurn.fromJson(Map<String, dynamic> map) {
    String requiredString(String key) {
      final value = map[key];
      if (value is! String) throw FormatException('Invalid $key');
      return value;
    }

    final sequence = map['sequence'];
    if (sequence is! int || sequence < 0) {
      throw const FormatException('Invalid voice sequence');
    }
    final typedEcho = map['typedEcho'];
    if (typedEcho != null && typedEcho is! bool) {
      throw const FormatException('Invalid typedEcho');
    }
    final awaitingSource = map['routingAwaitingSource'];
    if (awaitingSource != null && awaitingSource is! bool) {
      throw const FormatException('Invalid routingAwaitingSource');
    }
    final createdAt = map['createdAt'];
    if (createdAt != null && createdAt is! String) {
      throw const FormatException('Invalid voice createdAt');
    }
    return VoiceTurn(
      id: requiredString('id'),
      sequence: sequence,
      origin: VoiceTurnOrigin.values.byName(requiredString('origin')),
      text: requiredString('text'),
      createdAt: createdAt == null ? null : DateTime.parse(createdAt).toUtc(),
      delivery: VoiceDelivery.values.byName(requiredString('delivery')),
      hostEntryId: map['hostEntryId'] as String?,
      precedingHostEntryId: map['precedingHostEntryId'] as String?,
      precedingRenderedEntryId: map['precedingRenderedEntryId'] as String?,
      typedEcho: typedEcho ?? false,
      echoRemainder: map['echoRemainder'] as String?,
      routingPurpose: map['routingPurpose'] == null
          ? VoiceTurnPurpose.dialogue
          : VoiceTurnPurpose.values.byName(requiredString('routingPurpose')),
      routingRequestId: map['routingRequestId'] as String?,
      routingRequestText: map['routingRequestText'] as String?,
      routingPackageText: map['routingPackageText'] as String?,
      routingSourceTurnId: map['routingSourceTurnId'] as String?,
      routingAwaitingSource: awaitingSource ?? false,
    );
  }
}
