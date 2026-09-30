import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../raiju/companion_provider.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/modal_presentation.dart';
import '../spark.dart';
import 'spark_level_visualizer.dart';
import 'spark_transcript_sheet.dart';

class SparkModalRouteObserver extends NavigatorObserver {
  int _modalCount = 0;
  final ValueNotifier<bool> hasModalRoute = ValueNotifier(false);

  void _update(Route<dynamic>? route, int delta) {
    if (route is! PopupRoute<dynamic>) return;
    _modalCount = (_modalCount + delta).clamp(0, 1 << 20);
    hasModalRoute.value = _modalCount > 0;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _update(route, 1);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _update(route, -1);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _update(route, -1);
  }
}

/// Global, additive Spark surface. The expanded strip reserves layout space;
/// minimizing keeps the existing application fully interactive underneath.
class SparkShell extends ConsumerStatefulWidget {
  const SparkShell({
    super.key,
    required this.child,
    this.navigatorKey,
    this.modalRouteObserver,
  });

  final Widget child;
  final GlobalKey<NavigatorState>? navigatorKey;
  final SparkModalRouteObserver? modalRouteObserver;

  @override
  ConsumerState<SparkShell> createState() => _SparkShellState();
}

class _SparkShellState extends ConsumerState<SparkShell>
    with WidgetsBindingObserver {
  bool _minimized = false;
  bool _modalActive = false;
  SparkController? _controller;
  bool _startRequested = false;
  Future<void>? _stopInFlight;
  // Keep the display-only meter freshness clock alive while the strip is
  // minimized; remounting with a stale positive scalar must not restart it.
  final GlobalKey _meterKey = GlobalKey();
  List<SparkTranscriptEntry> _previousTranscript = const [];
  SparkTranscriptEntry? _visibleUserPartial;
  String? _partialChatId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.modalRouteObserver?.hasModalRoute.addListener(_onModalChanged);
  }

  void _onModalChanged() {
    if (mounted) {
      setState(() {
        _modalActive = widget.modalRouteObserver?.hasModalRoute.value ?? false;
      });
    }
  }

  @override
  void dispose() {
    widget.modalRouteObserver?.hasModalRoute.removeListener(_onModalChanged);
    WidgetsBinding.instance.removeObserver(this);
    _stopIfActive();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final connecting =
        _startRequested || _controller?.snapshot.phase == SparkPhase.connecting;
    if (state == AppLifecycleState.detached ||
        ((state == AppLifecycleState.paused ||
                state == AppLifecycleState.hidden) &&
            (defaultTargetPlatform != TargetPlatform.iOS || connecting))) {
      _stopIfActive();
    }
  }

  void _stopIfActive() {
    final controller = _controller;
    if (controller == null || _stopInFlight != null) return;
    if (!_startRequested &&
        (controller.snapshot.phase == SparkPhase.idle ||
            controller.snapshot.phase == SparkPhase.error)) {
      return;
    }
    // A startup can still be awaiting credentials before its phase changes.
    // Invalidate that request and share one stop across lifecycle transitions.
    _startRequested = false;
    final stopping = controller.stop().catchError((Object _) {});
    _stopInFlight = stopping;
    unawaited(
      stopping.whenComplete(() {
        if (identical(_stopInFlight, stopping)) _stopInFlight = null;
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(sparkControllerProvider);
    _controller = controller;
    final viewedChatId = ref.watch(viewedCompanionChatProvider);
    final snapshot = controller.snapshot;
    final partial = _liveUserPartial(snapshot);
    final partialStyle = context.textTheme.labelSmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    if (_minimized) {
      return Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          Offstage(
            offstage: true,
            child: TickerMode(
              enabled: false,
              child: SparkLevelVisualizer(
                key: _meterKey,
                inputLevel: snapshot.inputLevel,
                outputLevel: snapshot.outputLevel,
                levelRevision: snapshot.levelRevision,
                active:
                    snapshot.phase != SparkPhase.idle &&
                    snapshot.phase != SparkPhase.error,
              ),
            ),
          ),
          PositionedDirectional(
            top: MediaQuery.sizeOf(context).height * .32,
            end: Grid.xs,
            child: IgnorePointer(
              ignoring: _modalActive,
              child: ExcludeSemantics(
                excluding: _modalActive,
                child: _MinimizedSparkControl(
                  snapshot: snapshot,
                  onExpand: () => setState(() => _minimized = false),
                  onStop: snapshot.phase == SparkPhase.idle
                      ? null
                      : _stopIfActive,
                  onMic: _canUseMic(snapshot.phase)
                      ? () => unawaited(
                          controller.setMicEnabled(!snapshot.micEnabled),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        ColoredBox(
          color: context.colors.surface,
          child: SafeArea(
            bottom: false,
            child: IgnorePointer(
              ignoring: _modalActive,
              child: ExcludeSemantics(
                excluding: _modalActive,
                child: Material(
                  key: const ValueKey('spark-strip'),
                  color: context.colors.surface,
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Grid.gutter,
                      Grid.xxs,
                      Grid.xs,
                      Grid.xxs,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => _showTranscript(context),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 2,
                                  ),
                                  child: LayoutBuilder(
                                    builder: (context, constraints) => Row(
                                      children: [
                                        Container(
                                          width: 8,
                                          height: 8,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: _phaseColor(
                                              context,
                                              snapshot.phase,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: Grid.xs),
                                        SizedBox(
                                          width: 58,
                                          child: Text(
                                            'Spark',
                                            style: context.textTheme.labelLarge
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                        ),
                                        Expanded(
                                          child: SparkLevelVisualizer(
                                            key: _meterKey,
                                            inputLevel: snapshot.inputLevel,
                                            outputLevel: snapshot.outputLevel,
                                            levelRevision:
                                                snapshot.levelRevision,
                                            active:
                                                snapshot.phase !=
                                                    SparkPhase.idle &&
                                                snapshot.phase !=
                                                    SparkPhase.error,
                                          ),
                                        ),
                                        if (constraints.maxWidth >= 220) ...[
                                          const SizedBox(width: Grid.xs),
                                          Flexible(
                                            child: Text(
                                              _phaseLabel(snapshot.phase),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: context
                                                  .textTheme
                                                  .labelSmall
                                                  ?.copyWith(
                                                    color: context
                                                        .colors
                                                        .onSurfaceVariant,
                                                  ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (snapshot.phase == SparkPhase.idle ||
                                snapshot.phase == SparkPhase.error)
                              IconButton(
                                key: const ValueKey('spark-start'),
                                tooltip: viewedChatId == null
                                    ? 'Open a chat before starting Spark'
                                    : 'Start live Spark voice',
                                onPressed: viewedChatId == null
                                    ? null
                                    : () {
                                        _startRequested = true;
                                        unawaited(
                                          controller
                                              .start(chatId: viewedChatId)
                                              .catchError((Object _) {})
                                              .whenComplete(
                                                () => _startRequested = false,
                                              ),
                                        );
                                      },
                                icon: const Icon(Icons.play_arrow_rounded),
                              )
                            else ...[
                              IconButton(
                                key: const ValueKey('spark-mic-toggle'),
                                tooltip: snapshot.micEnabled
                                    ? 'Mute Spark microphone'
                                    : 'Enable Spark microphone',
                                onPressed: !_canUseMic(snapshot.phase)
                                    ? null
                                    : () => unawaited(
                                        controller
                                            .setMicEnabled(!snapshot.micEnabled)
                                            .catchError((Object _) {}),
                                      ),
                                icon: Icon(
                                  snapshot.micEnabled
                                      ? Icons.mic_rounded
                                      : Icons.mic_off_rounded,
                                ),
                              ),
                              IconButton(
                                key: const ValueKey('spark-stop'),
                                tooltip: 'Stop live Spark voice',
                                onPressed: _stopIfActive,
                                icon: const Icon(Icons.stop_rounded),
                              ),
                            ],
                            IconButton(
                              key: const ValueKey('spark-minimize'),
                              tooltip: 'Minimize Spark controls',
                              onPressed: () =>
                                  setState(() => _minimized = true),
                              icon: const Icon(Icons.keyboard_arrow_up_rounded),
                            ),
                          ],
                        ),
                        if (snapshot.phase != SparkPhase.idle &&
                            snapshot.phase != SparkPhase.error)
                          Padding(
                            padding: const EdgeInsets.only(top: Grid.xxs),
                            child: partial == null
                                ? ExcludeSemantics(
                                    child: Text(
                                      ' ',
                                      maxLines: 1,
                                      style: partialStyle,
                                    ),
                                  )
                                : Semantics(
                                    label: 'Recognizing speech: $partial',
                                    liveRegion: true,
                                    child: ExcludeSemantics(
                                      child: Text(
                                        'You: $partial',
                                        key: const ValueKey(
                                          'spark-live-transcript',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: partialStyle,
                                      ),
                                    ),
                                  ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: widget.child,
            ),
          ),
        ),
      ],
    );
  }

  // A provider may update an active turn in place after another role starts.
  // Track changed entries rather than assuming their list positions are time.
  String? _liveUserPartial(SparkSnapshot snapshot) {
    if (snapshot.phase == SparkPhase.idle ||
        snapshot.phase == SparkPhase.error ||
        snapshot.boundChatId != _partialChatId) {
      _visibleUserPartial = null;
    }
    _partialChatId = snapshot.boundChatId;
    final entries = snapshot.transcript;
    if (snapshot.phase != SparkPhase.idle &&
        snapshot.phase != SparkPhase.error) {
      SparkTranscriptEntry? changedUser;
      var speechMovedOn = false;
      for (var index = 0; index < entries.length; index++) {
        final entry = entries[index];
        if (index < _previousTranscript.length &&
            identical(entry, _previousTranscript[index])) {
          continue;
        }
        if (entry.role == SparkTranscriptRole.user && !entry.isFinal) {
          changedUser = entry;
        } else {
          speechMovedOn = true;
        }
      }
      // Batched assistant/final updates have no reliable intra-frame order.
      // Hide ambiguous speech rather than leaving stale user words visible.
      if (speechMovedOn) {
        _visibleUserPartial = null;
      } else if (changedUser != null) {
        _visibleUserPartial = changedUser;
      }
    }
    _previousTranscript = entries;
    final text = _visibleUserPartial?.text.trim();
    if (text == null || text.isEmpty) return null;
    const limit = 160;
    final characters = text.characters;
    return characters.length > limit ? '…${characters.takeLast(limit)}' : text;
  }

  void _showTranscript(BuildContext context) {
    final routeContext =
        widget.navigatorKey?.currentState?.overlay?.context ?? context;
    unawaited(
      showBuzzModalBottomSheet<void>(
        context: routeContext,
        useRootNavigator: true,
        isScrollControlled: true,
        title: 'Spark',
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(routeContext).height * .88,
        ),
        builder: (_) => const SparkTranscriptSheet(),
      ),
    );
  }
}

class _MinimizedSparkControl extends StatelessWidget {
  const _MinimizedSparkControl({
    required this.snapshot,
    required this.onExpand,
    required this.onStop,
    required this.onMic,
  });

  final SparkSnapshot snapshot;
  final VoidCallback onExpand;
  final VoidCallback? onStop;
  final VoidCallback? onMic;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('spark-minimized-button'),
      color: context.colors.surfaceContainerHigh,
      elevation: 4,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Expand Spark controls',
            onPressed: onExpand,
            icon: const Icon(Icons.graphic_eq_rounded),
          ),
          if (onMic != null)
            IconButton(
              key: const ValueKey('spark-mic-toggle'),
              tooltip: snapshot.micEnabled
                  ? 'Mute Spark microphone'
                  : 'Enable Spark microphone',
              onPressed: onMic,
              icon: Icon(
                snapshot.micEnabled ? Icons.mic_rounded : Icons.mic_off_rounded,
              ),
            ),
          if (onStop != null)
            IconButton(
              key: const ValueKey('spark-stop'),
              tooltip: 'Stop live Spark voice',
              onPressed: onStop,
              icon: const Icon(Icons.stop_rounded),
            ),
        ],
      ),
    );
  }
}

bool _canUseMic(SparkPhase phase) =>
    phase != SparkPhase.idle &&
    phase != SparkPhase.connecting &&
    phase != SparkPhase.error;

String _phaseLabel(SparkPhase phase) => switch (phase) {
  SparkPhase.idle => 'Ready',
  SparkPhase.connecting => 'Connecting',
  SparkPhase.listening => 'Listening',
  SparkPhase.working => 'Thinking',
  SparkPhase.speaking => 'Speaking',
  SparkPhase.muted => 'Muted',
  SparkPhase.error => 'Needs attention',
};

Color _phaseColor(BuildContext context, SparkPhase phase) => switch (phase) {
  SparkPhase.error => context.colors.error,
  SparkPhase.idle => context.colors.outline,
  SparkPhase.muted => context.colors.tertiary,
  _ => context.colors.primary,
};
