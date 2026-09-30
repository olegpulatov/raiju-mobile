// MODIFIED FOR RAIJU: retained Buzz community declarations are neutral and
// all mutation paths fail closed without loading or storing Buzz credentials.
import 'dart:async';
import 'dart:developer' as developer;

import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../push/push_bridge.dart';
import '../push/push_subscription.dart';
import '../relay/backend_disabled.dart';
import 'community.dart';
import 'community_storage.dart';

final class CommunityTransitionCoordinator {
  final Map<Object, Future<void> Function()> _callbacks = {};
  Future<void>? _inFlight;
  Future<void> _operationTail = Future.value();

  void Function() register(Future<void> Function() callback) {
    final owner = Object();
    _callbacks[owner] = callback;
    return () => _callbacks.remove(owner);
  }

  /// Runs a complete community mutation after every earlier mutation finishes.
  ///
  /// Cleanup alone is intentionally memoized by [run], but callers that also
  /// mutate credentials or the active community must queue the whole operation
  /// here so they cannot race after sharing the same cleanup future.
  Future<void> runExclusive(Future<void> Function() operation) {
    final result = _operationTail.then((_) => operation());
    _operationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> run() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    final run = _runCallbacks();
    _inFlight = run;
    run.whenComplete(() {
      if (identical(_inFlight, run)) _inFlight = null;
    });
    return run;
  }

  Future<void> _runCallbacks() async {
    await Future.wait(
      _callbacks.values.map((callback) async {
        try {
          await callback();
        } catch (error, stackTrace) {
          developer.log(
            'Community transition cleanup failed',
            name: 'buzz.community',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }),
    );
  }
}

final communityTransitionProvider = Provider<CommunityTransitionCoordinator>(
  (ref) => CommunityTransitionCoordinator(),
);

final communityStorageProvider = Provider<CommunityStorage>((ref) {
  return CommunityStorage();
});

typedef CommunitySnapshotWriter =
    Future<void> Function(List<Community> communities);

typedef AgeGateCommunitySnapshotWriter =
    Future<void> Function(
      List<Community> communities, {
      required bool settleFence,
    });

/// Writes the complete persisted community set to storage shared with the iOS
/// notification service extension. Tests override this provider to verify that
/// every persistence path refreshes (or clears) the native snapshot.
final communitySnapshotWriterProvider = Provider<CommunitySnapshotWriter>((
  ref,
) {
  return registerBuzzPushCommunitySnapshot;
});

/// Strict writer used only for security-sensitive launch age-gate transitions.
final ageGateCommunitySnapshotWriterProvider =
    Provider<AgeGateCommunitySnapshotWriter>((ref) {
      return registerBuzzPushCommunitySnapshotStrict;
    });

final _communitySnapshotSyncProvider = Provider<_CommunitySnapshotSync>((ref) {
  return _CommunitySnapshotSync(
    ref.read(communitySnapshotWriterProvider),
    ref.read(ageGateCommunitySnapshotWriterProvider),
  );
});

/// Suspends or restores notification-service state at the launch age gate.
typedef CommunitySnapshotAgeGateAction = Future<void> Function();

/// Temporarily removes notification-service presentation material while the
/// launch age signal has not allowed access.
final suspendCommunitySnapshotForAgeCheckProvider =
    Provider<CommunitySnapshotAgeGateAction>((ref) {
      return () async {
        try {
          await ref.read(_communitySnapshotSyncProvider).suspendForAgeCheck();
          pushCommunitySnapshotError.value = null;
        } catch (error, stackTrace) {
          reportPushCommunitySnapshotError(error, stackTrace);
          Error.throwWithStackTrace(error, stackTrace);
        }
      };
    });

/// Restores notification-service presentation material after the launch age
/// signal allows access.
final resumeCommunitySnapshotAfterAgeCheckProvider =
    Provider<CommunitySnapshotAgeGateAction>((ref) {
      return () async {
        try {
          await ref
              .read(_communitySnapshotSyncProvider)
              .resumeAfterAgeCheck(ref.read(communityStorageProvider).loadAll);
          pushCommunitySnapshotError.value = null;
        } catch (error, stackTrace) {
          reportPushCommunitySnapshotError(error, stackTrace);
          Error.throwWithStackTrace(error, stackTrace);
        }
      };
    });

typedef CommunityPushLeaseDeactivator =
    Future<void> Function(Community community, {int? generation});

final communityPushLeaseDeactivatorProvider =
    Provider<CommunityPushLeaseDeactivator>(
      (ref) => (community, {generation}) =>
          Future.error(buzzBackendUnavailable),
    );

typedef CommunityPushLeaseRevocationEnqueuer =
    Future<bool> Function(Community community);

final communityPushLeaseRevocationEnqueuerProvider =
    Provider<CommunityPushLeaseRevocationEnqueuer>(
      (ref) => (community) => Future.error(buzzBackendUnavailable),
    );

typedef CommunityPushLeaseRevocationTrigger = Future<void> Function();

final communityPushLeaseRevocationTriggerProvider =
    Provider<CommunityPushLeaseRevocationTrigger>(
      (ref) => () => Future.error(buzzBackendUnavailable),
    );


class _CommunitySnapshotSync {
  _CommunitySnapshotSync(this._writer, this._ageGateWriter);

  final CommunitySnapshotWriter _writer;
  final AgeGateCommunitySnapshotWriter _ageGateWriter;
  ({String content, bool strict, bool settleFence})? _lastSuccessfulSnapshot;
  bool _ageRestricted = false;
  bool _ageCheckSuspended = false;
  Future<void> _mutationTail = Future.value();

  Future<void> _serializeMutation(Future<void> Function() operation) {
    final result = _mutationTail.then((_) => operation());
    _mutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> suspendForAgeCheck() => _serializeMutation(() async {
    if (!_ageRestricted) _ageCheckSuspended = true;
    await _write(
      const <Community>[],
      useAgeGateWriter: true,
      settleAgeGateFence: false,
    );
  });

  Future<void> resumeAfterAgeCheck(
    Future<List<Community>> Function() loadCommunities,
  ) => _serializeMutation(() async {
    if (_ageRestricted) return;
    final communities = await loadCommunities();
    _ageCheckSuspended = false;
    await _write(communities, useAgeGateWriter: true, settleAgeGateFence: true);
  });

  Future<void> write(
    List<Community> communities, {
    bool enforceAgeRestriction = false,
    bool useAgeGateWriter = false,
    bool settleAgeGateFence = false,
  }) {
    if (enforceAgeRestriction) _ageRestricted = true;
    // Ordinary exports must queue behind the entire restore, including its
    // storage read. Otherwise an export can finish during that read and then
    // be overwritten by the older list it returned.
    return _serializeMutation(
      () => _write(
        communities,
        useAgeGateWriter: useAgeGateWriter,
        settleAgeGateFence: settleAgeGateFence,
      ),
    );
  }

  Future<void> _write(
    List<Community> communities, {
    bool useAgeGateWriter = false,
    bool settleAgeGateFence = false,
  }) async {
    final effectiveCommunities = _ageRestricted || _ageCheckSuspended
        ? const <Community>[]
        : communities;
    final contentFingerprint = effectiveCommunities
        .map(
          (community) => [
            community.id,
            community.name,
            community.relayUrl,
            community.pubkey,
            community.nsec,
            community.pushNotificationsEnabled,
            buzzPushSubscriptionStateFingerprint(
              community.pushSubscriptionState,
            ),
          ].join('\u0000'),
        )
        .join('\u0001');
    // Both paths replace the same native data. Strict writes additionally
    // acknowledge the age-gate fence, so their mode is part of the request.
    final fingerprint = (
      content: contentFingerprint,
      strict: useAgeGateWriter,
      settleFence: settleAgeGateFence,
    );
    if (fingerprint == _lastSuccessfulSnapshot) return;

    if (useAgeGateWriter) {
      await _ageGateWriter(
        effectiveCommunities,
        settleFence: settleAgeGateFence,
      );
    } else {
      await _writer(effectiveCommunities);
    }
    _lastSuccessfulSnapshot = fingerprint;
  }
}

Future<void> syncCommunitySnapshot(Ref ref, List<Community> communities) async {
  try {
    await ref.read(_communitySnapshotSyncProvider).write(communities);
    pushCommunitySnapshotError.value = null;
  } catch (error, stackTrace) {
    reportPushCommunitySnapshotError(error, stackTrace);
  }
}

Future<void> syncStoredCommunitySnapshot(Ref ref) async {
  final communities = await ref.read(communityStorageProvider).loadAll();
  await syncCommunitySnapshot(ref, communities);
}


class CommunityListNotifier extends AsyncNotifier<List<Community>> {
  @override
  Future<List<Community>> build() async => const [];

  Future<String> addCommunity(Community community) =>
      Future.error(buzzBackendUnavailable);

  Future<void> removeCommunity(String id) =>
      Future.error(buzzBackendUnavailable);

  Future<void> removeActiveCommunityForSignOut() =>
      Future.error(buzzBackendUnavailable);

  Future<void> switchCommunity(String id) =>
      Future.error(buzzBackendUnavailable);

  Future<void> updateDesiredPushSubscriptions(
    String id,
    List<BuzzPushSubscription> desired,
  ) => Future.error(buzzBackendUnavailable);

  Future<int> reservePushLeaseGeneration(String id) =>
      Future.error(buzzBackendUnavailable);

  Future<bool> markPushLeaseAccepted(
    String id, {
    required List<BuzzPushSubscription> subscriptions,
    required int generation,
  }) => Future.error(buzzBackendUnavailable);

  Future<void> setPushNotificationsEnabled(String id, bool enabled) =>
      Future.error(buzzBackendUnavailable);

  Future<void> enforceAgeRestrictionOnPush() =>
      Future.error(buzzBackendUnavailable);

  Future<void> retryPendingPushLeaseTombstone(
    String id, {
    bool advanceGeneration = false,
  }) => Future.error(buzzBackendUnavailable);

  Future<void> renameCommunity(String id, String name) =>
      Future.error(buzzBackendUnavailable);
}

final communityListProvider =
    AsyncNotifierProvider<CommunityListNotifier, List<Community>>(
      CommunityListNotifier.new,
    );

/// The currently active community, derived from the stored active ID and
/// the community list.
final activeCommunityProvider = FutureProvider<Community?>(
  (ref) async => null,
);
