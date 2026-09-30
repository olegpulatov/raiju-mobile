// Modified for Raiju: original app shell opens locally without Buzz services.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'features/channels/channel.dart';
import 'features/channels/channel_management_provider.dart';
import 'features/channels/channels_provider.dart';
import 'features/home/home_page.dart';
import 'features/invites/invite_join_provider.dart';
import 'features/channels/voice_note_recording.dart';
import 'features/profile/settings_profile_header.dart';
import 'features/settings/settings_page.dart';
import 'shared/auth/auth.dart';
import 'shared/emoji/emoji_burst.dart';
import 'shared/relay/relay.dart';
import 'shared/theme/theme.dart';
import 'raiju/companion_provider.dart';
import 'spark/widgets/spark_shell.dart';

const _starterChannelNamespace = '3ce33bea-8f09-5f1b-9c85-8a7d2659e6b0';

const _starterChannels = [
  (slug: 'general', description: 'General conversation and community updates.'),
  (
    slug: 'welcome-everyone',
    description: 'Say hi, ask a question, or share what brought you here.',
  ),
];

final _inviteRelayConnectedProvider = FutureProvider.family<void, String>((
  ref,
  expectedRelayUrl,
) async {
  final currentConfig = ref.read(relayConfigProvider);
  if (currentConfig.baseUrl != expectedRelayUrl) {
    throw StateError('Active community changed before invite recovery');
  }
  if (ref.read(relaySessionProvider).status == SessionStatus.connected) return;

  final connected = Completer<void>();
  ref.listen(relaySessionProvider, (_, next) {
    if (connected.isCompleted) return;
    if (ref.read(relayConfigProvider).baseUrl != expectedRelayUrl) {
      connected.completeError(
        StateError('Active community changed during invite recovery'),
      );
    } else if (next.status == SessionStatus.connected) {
      connected.complete();
    }
  });
  await connected.future;
});

/// App-level bridge from invite joining to the channels feature.
class MobileInviteJoinRecovery implements InviteJoinRecovery {
  final Future<List<Channel>> Function() _loadChannels;
  final Future<Channel> Function({
    required String channelId,
    required String name,
    required String channelType,
    required String visibility,
    String? description,
    int? ttlSeconds,
  })
  _createChannel;
  final Future<void> Function(String channelId) _joinChannel;
  final String _relayHttpOrigin;
  final bool Function() _isScopeCurrent;

  /// Creates recovery from channel-loading, creation, and join operations.
  MobileInviteJoinRecovery({
    required Future<List<Channel>> Function() loadChannels,
    required Future<Channel> Function({
      required String channelId,
      required String name,
      required String channelType,
      required String visibility,
      String? description,
      int? ttlSeconds,
    })
    createChannel,
    required Future<void> Function(String channelId) joinChannel,
    required String relayHttpOrigin,
    bool Function()? isScopeCurrent,
  }) : _loadChannels = loadChannels,
       _createChannel = createChannel,
       _joinChannel = joinChannel,
       _relayHttpOrigin = relayHttpOrigin,
       _isScopeCurrent = isScopeCurrent ?? _alwaysCurrent;

  /// Ensures memberships in the same public starter channels as desktop.
  ///
  /// All starter work is fenced to the community and identity that started it.
  /// A partial setup remains recoverable, so a failed operation deliberately
  /// propagates to the invite flow instead of being reported as success.
  @override
  Future<String?> ensureStarterChannels() async {
    _ensureScopeCurrent();
    var channels = await _loadChannels();
    _ensureScopeCurrent();
    String? welcomeEveryoneId;

    for (final starter in _starterChannels) {
      _ensureScopeCurrent();
      var channel = _findStarterChannel(channels, starter.slug);
      if (channel == null) {
        final channelId = desktopStarterChannelId(
          relayHttpOrigin: _relayHttpOrigin,
          slug: starter.slug,
        );
        try {
          channel = await _createChannel(
            channelId: channelId,
            name: starter.slug,
            channelType: 'stream',
            visibility: 'open',
            description: starter.description,
          );
          _ensureScopeCurrent();
        } catch (error) {
          if (!_isDuplicateChannelError(error)) rethrow;
          _ensureScopeCurrent();
          channels = await _loadChannels();
          _ensureScopeCurrent();
          channel =
              _findStarterChannel(channels, starter.slug) ??
              channels
                  .where((candidate) => candidate.id == channelId)
                  .firstOrNull;
          if (channel == null) rethrow;
        }
      }

      _ensureScopeCurrent();
      if (!channel.isMember) {
        await _joinChannel(channel.id);
        _ensureScopeCurrent();
      }
      if (starter.slug == 'welcome-everyone') {
        welcomeEveryoneId = channel.id;
      }
    }

    return welcomeEveryoneId;
  }

  static bool _alwaysCurrent() => true;

  void _ensureScopeCurrent() {
    if (!_isScopeCurrent()) {
      throw StateError('Active community changed during invite recovery');
    }
  }
}

Channel? _findStarterChannel(List<Channel> channels, String name) {
  final normalizedName = name.trim().toLowerCase();
  return channels
      .where(
        (channel) =>
            channel.name.trim().toLowerCase() == normalizedName &&
            channel.isStream &&
            channel.visibility == 'open' &&
            !channel.isArchived,
      )
      .firstOrNull;
}

bool _isDuplicateChannelError(Object error) =>
    error.toString().contains('duplicate: channel already exists');

/// Returns desktop's deterministic per-relay UUID for a public starter.
@visibleForTesting
String desktopStarterChannelId({
  required String relayHttpOrigin,
  required String slug,
}) {
  final scope = relayHttpOrigin.trim().replaceFirst(RegExp(r'/+$'), '');
  return const Uuid().v5(
    _starterChannelNamespace,
    'starter-channel:v1:$scope:$slug',
  );
}

/// Builds one fresh, identity-scoped invite recovery against the app container.
InviteJoinRecovery buildMobileInviteJoinRecovery(
  Ref ref,
  InviteJoinRecoveryScope scope,
) {
  final expectedConfig = ref.read(relayConfigProvider);
  if (expectedConfig.baseUrl != scope.relayHttpOrigin ||
      expectedConfig.nsec != scope.nsec) {
    throw StateError('Active community changed before invite recovery');
  }
  final channelActions = ref.read(channelActionsProvider);

  bool isScopeCurrent() {
    final currentConfig = ref.read(relayConfigProvider);
    return currentConfig.baseUrl == scope.relayHttpOrigin &&
        currentConfig.nsec == scope.nsec;
  }

  void ensureScopeCurrent() {
    if (!isScopeCurrent()) {
      throw StateError('Active community changed during invite recovery');
    }
  }

  return MobileInviteJoinRecovery(
    loadChannels: () async {
      ensureScopeCurrent();
      await ref.read(activeCommunityProvider.future);
      ensureScopeCurrent();
      await ref
          .read(_inviteRelayConnectedProvider(scope.relayHttpOrigin).future)
          .timeout(const Duration(seconds: 15));
      ensureScopeCurrent();
      await ref.read(channelsProvider.notifier).refresh(fetchDirectory: true);
      ensureScopeCurrent();
      final channels = await ref.read(channelsProvider.future);
      ensureScopeCurrent();
      return channels;
    },
    createChannel:
        ({
          required channelId,
          required name,
          required channelType,
          required visibility,
          description,
          ttlSeconds,
        }) => channelActions.createChannel(
          channelId: channelId,
          name: name,
          channelType: channelType,
          visibility: visibility,
          description: description,
          ttlSeconds: ttlSeconds,
        ),
    joinChannel: channelActions.joinChannel,
    relayHttpOrigin: scope.relayHttpOrigin,
    isScopeCurrent: isScopeCurrent,
  );
}

final _mobileRootNavigatorKey = GlobalKey<NavigatorState>();
final _sparkModalRouteObserver = SparkModalRouteObserver();

class App extends HookConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final communityTheme = ref.watch(communityThemeProvider);
    final themeMode = communityTheme.mode;
    final accentIndex = effectiveAccentIndex(
      communityTheme.theme,
      communityTheme.accent,
    );
    final schemeName = communityTheme.theme;
    final controller = ref.watch(companionControllerProvider);
    final themeNotifier = ref.read(communityThemeProvider.notifier);
    useEffect(() {
      void saveBeforeSuspension() {
        unawaited(
          controller.flush().catchError((Object _) {
            // Controller retains a visible storageError; lifecycle cannot await.
          }),
        );
        unawaited(themeNotifier.flush());
      }

      final lifecycle = AppLifecycleListener(
        onInactive: saveBeforeSuspension,
        onPause: saveBeforeSuspension,
      );
      return lifecycle.dispose;
    }, [controller, themeNotifier]);

    final resolved = resolveSchemes(schemeName, themeMode);
    final lightScheme = applyAccent(resolved.light, accentIndex);
    final darkScheme = applyAccent(resolved.dark, accentIndex);
    // Light/Dark modes pin the brightness; System leaves it null so Flutter
    // follows the OS across the selected theme and its pair.
    final effectiveMode = resolved.forcedMode ?? themeMode;

    // Derive the gradient from the themes that produced each color scheme.
    // This keeps fallbacks and pinned brightness changes aligned with the
    // rendered palette rather than the raw persisted selection.
    final buzzLightGradient = buzzTopSectionGradient(
      resolved.lightTheme?.name ?? '',
      lightScheme.brightness,
    );
    final buzzDarkGradient = buzzTopSectionGradient(
      resolved.darkTheme?.name ?? '',
      darkScheme.brightness,
    );

    // Buzz auth, relay, push, badge and deep-link bootstrap is intentionally
    // absent. Retained screens consume local companion state instead.

    return MaterialApp(
      navigatorKey: _mobileRootNavigatorKey,
      navigatorObservers: [
        voiceNoteRouteObserver,
        _sparkModalRouteObserver,
      ],
      title: 'Raiju',
      theme: AppTheme.light(
        colorScheme: lightScheme,
        topSectionGradient: buzzLightGradient,
      ),
      darkTheme: AppTheme.dark(
        colorScheme: darkScheme,
        topSectionGradient: buzzDarkGradient,
      ),
      themeMode: effectiveMode,
      builder: (context, child) => _SparkAppOverlay(
        child: AppMarkdownTheme(
          child: EmojiBurstOverlay(
            child: SparkShell(
              navigatorKey: _mobileRootNavigatorKey,
              modalRouteObserver: _sparkModalRouteObserver,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
      home: HomePage(
        settingsPageBuilder: _buildSettingsPage,
        hasUnreadInbox: false,
      ),
    );
  }
}

Widget _buildSettingsPage(BuildContext context) => const _SettingsPageContent();

class _SettingsPageContent extends ConsumerWidget {
  const _SettingsPageContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsPage(profileHeader: const SettingsProfileHeader());
  }
}

class _SparkAppOverlay extends StatefulWidget {
  const _SparkAppOverlay({required this.child});
  final Widget child;

  @override
  State<_SparkAppOverlay> createState() => _SparkAppOverlayState();
}

class _SparkAppOverlayState extends State<_SparkAppOverlay> {
  late final OverlayEntry _entry = OverlayEntry(builder: (_) => widget.child);

  @override
  void didUpdateWidget(covariant _SparkAppOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry.markNeedsBuild();
  }


  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);
}
