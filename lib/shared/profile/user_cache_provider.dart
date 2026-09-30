// MODIFIED FOR RAIJU: profile cache remains a local display cache and never
// queries the retained Buzz relay backend.

import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../relay/relay.dart';
import 'user_profile.dart';
import 'profile_event_parser.dart';

/// In-memory cache of user profiles, fetched in batches from the relay.
///
/// Lookups requested via [get] or [preload] are coalesced into a single
/// kind:0 batch query (NIP-01 `authors` filter) every 50ms. Larger requests
/// drain sequentially in pages bounded by the relay response limit.
class UserCacheNotifier extends Notifier<Map<String, UserProfile>> {
  final Map<String, ({int createdAt, String eventId})> _profileEventOrders = {};

  @override
  Map<String, UserProfile> build() => {};

  /// Request a profile for [pubkey]. Returns immediately from cache if
  /// available, otherwise schedules a batch fetch.
  UserProfile? get(String pubkey) => state[pubkey.toLowerCase()];

  /// Stores a profile that was fetched or updated outside the batch loader.
  void put(UserProfile profile) {
    state = {...state, profile.pubkey.toLowerCase(): profile};
  }

  /// Preload profiles for a list of pubkeys (e.g. channel members).
  /// Returns whether the batch completed successfully.
  Future<bool> preload(List<String> pubkeys) async => false;

  /// Force-refresh profiles for identity-sensitive gates.
  ///
  /// Unlike [preload], this fetches cached pubkeys too so stale human profiles
  /// cannot be trusted after a verified agent-owner profile was published.
  Future<bool> refresh(List<String> pubkeys) async => false;

  /// Applies a live kind:0 profile event to the cache.
  ///
  /// Surfaces that keep a participant-scoped profile subscription can use this
  /// to update names and avatars without discarding the rest of the cache.
  void cacheProfileEvent(NostrEvent event) {
    if (event.kind != 0) return;
    final updated = Map<String, UserProfile>.from(state);
    if (_cacheProfileEvent(event, updated)) state = updated;
  }



  bool _isNewer(String pubkey, int createdAt, String eventId) {
    final current = _profileEventOrders[pubkey];
    return current == null ||
        createdAt > current.createdAt ||
        (createdAt == current.createdAt &&
            eventId.compareTo(current.eventId) < 0);
  }

  bool _cacheProfileEvent(NostrEvent event, Map<String, UserProfile> profiles) {
    if (event.kind != 0) return false;
    final pubkey = event.pubkey.toLowerCase();
    if (!_isNewer(pubkey, event.createdAt, event.id)) return false;
    profiles[pubkey] = parseProfileEvent(event).profile;
    _profileEventOrders[pubkey] = (
      createdAt: event.createdAt,
      eventId: event.id,
    );
    return true;
  }
}

/// Profile history parser, isolated from provider state so batch completion can
/// be delayed independently of relay delivery.
final profileEventBatchParserProvider =
    Provider<Future<List<ParsedProfileEvent>> Function(List<NostrEvent>)>(
      (ref) => parseProfileEventBatch,
    );

final userCacheProvider =
    NotifierProvider<UserCacheNotifier, Map<String, UserProfile>>(
      UserCacheNotifier.new,
    );
