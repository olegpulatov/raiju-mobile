// MODIFIED FOR RAIJU: retained push revocation records are compatibility data;
// production storage, key decoding, retry, and publication are disabled.
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:nostr/nostr.dart' as nostr;

import '../community/community.dart';
import '../relay/backend_disabled.dart';
import 'push_bridge.dart';

const _maxSafeJsonInteger = 9007199254740991;
const _lowercaseHex64Pattern = r'^[0-9a-f]{64}$';
const _installationIdPattern = r'^[0-9a-f]{32}$';

typedef BuzzPushLeaseRevocationPublisher =
    Future<void> Function(BuzzPushLeaseRevocationRecord record);
typedef BuzzPushLeaseRevocationClock = DateTime Function();
typedef BuzzPushLeaseRevocationJitter = double Function();
typedef BuzzPushLeaseRevocationErrorReporter =
    void Function(Object error, StackTrace stackTrace);
typedef BuzzPushLeaseRevocationWakeScheduler =
    void Function() Function(Duration delay, void Function() wake);

/// Durable state for retracting one precise NIP-PL lease address.
///
/// The signing key is intentionally retained in secure storage only until the
/// relay accepts the tombstone or the old endpoint grant expires.
@immutable
class BuzzPushLeaseRevocationRecord {
  final String relayUrl;
  final String relayOrigin;
  final String memberPubkey;
  final String nsec;
  final String installationId;

  /// Generation reserved for the next relay attempt.
  final int generation;
  final int expiresAt;
  final int attemptCount;
  final int nextAttemptAt;

  BuzzPushLeaseRevocationRecord({
    required this.relayUrl,
    required this.relayOrigin,
    required this.memberPubkey,
    required this.nsec,
    required this.installationId,
    required this.generation,
    required this.expiresAt,
    required this.attemptCount,
    required this.nextAttemptAt,
  }) {
    if (canonicalBuzzPushRelayOrigin(relayUrl) != relayOrigin) {
      throw const FormatException(
        'Push revocation relay URL and origin do not match.',
      );
    }
    if (!RegExp(_lowercaseHex64Pattern).hasMatch(memberPubkey)) {
      throw const FormatException(
        'Push revocation member pubkey must be exact lowercase hex.',
      );
    }
    final decoded = nostr.Nip19.decode(payload: nsec);
    if (decoded.prefix != nostr.Nip19Prefix.nsec ||
        decoded.data.length != 64 ||
        nostr.Keys(decoded.data).public != memberPubkey) {
      throw const FormatException(
        'Push revocation signing key does not match its member pubkey.',
      );
    }
    if (!RegExp(_installationIdPattern).hasMatch(installationId)) {
      throw const FormatException(
        'Push revocation installation id must be exact lowercase hex.',
      );
    }
    if (generation <= 0 || generation > _maxSafeJsonInteger) {
      throw const FormatException('Push revocation generation is invalid.');
    }
    if (expiresAt <= 0 || attemptCount < 0 || nextAttemptAt < 0) {
      throw const FormatException('Push revocation retry state is invalid.');
    }
  }

  String get leaseAddress => '$memberPubkey|$relayOrigin|$installationId';

  BuzzPushLeaseRevocationRecord copyWith({
    int? generation,
    int? expiresAt,
    int? attemptCount,
    int? nextAttemptAt,
  }) => BuzzPushLeaseRevocationRecord(
    relayUrl: relayUrl,
    relayOrigin: relayOrigin,
    memberPubkey: memberPubkey,
    nsec: nsec,
    installationId: installationId,
    generation: generation ?? this.generation,
    expiresAt: expiresAt ?? this.expiresAt,
    attemptCount: attemptCount ?? this.attemptCount,
    nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'relayUrl': relayUrl,
    'relayOrigin': relayOrigin,
    'memberPubkey': memberPubkey,
    'nsec': nsec,
    'installationId': installationId,
    'generation': generation,
    'expiresAt': expiresAt,
    'attemptCount': attemptCount,
    'nextAttemptAt': nextAttemptAt,
  };

  factory BuzzPushLeaseRevocationRecord.fromJson(Map<String, dynamic> json) {
    const keys = {
      'version',
      'relayUrl',
      'relayOrigin',
      'memberPubkey',
      'nsec',
      'installationId',
      'generation',
      'expiresAt',
      'attemptCount',
      'nextAttemptAt',
    };
    if (json.keys.toSet().difference(keys).isNotEmpty ||
        keys.difference(json.keys.toSet()).isNotEmpty ||
        json['version'] != 1 ||
        json['relayUrl'] is! String ||
        json['relayOrigin'] is! String ||
        json['memberPubkey'] is! String ||
        json['nsec'] is! String ||
        json['installationId'] is! String ||
        json['generation'] is! int ||
        json['expiresAt'] is! int ||
        json['attemptCount'] is! int ||
        json['nextAttemptAt'] is! int) {
      throw const FormatException('Invalid push revocation record.');
    }
    return BuzzPushLeaseRevocationRecord(
      relayUrl: json['relayUrl'] as String,
      relayOrigin: json['relayOrigin'] as String,
      memberPubkey: json['memberPubkey'] as String,
      nsec: json['nsec'] as String,
      installationId: json['installationId'] as String,
      generation: json['generation'] as int,
      expiresAt: json['expiresAt'] as int,
      attemptCount: json['attemptCount'] as int,
      nextAttemptAt: json['nextAttemptAt'] as int,
    );
  }
}

class BuzzPushLeaseRevocationStorage {

  BuzzPushLeaseRevocationStorage({FlutterSecureStorage? secure});

  Future<List<BuzzPushLeaseRevocationRecord>> loadAll() async => const [];

  Future<void> replaceAll(
    Iterable<BuzzPushLeaseRevocationRecord> records,
  ) => Future.error(buzzBackendUnavailable);
}

/// A durable, single-flight retry coordinator for removed-community leases.
///
/// Every attempt reserves its successor generation and retry time before
/// network I/O. A process death during an ambiguous publication therefore
/// cannot cause an immediate replay or reuse a generation the relay may have
/// accepted.
class BuzzPushLeaseRevocationOutbox {
  BuzzPushLeaseRevocationOutbox({
    required this.storage,
    required this.publisher,
    this.now = DateTime.now,
    BuzzPushLeaseRevocationJitter? jitter,
    this.reportError = reportPushLeaseCleanupError,
    BuzzPushLeaseRevocationWakeScheduler? scheduleWake,
  }) : jitter = jitter ?? Random.secure().nextDouble,
       scheduleWake = scheduleWake ?? _scheduleTimer;

  final BuzzPushLeaseRevocationStorage storage;
  final BuzzPushLeaseRevocationPublisher publisher;
  final BuzzPushLeaseRevocationClock now;
  final BuzzPushLeaseRevocationJitter jitter;
  final BuzzPushLeaseRevocationErrorReporter reportError;
  final BuzzPushLeaseRevocationWakeScheduler scheduleWake;


  Future<void> enqueue(BuzzPushLeaseRevocationRecord record) =>
      Future.error(buzzBackendUnavailable);

  Future<bool> enqueueCommunity(
    Community community, {
    Future<List<BuzzPushEndpointGrant>> Function()? readGrants,
  }) => Future.error(buzzBackendUnavailable);

  Future<void> start() => Future.error(buzzBackendUnavailable);

  Future<void> trigger() => Future.error(buzzBackendUnavailable);




  void dispose() {}
}

void Function() _scheduleTimer(Duration delay, void Function() wake) {
  final timer = Timer(delay, wake);
  return timer.cancel;
}

String canonicalBuzzPushRelayOrigin(String relayUrl) {
  final uri = _buzzPushRelayUri(relayUrl);
  final scheme = switch (uri.scheme) {
    'https' || 'wss' => 'wss',
    'http' || 'ws' => 'ws',
    _ => throw StateError('Validated relay URL has an unsupported scheme.'),
  };
  return '$scheme://${uri.authority}';
}

String canonicalBuzzPushRelayHttpUrl(String relayUrl) {
  final uri = _buzzPushRelayUri(relayUrl);
  final scheme = switch (uri.scheme) {
    'https' || 'wss' => 'https',
    'http' || 'ws' => 'http',
    _ => throw StateError('Validated relay URL has an unsupported scheme.'),
  };
  return uri.replace(scheme: scheme, path: '/').toString();
}

Uri _buzzPushRelayUri(String relayUrl) {
  final uri = Uri.tryParse(relayUrl);
  if (uri == null ||
      !const {'http', 'https', 'ws', 'wss'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw FormatException('Invalid relay URL for push revocation: $relayUrl');
  }
  return uri;
}

Future<void> publishBuzzPushLeaseRevocation(
  BuzzPushLeaseRevocationRecord record,
) => Future.error(buzzBackendUnavailable);

final buzzPushLeaseRevocationStorageProvider =
    Provider<BuzzPushLeaseRevocationStorage>(
      (ref) => BuzzPushLeaseRevocationStorage(),
    );

final buzzPushLeaseRevocationOutboxProvider =
    Provider<BuzzPushLeaseRevocationOutbox>((ref) {
      final outbox = BuzzPushLeaseRevocationOutbox(
        storage: ref.read(buzzPushLeaseRevocationStorageProvider),
        publisher: publishBuzzPushLeaseRevocation,
      );
      ref.onDispose(outbox.dispose);
      return outbox;
    });
