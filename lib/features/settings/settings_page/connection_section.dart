// MODIFIED FOR RAIJU: this original settings card now manages durable OMP
// connections instead of Buzz identity export and community sign-out.
part of '../settings_page.dart';

class _ConnectionSection extends ConsumerWidget {
  const _ConnectionSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(companionControllerProvider);
    final relay = ref.watch(collabRelayProvider);
    final chats = controller.chats;

    return AppListCard(
      label: 'Connection',
      verticalPadding: Grid.twelve,
      children: [
        const AppListRow(
          key: ValueKey('buzz-identity-unavailable'),
          icon: LucideIcons.key,
          title: 'Identity (pubkey)',
          subtitle: 'Not used by Raiju',
        ),
        const AppListRow(
          key: ValueKey('buzz-identity-transfer-unavailable'),
          icon: LucideIcons.scanQrCode,
          title: 'Send identity to desktop',
          subtitle: 'Unavailable in Raiju; no Buzz identity is stored',
        ),
        AppListRow(
          key: const ValueKey('settings-connect-omp'),
          icon: LucideIcons.scanQrCode,
          title: 'Connect OMP chat',
          subtitle: 'Scan a QR code or paste a collaboration link',
          trailing: const _RowChevron(),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const PairingPage(addingCommunity: true),
            ),
          ),
        ),
        AppListRow(
          key: const ValueKey('settings-default-collab-relay'),
          icon: LucideIcons.radioTower,
          title: 'Default collaboration relay',
          subtitle: relay,
          trailing: const _RowChevron(),
          onTap: () => showBuzzDialog<void>(
            context: context,
            builder: (_) => _EditRelayDialog(initialRelay: relay),
          ),
        ),
        if (controller.isLoading)
          const AppListRow(
            key: ValueKey('saved-connections-loading'),
            icon: LucideIcons.loaderCircle,
            title: 'Saved connections',
            subtitle: 'Loading private device storage…',
          )
        else if (controller.storageError != null)
          AppListRow(
            key: const ValueKey('saved-connections-error'),
            icon: LucideIcons.triangleAlert,
            title: 'Saved connections unavailable',
            subtitle: controller.storageError,
            subtitleStyle: context.textTheme.bodySmall?.copyWith(
              color: context.colors.error,
            ),
          )
        else if (chats.isEmpty)
          const AppListRow(
            key: ValueKey('saved-connections-empty'),
            icon: LucideIcons.messageCircle,
            title: 'No saved connections',
            subtitle: 'Connected chats will be encrypted and saved here',
          )
        else
          for (final chat in chats) _SavedConnectionRow(chat: chat),
      ],
    );
  }
}

class _EditRelayDialog extends ConsumerStatefulWidget {
  const _EditRelayDialog({required this.initialRelay});

  final String initialRelay;

  @override
  ConsumerState<_EditRelayDialog> createState() => _EditRelayDialogState();
}

class _EditRelayDialogState extends ConsumerState<_EditRelayDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialRelay,
  );
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(collabRelayProvider.notifier).setRelay(_controller.text);
      if (mounted) Navigator.of(context).pop();
    } on CollabLinkException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save the relay. Try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Default collaboration relay'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Used for manually entered room codes only. Full QR links use their own relay.',
        ),
        TextField(
          key: const ValueKey('default-collab-relay-input'),
          controller: _controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Relay origin',
            hintText: 'wss://relay.example',
            errorText: _error,
          ),
          onSubmitted: (_) => _save(),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      TextButton(onPressed: _saving ? null : _save, child: const Text('Save')),
    ],
  );
}

/// Retains the original destructive card placement without invoking Buzz auth.
class _RemoveCommunitySection extends StatelessWidget {
  const _RemoveCommunitySection();

  @override
  Widget build(BuildContext context) {
    return const AppListCard(
      verticalPadding: Grid.twelve,
      children: [
        AppListRow(
          key: ValueKey('remove-community-unavailable'),
          icon: LucideIcons.logOut,
          title: 'Remove community',
          subtitle:
              'Unavailable in Raiju; forget individual OMP connections above',
        ),
      ],
    );
  }
}

class _SavedConnectionRow extends ConsumerWidget {
  const _SavedConnectionRow({required this.chat});

  final ChatThread chat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = chat.snapshot.phase;
    final connected =
        phase == ConnectionPhase.live ||
        phase == ConnectionPhase.connecting ||
        phase == ConnectionPhase.syncing ||
        phase == ConnectionPhase.reconnecting;
    final status = switch (phase) {
      ConnectionPhase.live =>
        chat.snapshot.readOnly ? 'Live · read only' : 'Live',
      ConnectionPhase.connecting => 'Connecting',
      ConnectionPhase.syncing => 'Syncing',
      ConnectionPhase.reconnecting => 'Reconnecting',
      ConnectionPhase.disconnected => 'Disconnected',
      ConnectionPhase.ended => 'Session ended',
      ConnectionPhase.error => chat.snapshot.error ?? 'Connection error',
    };

    Future<void> run(Future<void> Function() action) async {
      try {
        await action();
      } catch (_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('The connection could not be updated. Try again.'),
          ),
        );
      }
    }

    return AppListRow(
      key: ValueKey('saved-connection-${chat.id}'),
      icon: connected ? LucideIcons.radio : LucideIcons.radioTower,
      title: chat.title,
      subtitle: status,
      subtitleStyle: phase == ConnectionPhase.error
          ? context.textTheme.bodySmall?.copyWith(color: context.colors.error)
          : null,
      trailing: PopupMenuButton<_ConnectionAction>(
        tooltip: 'Connection actions',
        onSelected: (action) {
          final controller = ref.read(companionControllerProvider);
          switch (action) {
            case _ConnectionAction.reconnect:
              unawaited(run(() => controller.reconnect(chat.id)));
              break;
            case _ConnectionAction.disconnect:
              unawaited(run(() => controller.disconnect(chat.id)));
              break;
            case _ConnectionAction.forget:
              _confirmForgetConnection(context, ref, chat);
              break;
          }
        },
        itemBuilder: (_) => [
          if (!connected)
            const PopupMenuItem(
              value: _ConnectionAction.reconnect,
              child: Text('Reconnect'),
            ),
          if (connected)
            const PopupMenuItem(
              value: _ConnectionAction.disconnect,
              child: Text('Disconnect'),
            ),
          const PopupMenuItem(
            value: _ConnectionAction.forget,
            child: Text('Forget connection'),
          ),
        ],
      ),
    );
  }
}

enum _ConnectionAction { reconnect, disconnect, forget }

void _confirmForgetConnection(
  BuildContext context,
  WidgetRef ref,
  ChatThread chat,
) {
  showBuzzDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Forget connection?'),
      content: const Text(
        'This removes the saved private link and cached chat from this device. It does not stop the OMP host session.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: dialogContext.colors.error,
          ),
          onPressed: () async {
            Navigator.of(dialogContext).pop();
            try {
              await ref.read(companionControllerProvider).remove(chat.id);
            } catch (_) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Could not forget this connection. Try again.'),
                ),
              );
            }
          },
          child: const Text('Forget'),
        ),
      ],
    ),
  );
}
