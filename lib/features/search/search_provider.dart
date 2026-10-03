// MODIFIED FOR RAIJU: search saved collab and relay chats locally, without
// querying the retained Buzz relay or user directory.

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../harness/harness.dart';
import '../../raiju/companion_provider.dart';
import '../channels/channel.dart';
import '../channels/channel_management_provider.dart';
import '../channels/channels_provider.dart';

@immutable
class SearchHit {
  final String eventId;
  final String content;
  final int kind;
  final String pubkey;
  final String? channelId;
  final String? channelName;
  final int createdAt;
  final double score;
  final List<List<String>> tags;
  final bool isLocal;

  const SearchHit({
    required this.eventId,
    required this.content,
    required this.kind,
    required this.pubkey,
    this.channelId,
    this.channelName,
    required this.createdAt,
    required this.score,
    this.tags = const [],
    this.isLocal = false,
  });

  factory SearchHit.fromJson(Map<String, dynamic> json) => SearchHit(
    eventId: json['event_id'] as String,
    content: json['content'] as String? ?? '',
    kind: json['kind'] as int? ?? 9,
    pubkey: json['pubkey'] as String,
    channelId: json['channel_id'] as String?,
    channelName: json['channel_name'] as String?,
    createdAt: json['created_at'] as int? ?? 0,
    score: (json['score'] as num?)?.toDouble() ?? 0.0,
    tags:
        (json['tags'] as List<dynamic>?)
            ?.map((t) => (t as List<dynamic>).map((e) => e as String).toList())
            .toList() ??
        const [],
  );
}

@immutable
class SearchState {
  final String query;
  final List<SearchHit> messageResults;
  final List<DirectoryUser> userResults;
  final List<Channel> channelResults;
  final bool isLoading;
  final String? error;

  const SearchState({
    this.query = '',
    this.messageResults = const [],
    this.userResults = const [],
    this.channelResults = const [],
    this.isLoading = false,
    this.error,
  });

  const SearchState.initial()
    : query = '',
      messageResults = const [],
      userResults = const [],
      channelResults = const [],
      isLoading = false,
      error = null;

  SearchState copyWith({
    String? query,
    List<SearchHit>? messageResults,
    List<DirectoryUser>? userResults,
    List<Channel>? channelResults,
    bool? isLoading,
    String? error,
  }) => SearchState(
    query: query ?? this.query,
    messageResults: messageResults ?? this.messageResults,
    userResults: userResults ?? this.userResults,
    channelResults: channelResults ?? this.channelResults,
    isLoading: isLoading ?? this.isLoading,
    error: error ?? this.error,
  );
}

class SearchNotifier extends Notifier<SearchState> {
  @override
  SearchState build() {
    ref.listen(channelsProvider, (_, _) => _refreshResults());
    ref.listen(companionControllerProvider, (_, _) => _refreshResults());
    return const SearchState.initial();
  }

  void search(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      clear();
      return;
    }
    _searchLocal(trimmed);
  }

  void _refreshResults() {
    if (state.query.isNotEmpty) _searchLocal(state.query);
  }

  void _searchLocal(String query) {
    final lowerQuery = query.toLowerCase();
    final controller = ref.read(companionControllerProvider);
    final chats = controller.chats;
    final channels =
        ref.read(channelsProvider).asData?.value ??
        chats.map(channelFromChatThread).toList(growable: false);
    final channelById = {for (final channel in channels) channel.id: channel};
    final matches = channels
        .where((channel) {
          return channel.name.toLowerCase().contains(lowerQuery) ||
              channel.description.toLowerCase().contains(lowerQuery);
        })
        .toList(growable: false);
    final hits = <SearchHit>[];
    for (final chat in chats) {
      final channel = channelById[chat.id];
      if (channel == null) continue;
      for (final message in chat.snapshot.messages) {
        if (message.role != MessageRole.user &&
            message.role != MessageRole.assistant) {
          continue;
        }
        final content = message.prose ?? message.text;
        if (!content.toLowerCase().contains(lowerQuery)) continue;
        hits.add(
          SearchHit(
            eventId: '${chat.id}:${message.id}',
            content: content,
            kind: 9,
            pubkey:
                message.author ??
                (message.role == MessageRole.user ? 'You' : 'oh-my-pi'),
            channelId: chat.id,
            channelName: channel.name,
            createdAt:
                (message.timestamp ?? chat.createdAt).millisecondsSinceEpoch ~/
                1000,
            score: 0,
            isLocal: true,
          ),
        );
      }
    }
    hits.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    state = SearchState(
      query: query,
      channelResults: matches,
      messageResults: hits,
    );
  }

  void clear() {
    state = const SearchState.initial();
  }
}

final searchProvider = NotifierProvider<SearchNotifier, SearchState>(
  SearchNotifier.new,
);
