import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../companion_controller.dart';
import '../../harness/harness.dart';
import '../../harness/ompd_api.dart';
import '../../harness/ompd_connection.dart';
import '../../raiju/companion_provider.dart';
import '../../raiju/ompd_relay_preferences.dart';
import '../../shared/theme/theme.dart';

final ompdApiProvider = Provider<OmpdApi>((ref) => const OmpdApi());

enum OmpdPairingView { browse, start }

/// Optional relay with independently saved connection and start preferences.
class OmpdPairingPage extends ConsumerStatefulWidget {
  const OmpdPairingPage({super.key, this.initialView = OmpdPairingView.browse});

  final OmpdPairingView initialView;

  @override
  ConsumerState<OmpdPairingPage> createState() => _OmpdPairingPageState();
}

class _OmpdPairingPageState extends ConsumerState<OmpdPairingPage> {
  late final TextEditingController _endpoint;
  final _name = TextEditingController();
  late final TextEditingController _profile;
  final _cwd = TextEditingController();
  final _session = TextEditingController();
  List<OmpdInstance> _instances = const [];
  late OmpdPairingView _view;
  bool _saved = false;
  bool _busy = false;
  bool _startAttempted = false;
  bool _cancelled = false;
  bool _hasRefreshed = false;
  String? _error;
  String? _progress;
  ChatJoinCancellation? _pendingJoin;

  @override
  void initState() {
    super.initState();
    final preferences = ref.read(ompdRelayPreferencesProvider);
    _endpoint = TextEditingController(
      text:
          preferences.endpoint ??
          ref.read(companionControllerProvider).lastOmpdEndpoint?.toString() ??
          '',
    );
    _profile = TextEditingController(text: preferences.profile);
    _view = widget.initialView;
  }

  @override
  void dispose() {
    _cancelPending();
    _endpoint.dispose();
    _name.dispose();
    _profile.dispose();
    _cwd.dispose();
    _session.dispose();
    super.dispose();
  }

  bool get _active => mounted && !_cancelled;

  void _cancelPending() {
    _cancelled = true;
    _pendingJoin?.cancel();
  }

  OmpdEndpoint _editedEndpoint() =>
      OmpdEndpoint.parse(_endpoint.text, requirePort: true);

  Future<void> _rememberEdits() async {
    try {
      await ref
          .read(ompdRelayPreferencesProvider.notifier)
          .setDraft(endpoint: _endpoint.text, profile: _profile.text);
    } catch (_) {
      if (_active) setState(() => _error = 'Could not save relay settings.');
    }
  }

  Future<void> _save() => _run((_) async {
    if (_active) setState(() => _saved = true);
  });

  bool _attachable(OmpdInstance instance) =>
      instance.ready &&
      instance.rpc &&
      !instance.sessionConflict &&
      (instance.sessionId?.isNotEmpty ?? false) &&
      (instance.sessionFile?.isNotEmpty ?? false);

  Future<void> _run(Future<void> Function(OmpdEndpoint) action) async {
    if (_busy || !_active) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final endpoint = _editedEndpoint();
      await ref
          .read(ompdRelayPreferencesProvider.notifier)
          .setDraft(endpoint: endpoint.toString(), profile: _profile.text);
      if (!_active) return;
      _endpoint.text = endpoint.toString();
      await action(endpoint);
    } on HarnessException catch (error) {
      if (_active) setState(() => _error = error.message);
    } catch (_) {
      if (_active) {
        setState(
          () => _error =
              'Could not save or connect. Check relay endpoint and network.',
        );
      }
    } finally {
      if (_active) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _refresh() => _run((endpoint) async {
    final instances = await ref.read(ompdApiProvider).status(endpoint);
    if (_active) {
      setState(() {
        _instances = instances;
        _hasRefreshed = true;
      });
    }
  });

  Future<void> _join(OmpdEndpoint endpoint, OmpdInstance instance) async {
    if (!_attachable(instance)) {
      throw const HarnessException(
        'Session identity is not ready. Refresh before attaching; no conversation was changed.',
      );
    }
    if (!_active) return;
    final controller = ref.read(companionControllerProvider);
    final cancellation = ChatJoinCancellation();
    _pendingJoin = cancellation;
    final ChatThread chat;
    try {
      chat = await controller.join(
        OmpdConnection(
          endpoint: endpoint,
          instance: instance.name,
          sessionId: instance.sessionId,
          sessionFile: instance.sessionFile,
          trustedNetwork: true,
        ).encode(),
        cancellation: cancellation,
      );
    } finally {
      _pendingJoin = null;
    }
    if (!mounted || _cancelled) {
      // Cancel only the local connection. Never stop the daemon worker.
      await controller.remove(chat.id);
      return;
    }
    Navigator.of(context).pop<ChatThread>(chat);
  }

  Future<void> _start() => _run((endpoint) async {
    if (_startAttempted) return;
    final name = _name.text.trim();
    final profile = _profile.text.trim();
    final cwd = _cwd.text.trim();
    final session = _session.text.trim();
    if (name.isEmpty) {
      throw const HarnessException('Enter an instance name.');
    }
    validateOmpdName(name);
    if (profile.isNotEmpty) validateOmpdName(profile);
    if (profile.isEmpty && cwd.isEmpty) {
      throw const HarnessException(
        'Enter a profile or an absolute working directory on the host.',
      );
    }
    if (cwd.isNotEmpty && !cwd.startsWith('/')) {
      throw const HarnessException(
        'Working directory must be an absolute host path.',
      );
    }
    for (final value in [cwd, session]) {
      if (value.length > 4096 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
        throw const HarnessException(
          'Invalid host directory or session reference.',
        );
      }
    }
    setState(() {
      _startAttempted = true;
      _progress = 'Starting once, then waiting for session identity…';
    });
    final api = ref.read(ompdApiProvider);
    try {
      await api.start(
        endpoint,
        name: name,
        profile: profile.isEmpty ? null : profile,
        cwd: cwd.isEmpty ? null : cwd,
        session: session.isEmpty ? null : session,
      );
      if (!_active) return;
      final instance = await api.waitUntilReady(endpoint, name);
      if (!_active) return;
      await _join(endpoint, instance);
    } on HarnessException catch (error) {
      throw HarnessException(
        '${error.message} A start attempt was made; the instance may still run. Refresh and attach instead of starting again.',
      );
    } catch (_) {
      throw const HarnessException(
        'Start or attach failed. The instance may still run. Refresh and attach instead of starting again.',
      );
    }
  });

  Widget _field(
    String key,
    String label,
    TextEditingController controller, {
    String? hint,
    ValueChanged<String>? onChanged,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: Grid.twelve),
    child: TextField(
      key: ValueKey(key),
      controller: controller,
      enabled: !_busy,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
      onChanged: onChanged,
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _cancelPending();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          _view == OmpdPairingView.browse
              ? 'Browse relay'
              : 'Add remote session',
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(Grid.gutter),
          children: [
            _field(
              'ompd-endpoint',
              'Endpoint host:port',
              _endpoint,
              hint: 'host:port or [IPv6]:port',
              onChanged: (_) {
                setState(() {
                  _instances = const [];
                  _hasRefreshed = false;
                  _error = null;
                  _saved = false;
                });
                _rememberEdits();
              },
            ),
            OutlinedButton.icon(
              key: const ValueKey('ompd-save'),
              onPressed: _busy ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save'),
            ),
            if (_saved)
              const Text('Relay settings saved', key: ValueKey('ompd-saved')),
            const SizedBox(height: Grid.twelve),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    key: const ValueKey('ompd-view-browse'),
                    onPressed: _busy
                        ? null
                        : () => setState(() => _view = OmpdPairingView.browse),
                    child: Text(
                      'Browse relay',
                      style: _view == OmpdPairingView.browse
                          ? const TextStyle(fontWeight: FontWeight.bold)
                          : null,
                    ),
                  ),
                ),
                Expanded(
                  child: TextButton(
                    key: const ValueKey('ompd-view-start'),
                    onPressed: _busy
                        ? null
                        : () => setState(() => _view = OmpdPairingView.start),
                    child: Text(
                      'Start or resume',
                      style: _view == OmpdPairingView.start
                          ? const TextStyle(fontWeight: FontWeight.bold)
                          : null,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Grid.twelve),
            if (_view == OmpdPairingView.browse) ...[
              const Text(
                'Attaching takes write control from the current controller. Leaving or disconnecting never stops the worker.',
              ),
              const SizedBox(height: Grid.twelve),
              OutlinedButton.icon(
                key: const ValueKey('ompd-refresh'),
                onPressed: _busy ? null : _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh running instances'),
              ),
              if (_hasRefreshed && _instances.isEmpty)
                const Text('No running instances. Use Start or resume.'),
              for (final instance in _instances)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    instance.sessionName?.isNotEmpty == true
                        ? '${instance.name} — ${instance.sessionName}'
                        : instance.name,
                  ),
                  subtitle: Text(
                    '${instance.state}${_attachable(instance) ? '' : ' — unavailable until RPC and session identity are ready'}',
                  ),
                  trailing: TextButton(
                    key: ValueKey('ompd-attach-${instance.name}'),
                    onPressed: !_busy && _attachable(instance)
                        ? () => _run((endpoint) => _join(endpoint, instance))
                        : null,
                    child: const Text('Attach'),
                  ),
                ),
            ],
            if (_view == OmpdPairingView.start) ...[
              const SizedBox(height: Grid.md),
              Text(
                'Start new or resume known session',
                style: context.textTheme.titleMedium,
              ),
              const SizedBox(height: Grid.twelve),
              _field('ompd-name', 'Instance name', _name),
              _field(
                'ompd-profile',
                'Profile (or enter working directory)',
                _profile,
                onChanged: (_) {
                  setState(() => _saved = false);
                  _rememberEdits();
                },
              ),
              _field('ompd-cwd', 'Absolute host working directory', _cwd),
              _field('ompd-session', 'Session file or ID (optional)', _session),
              const Text(
                'Leave session empty for a new conversation. To resume, enter a known session ID or absolute session-file path on the host. Paths refer to the host, not this phone.',
              ),
              const SizedBox(height: Grid.twelve),
              FilledButton(
                key: const ValueKey('ompd-start'),
                onPressed: !_busy && !_startAttempted ? _start : null,
                child: const Text('Start once and connect'),
              ),
              if (_startAttempted && !_busy)
                const Text(
                  'A start attempt was made. Use Browse relay to find and attach that instance. Returning to this screen never retries it automatically.',
                ),
            ],
            if (_busy) ...[
              const SizedBox(height: Grid.twelve),
              const LinearProgressIndicator(),
              Text(_progress ?? 'Connecting…'),
              const Text(
                'You can go back. Any started instance keeps running.',
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: Grid.twelve),
              Text(
                _error!,
                key: const ValueKey('ompd-error'),
                style: TextStyle(color: context.colors.error),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
