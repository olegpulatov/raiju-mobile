import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/theme/theme.dart';
import '../spark.dart';

/// The live dialogue is displayed in its bound chat, not a second transcript.
/// This sheet retains typed input and connection status while navigating.
class SparkTranscriptSheet extends ConsumerStatefulWidget {
  const SparkTranscriptSheet({super.key});

  @override
  ConsumerState<SparkTranscriptSheet> createState() =>
      _SparkTranscriptSheetState();
}

class _SparkTranscriptSheetState extends ConsumerState<SparkTranscriptSheet> {
  final _input = TextEditingController();
  bool _sendingText = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _sendText() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sendingText) return;
    setState(() => _sendingText = true);
    try {
      await ref.read(sparkControllerProvider).sendText(text);
      if (mounted) _input.clear();
    } catch (_) {
      // Keep the draft; the controller exposes a sanitized visible error.
    } finally {
      if (mounted) setState(() => _sendingText = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(sparkControllerProvider);
    final snapshot = controller.snapshot;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          Grid.gutter,
          Grid.xs,
          Grid.gutter,
          MediaQuery.viewInsetsOf(context).bottom + Grid.xs,
        ),
        child: ListView(
          key: const ValueKey('spark-transcript'),
          shrinkWrap: true,
          children: [
            Text('Spark', style: context.textTheme.titleMedium),
            const SizedBox(height: Grid.xs),
            Text(
              snapshot.boundChatId == null
                  ? 'Open a chat to start Spark. Conversation appears in that chat.'
                  : 'Conversation stays in the chat where Spark started, even when you navigate away.',
              style: context.textTheme.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            if (snapshot.integrationStatus case final status?) ...[
              const SizedBox(height: Grid.xs),
              Text(status, key: const ValueKey('spark-integration-status')),
            ],
            if (snapshot.error case final error?) ...[
              const SizedBox(height: Grid.xs),
              Text(error, style: TextStyle(color: context.colors.error)),
            ],
            const SizedBox(height: Grid.sm),
            TextField(
              key: const ValueKey('spark-manual-input'),
              controller: _input,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => unawaited(_sendText()),
              decoration: InputDecoration(
                labelText: 'Message Spark',
                hintText: 'Appears in the bound chat',
                suffixIcon: IconButton(
                  key: const ValueKey('spark-manual-submit'),
                  tooltip: 'Send message to Spark',
                  onPressed: _sendingText ? null : () => unawaited(_sendText()),
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
