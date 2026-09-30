// Modified for Raiju: companion connection and host-question states use the
// retained channel banner/card styling without invoking Buzz relay state.

part of '../channel_detail_page.dart';

// Retained original read-only channel notice while Buzz state is dormant.
// ignore: unused_element
class _ReadOnlyNotice extends StatelessWidget {
  final Channel channel;

  const _ReadOnlyNotice({required this.channel});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.only(
        left: Grid.gutter,
        right: Grid.gutter,
        top: Grid.xxs,
        bottom: MediaQuery.viewPaddingOf(context).bottom + Grid.xxs,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.colors.outlineVariant)),
        color: context.colors.surface,
      ),
      child: Text(
        channel.isArchived
            ? 'This ${channel.isForum ? 'forum' : 'channel'} is archived and read-only on mobile.'
            : 'Join this ${channel.isForum ? 'forum' : 'channel'} from Manage to participate.',
        style: context.textTheme.bodySmall?.copyWith(
          color: context.colors.onSurfaceVariant,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _HeaderEphemeralBadge extends StatelessWidget {
  final Channel channel;

  const _HeaderEphemeralBadge({required this.channel});

  @override
  Widget build(BuildContext context) {
    final display = ephemeralChannelDisplay(channel);
    if (display == null) return const SizedBox.shrink();

    return Tooltip(
      message: display.tooltipLabel,
      child: Icon(
        LucideIcons.clockFading,
        key: const Key('chat-ephemeral-badge'),
        size: 16,
        color: context.colors.onSurfaceVariant,
      ),
    );
  }
}

// Retained original message loading skeleton for visual continuity.
// ignore: unused_element
class _MessageTimelineSkeleton extends StatelessWidget {
  final double appBarTitleContentHeight;
  final SessionStatus status;

  const _MessageTimelineSkeleton({
    required this.appBarTitleContentHeight,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final semanticsLabel = switch (status) {
      SessionStatus.connecting => 'Connecting',
      SessionStatus.reconnecting => 'Reconnecting',
      SessionStatus.connected || SessionStatus.disconnected => 'Loading',
    };
    return Semantics(
      key: const Key('channel-detail-connection-skeleton'),
      liveRegion: true,
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: ListView.separated(
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            Grid.gutter,
            frostedAppBarHeight(
                  context,
                  titleContentHeight: appBarTitleContentHeight,
                ) +
                Grid.xs,
            Grid.gutter,
            Grid.xs,
          ),
          itemCount: 4,
          separatorBuilder: (_, _) => const SizedBox(height: Grid.xs),
          itemBuilder: (_, index) => _MessageSkeletonRow(index: index),
        ),
      ),
    );
  }
}

class _MessageSkeletonRow extends StatelessWidget {
  final int index;

  const _MessageSkeletonRow({required this.index});

  @override
  Widget build(BuildContext context) {
    const authorWidths = <double>[112, 96, 128, 80];
    const lineWidths = <List<double>>[
      [280, 224],
      [272, 184],
      [232],
      [288, 216],
    ];
    final availableWidth = MediaQuery.sizeOf(context).width - 88;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SkeletonBar(
          width: 36,
          height: 36,
          borderRadius: BorderRadius.circular(Radii.full),
        ),
        const SizedBox(width: Grid.xxs),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SkeletonBar(width: authorWidths[index], height: 15),
                  const SizedBox(width: Grid.xxs),
                  const SkeletonBar(width: 40, height: 12),
                ],
              ),
              const SizedBox(height: Grid.half),
              for (final width in lineWidths[index]) ...[
                SkeletonBar(width: min(width, availableWidth), height: 16),
                const SizedBox(height: Grid.half),
              ],
              const Row(
                children: [
                  SkeletonBar(width: 32, height: 16),
                  SizedBox(width: Grid.xs),
                  SkeletonBar(width: 32, height: 16),
                  SizedBox(width: Grid.xs),
                  SkeletonBar(width: 32, height: 16),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// Retained original forum loading skeleton for visual continuity.
// ignore: unused_element
class _ForumConnectionSkeleton extends StatelessWidget {
  final SessionStatus status;

  const _ForumConnectionSkeleton({required this.status});

  @override
  Widget build(BuildContext context) {
    final semanticsLabel = switch (status) {
      SessionStatus.connecting => 'Connecting',
      SessionStatus.reconnecting => 'Reconnecting',
      SessionStatus.connected || SessionStatus.disconnected => 'Loading',
    };
    return Semantics(
      key: const Key('forum-connection-skeleton'),
      liveRegion: true,
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: IgnorePointer(
          child: ExcludeFocus(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.colors.surface,
                borderRadius: BorderRadius.circular(Radii.lg),
                border: Border.all(color: context.colors.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(Grid.twelve),
                child: SkeletonShimmer(
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          SkeletonBar(
                            width: 28,
                            height: 28,
                            borderRadius: BorderRadius.all(
                              Radius.circular(Radii.full),
                            ),
                          ),
                          SizedBox(width: Grid.xxs),
                          SkeletonBar(width: 112, height: 14),
                        ],
                      ),
                      SizedBox(height: Grid.xxs),
                      SkeletonBar(width: 240, height: 14),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CompanionStatusBanner extends StatelessWidget {
  const _CompanionStatusBanner({
    required this.snapshot,
    this.storageError,
    this.promptTrackingError,
    required this.chatAvailable,
    this.onRetry,
    this.onDisconnect,
    this.onStop,
  });

  final HarnessSnapshot snapshot;
  final bool chatAvailable;
  final String? storageError;
  final String? promptTrackingError;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onDisconnect;
  final Future<void> Function()? onStop;

  @override
  Widget build(BuildContext context) {
    final persistenceError = storageError?.trim();
    final trackingError = promptTrackingError?.trim();
    final error = snapshot.error?.trim();
    final needsBanner =
        (persistenceError != null && persistenceError.isNotEmpty) ||
        (trackingError != null && trackingError.isNotEmpty) ||
        snapshot.readOnly ||
        snapshot.isStreaming ||
        snapshot.phase != ConnectionPhase.live ||
        (error != null && error.isNotEmpty);
    if (!needsBanner) return const SizedBox.shrink();

    final label = !chatAvailable
        ? 'This saved companion chat is unavailable.'
        : persistenceError != null && persistenceError.isNotEmpty
        ? persistenceError
        : trackingError != null && trackingError.isNotEmpty
        ? trackingError
        : error != null && error.isNotEmpty
        ? error
        : snapshot.isStreaming
        ? (snapshot.activity.trim().isEmpty
              ? 'Assistant is responding…'
              : snapshot.activity.trim())
        : switch (snapshot.phase) {
            ConnectionPhase.disconnected =>
              'Disconnected. This chat will not reconnect until you retry.',
            ConnectionPhase.connecting => 'Connecting to the host…',
            ConnectionPhase.syncing => 'Syncing the host transcript…',
            ConnectionPhase.reconnecting => 'Reconnecting to the host…',
            ConnectionPhase.ended => 'The host session has ended.',
            ConnectionPhase.error =>
              'The host could not be reached. Your transcript is still available.',
            ConnectionPhase.live when snapshot.readOnly =>
              'This link is read only. Sending and stopping are disabled.',
            ConnectionPhase.live => '',
          };

    return Material(
      color: context.colors.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Grid.gutter,
            vertical: Grid.xxs,
          ),
          child: Row(
            children: [
              Icon(
                snapshot.readOnly
                    ? LucideIcons.lock
                    : snapshot.isStreaming
                    ? LucideIcons.sparkles
                    : LucideIcons.wifiOff,
                size: 18,
                color: error == null && trackingError == null
                    ? context.colors.onSurfaceVariant
                    : context.colors.error,
              ),
              const SizedBox(width: Grid.xs),
              Expanded(
                child: Text(
                  label,
                  key: const ValueKey('companion-status-message'),
                  style: context.textTheme.bodySmall?.copyWith(
                    color: error == null && trackingError == null
                        ? context.colors.onSurfaceVariant
                        : context.colors.error,
                  ),
                ),
              ),
              if (onStop != null)
                TextButton(
                  key: const ValueKey('companion-stop'),
                  onPressed: () => unawaited(onStop!()),
                  child: const Text('Stop'),
                ),
              if (onRetry != null &&
                  snapshot.phase != ConnectionPhase.live &&
                  snapshot.phase != ConnectionPhase.connecting &&
                  snapshot.phase != ConnectionPhase.syncing &&
                  snapshot.phase != ConnectionPhase.reconnecting)
                TextButton(
                  key: const ValueKey('companion-retry'),
                  onPressed: () => unawaited(onRetry!()),
                  child: const Text('Retry'),
                ),
              if (onDisconnect != null &&
                  snapshot.phase != ConnectionPhase.disconnected)
                IconButton(
                  key: const ValueKey('companion-disconnect'),
                  tooltip: 'Disconnect',
                  onPressed: () => unawaited(onDisconnect!()),
                  icon: const Icon(LucideIcons.wifiOff, size: 18),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompanionQuestionCard extends StatelessWidget {
  const _CompanionQuestionCard({
    required this.question,
    required this.remainingCount,
    required this.enabled,
    required this.onRespond,
  });

  final HarnessQuestion question;
  final int remainingCount;
  final Future<void> Function(String? value) onRespond;
  final bool enabled;

  Future<void> _openEditor(BuildContext context) async {
    final answer = await showBuzzDialog<String>(
      context: context,
      builder: (dialogContext) =>
          _CompanionQuestionEditorDialog(question: question),
    );
    if (answer != null) await onRespond(answer);
  }

  @override
  Widget build(BuildContext context) {
    final hasOptions = question.options.isNotEmpty;
    return Material(
      key: ValueKey('companion-question-${question.id}'),
      color: context.colors.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Grid.gutter,
          Grid.xs,
          Grid.gutter,
          Grid.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  LucideIcons.messageCircle,
                  size: 18,
                  color: context.colors.primary,
                ),
                const SizedBox(width: Grid.xs),
                Expanded(
                  child: Text(
                    question.title,
                    style: context.textTheme.titleSmall,
                  ),
                ),
                if (remainingCount > 0)
                  Text(
                    '+$remainingCount',
                    style: context.textTheme.labelSmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            if (question.helpText?.trim().isNotEmpty == true) ...[
              const SizedBox(height: Grid.half),
              Text(
                question.helpText!,
                style: context.textTheme.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: Grid.xs),
            Wrap(
              spacing: Grid.half,
              runSpacing: Grid.half,
              children: [
                for (final option in question.options)
                  OutlinedButton(
                    key: ValueKey(
                      'companion-question-${question.id}-${option.label}',
                    ),
                    onPressed: enabled
                        ? () => unawaited(onRespond(option.label))
                        : null,
                    child: Text(option.label),
                  ),
                if (!hasOptions)
                  FilledButton.tonalIcon(
                    key: const ValueKey('companion-question-open-editor'),
                    onPressed: enabled
                        ? () => unawaited(_openEditor(context))
                        : null,
                    icon: const Icon(LucideIcons.pencil, size: 16),
                    label: const Text('Answer'),
                  ),
                TextButton(
                  key: const ValueKey('companion-question-decline'),
                  onPressed: enabled
                      ? () => unawaited(onRespond(null))
                      : null,
                  child: const Text('Decline'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CompanionQuestionEditorDialog extends StatefulWidget {
  const _CompanionQuestionEditorDialog({required this.question});

  final HarnessQuestion question;

  @override
  State<_CompanionQuestionEditorDialog> createState() =>
      _CompanionQuestionEditorDialogState();
}

class _CompanionQuestionEditorDialogState
    extends State<_CompanionQuestionEditorDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.question.prefill);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.question.title),
      content: TextField(
        key: const ValueKey('companion-question-editor'),
        controller: _controller,
        autofocus: true,
        minLines: 1,
        maxLines: 8,
        decoration: InputDecoration(
          hintText: widget.question.helpText ?? 'Enter your answer',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Send answer'),
        ),
      ],
    );
  }
}
