// MODIFIED FOR RAIJU: this original settings card now manages durable OMP
// connections instead of Buzz identity export and community sign-out.
part of '../settings_page.dart';

class _ConnectionSection extends ConsumerWidget {
  const _ConnectionSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final relay = ref.watch(collabRelayProvider);

    return AppListCard(
      label: 'Connection',
      verticalPadding: Grid.twelve,
      children: [
        AppListRow(
          key: const ValueKey('settings-connect-omp'),
          icon: LucideIcons.scanQrCode,
          title: 'Attach to collab',
          subtitle: 'Scan a QR code or paste a collaboration link',
          trailing: const _RowChevron(),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const PairingPage(addingCommunity: true),
            ),
          ),
        ),
        AppListRow(
          key: const ValueKey('settings-browse-relay'),
          icon: LucideIcons.server,
          title: 'Browse relay',
          subtitle: 'Browse or start an oh-my-pi session',
          trailing: const _RowChevron(),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  const OmpdPairingPage(initialView: OmpdPairingView.browse),
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
