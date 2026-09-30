part of '../settings_page.dart';

class _SparkSection extends ConsumerWidget {
  const _SparkSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(sparkControllerProvider);
    return AppListCard(
      key: const ValueKey('spark-settings-section'),
      label: 'Spark live voice',
      children: [
        AppListRow(
          icon: LucideIcons.audioLines,
          title: 'Spark',
          subtitle: controller.settings.brokerUrl.isEmpty
              ? 'Configure live voice and connected conversation'
              : 'Voice: ${controller.settings.voice} · ${controller.settings.promptPresets.length} prompt${controller.settings.promptPresets.length == 1 ? '' : 's'}',
          subtitleMaxLines: 2,
          trailing: const _RowChevron(),
          onTap: () => unawaited(
            showBuzzModalBottomSheet<void>(
              context: context,
              useRootNavigator: true,
              isScrollControlled: true,
              title: 'Spark settings',
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .92,
              ),
              builder: (_) => const SparkSettingsEditor(),
            ),
          ),
        ),
      ],
    );
  }
}

class SparkSettingsEditor extends ConsumerStatefulWidget {
  const SparkSettingsEditor({super.key});

  @override
  ConsumerState<SparkSettingsEditor> createState() =>
      _SparkSettingsEditorState();
}

class _SparkSettingsEditorState extends ConsumerState<SparkSettingsEditor> {
  late final TextEditingController _brokerUrl;
  final _brokerToken = TextEditingController();
  late final TextEditingController _promptName;
  late final TextEditingController _promptInstructions;
  late final TextEditingController _userName;
  late final TextEditingController _contextAddition;
  late final TextEditingController _mainAgentDirective;
  late final TextEditingController _agentFinalMessage;
  late List<SparkPromptPreset> _presets;
  late String _selectedPresetId;
  late SparkToolVisibility _toolVisibility;
  late bool _hideThinking;
  late bool _announceTerminalReplies;
  late String _voice;
  late String? _credentialId;
  late bool _allowHttp;
  bool _saving = false;
  late final Future<void> _initialization;
  bool _loaded = false;

  SparkSettings get _initial => ref.read(sparkControllerProvider).settings;

  @override
  void initState() {
    super.initState();
    _initialization = ref.read(sparkControllerProvider).initialize();
  }

  void _hydrate(SparkSettings settings) {
    _brokerUrl = TextEditingController(text: settings.brokerUrl);
    _presets = List.of(settings.promptPresets);
    _selectedPresetId = settings.selectedPresetId;
    final selected = settings.selectedPreset;
    _promptName = TextEditingController(text: selected.name);
    _promptInstructions = TextEditingController(text: selected.instructions);
    _userName = TextEditingController(text: settings.userName);
    _contextAddition = TextEditingController(text: settings.contextAddition);
    _mainAgentDirective = TextEditingController(
      text: settings.mainAgentDirective,
    );
    _agentFinalMessage = TextEditingController(
      text: settings.agentFinalMessage,
    );
    _toolVisibility = settings.toolVisibility;
    _hideThinking = settings.hideThinking;
    _announceTerminalReplies = settings.announceTerminalReplies;
    _voice = settings.voice;
    _credentialId = settings.selectedCredentialId;
    _allowHttp = settings.allowInsecureHttp;
  }

  @override
  void dispose() {
    if (_loaded) {
      _brokerUrl.dispose();
      _promptName.dispose();
      _promptInstructions.dispose();
      _userName.dispose();
      _contextAddition.dispose();
      _mainAgentDirective.dispose();
      _agentFinalMessage.dispose();
    }
    _brokerToken.dispose();
    super.dispose();
  }

  void _persistCurrentPreset() {
    final index = _presets.indexWhere((item) => item.id == _selectedPresetId);
    if (index < 0) return;
    _presets[index] = _presets[index].copyWith(
      name: _promptName.text,
      instructions: _promptInstructions.text,
    );
  }

  void _selectPreset(String id) {
    _persistCurrentPreset();
    final preset = _presets.firstWhere((item) => item.id == id);
    setState(() {
      _selectedPresetId = id;
      _promptName.text = preset.name;
      _promptInstructions.text = preset.instructions;
    });
  }

  void _addPreset() {
    _persistCurrentPreset();
    var suffix = _presets.length + 1;
    var id = 'spark-prompt-$suffix';
    while (_presets.any((item) => item.id == id)) {
      id = 'spark-prompt-${++suffix}';
    }
    final preset = SparkPromptPreset(
      id: id,
      name: 'Prompt $suffix',
      instructions: sparkDefaultInstructions,
    );
    setState(() {
      _presets.add(preset);
      _selectedPresetId = preset.id;
      _promptName.text = preset.name;
      _promptInstructions.text = preset.instructions;
    });
  }

  void _deletePreset() {
    if (_presets.length == 1) return;
    setState(() {
      _presets.removeWhere((item) => item.id == _selectedPresetId);
      final preset = _presets.first;
      _selectedPresetId = preset.id;
      _promptName.text = preset.name;
      _promptInstructions.text = preset.instructions;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    _persistCurrentPreset();
    final controller = ref.read(sparkControllerProvider);
    setState(() => _saving = true);
    try {
      await controller.saveSettings(
        SparkSettings(
          brokerUrl: _brokerUrl.text.trim(),
          allowInsecureHttp: _allowHttp,
          selectedCredentialId: _credentialId,
          promptPresets: List.unmodifiable(_presets),
          selectedPresetId: _selectedPresetId,
          voice: _voice,
          userName: _userName.text.trim(),
          contextAddition: _contextAddition.text,
          mainAgentDirective: _mainAgentDirective.text,
          agentFinalMessage: _agentFinalMessage.text,
          toolVisibility: _toolVisibility,
          hideThinking: _hideThinking,
          announceTerminalReplies: _announceTerminalReplies,
          legacyHandoffInstructions: _initial.legacyHandoffInstructions,
        ),
        brokerToken: _brokerToken.text.isEmpty ? null : _brokerToken.text,
      );
      _brokerToken.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Spark settings saved securely.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(sparkControllerProvider);
    return FutureBuilder<void>(
      future: _initialization,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!_loaded) {
          if (!controller.settingsLoaded) {
            return const Center(
              child: Text(
                'Spark settings are unavailable or corrupt. Existing data was not reset.',
              ),
            );
          }
          _hydrate(controller.settings);
          _loaded = true;
        }
        return _buildLoaded(context, controller);
      },
    );
  }

  Widget _buildLoaded(BuildContext context, SparkController controller) {
    final credentials = controller.eligibleCredentials;
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
          shrinkWrap: true,
          children: [
            Text('Broker', style: context.textTheme.titleMedium),
            const SizedBox(height: Grid.xs),
            TextField(
              key: const ValueKey('spark-broker-url'),
              controller: _brokerUrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'OMP broker URL',
                hintText: 'https://trusted-broker.example',
              ),
            ),
            const SizedBox(height: Grid.xs),
            TextField(
              key: const ValueKey('spark-broker-token'),
              controller: _brokerToken,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: controller.hasBrokerToken
                    ? 'Replace broker token (stored securely)'
                    : 'Broker token (stored securely)',
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Allow HTTP on a trusted network'),
              subtitle: const Text(
                'HTTP exposes this broad-scope broker credential to the network. Prefer HTTPS.',
              ),
              value: _allowHttp,
              onChanged: (value) => setState(() => _allowHttp = value),
            ),
            if (credentials.isNotEmpty)
              DropdownButtonFormField<String?>(
                initialValue: _credentialId,
                decoration: const InputDecoration(
                  labelText: 'ChatGPT credential',
                ),
                items: [
                  if (credentials.length == 1)
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Automatic (only eligible credential)'),
                    ),
                  ...credentials.map(
                    (item) => DropdownMenuItem<String?>(
                      value: item.id,
                      child: Text(item.label),
                    ),
                  ),
                ],
                onChanged: (value) => setState(() => _credentialId = value),
              ),
            const SizedBox(height: Grid.lg),
            Text('Voice and personality', style: context.textTheme.titleMedium),
            const SizedBox(height: Grid.xs),
            DropdownButtonFormField<String>(
              initialValue: _voice,
              decoration: const InputDecoration(labelText: 'Spark voice'),
              items: const [
                DropdownMenuItem(value: 'arbor', child: Text('Arbor')),
                DropdownMenuItem(value: 'breeze', child: Text('Breeze')),
                DropdownMenuItem(value: 'cove', child: Text('Cove')),
                DropdownMenuItem(value: 'ember', child: Text('Ember')),
                DropdownMenuItem(value: 'juniper', child: Text('Juniper')),
                DropdownMenuItem(value: 'maple', child: Text('Maple')),
                DropdownMenuItem(value: 'sol', child: Text('Sol')),
                DropdownMenuItem(value: 'spruce', child: Text('Spruce')),
                DropdownMenuItem(value: 'vale', child: Text('Vale')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _voice = value);
              },
            ),
            const SizedBox(height: Grid.xs),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedPresetId,
                    decoration: const InputDecoration(
                      labelText: 'Named prompt',
                    ),
                    items: _presets
                        .map(
                          (item) => DropdownMenuItem(
                            value: item.id,
                            child: Text(item.name),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      if (value != null) _selectPreset(value);
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'Add prompt',
                  onPressed: _addPreset,
                  icon: const Icon(LucideIcons.plus),
                ),
                IconButton(
                  tooltip: 'Delete prompt',
                  onPressed: _presets.length == 1 ? null : _deletePreset,
                  icon: const Icon(LucideIcons.trash2),
                ),
              ],
            ),
            const SizedBox(height: Grid.xs),
            TextField(
              key: const ValueKey('spark-prompt-name'),
              controller: _promptName,
              decoration: const InputDecoration(labelText: 'Prompt name'),
            ),
            const SizedBox(height: Grid.xs),
            TextField(
              key: const ValueKey('spark-prompt-instructions'),
              controller: _promptInstructions,
              minLines: 4,
              maxLines: 10,
              decoration: const InputDecoration(
                labelText: 'Spark personality instructions',
                alignLabelWithHint: true,
              ),
            ),
            TextField(
              key: const ValueKey('spark-user-name'),
              controller: _userName,
              decoration: const InputDecoration(labelText: 'Your name'),
            ),
            const SizedBox(height: Grid.xs),
            SwitchListTile.adaptive(
              key: const ValueKey('spark-show-thinking'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Show thinking'),
              subtitle: const Text(
                'Hidden by default; does not change saved messages.',
              ),
              value: !_hideThinking,
              onChanged: (value) => setState(() => _hideThinking = !value),
            ),
            SwitchListTile.adaptive(
              key: const ValueKey('spark-announce-terminal-replies'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Read terminal replies aloud'),
              subtitle: const Text(
                'Only new replies while Spark is listening.',
              ),
              value: _announceTerminalReplies,
              onChanged: (value) =>
                  setState(() => _announceTerminalReplies = value),
            ),
            DropdownButtonFormField<SparkToolVisibility>(
              key: const ValueKey('spark-tool-visibility'),
              initialValue: _toolVisibility,
              decoration: const InputDecoration(
                labelText: 'Show tool activity',
              ),
              items: const [
                DropdownMenuItem(
                  value: SparkToolVisibility.show,
                  child: Text('Show'),
                ),
                DropdownMenuItem(
                  value: SparkToolVisibility.hide,
                  child: Text('Hide'),
                ),
                DropdownMenuItem(
                  value: SparkToolVisibility.hideInVoice,
                  child: Text('Hide during voice'),
                ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _toolVisibility = value);
              },
            ),
            const SizedBox(height: Grid.lg),
            Text('Conversation prompts', style: context.textTheme.titleMedium),
            const SizedBox(height: Grid.xs),
            TextField(
              key: const ValueKey('spark-context-addition'),
              controller: _contextAddition,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Context-sharing addition',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: Grid.xs),
            TextField(
              key: const ValueKey('spark-main-agent-directive'),
              controller: _mainAgentDirective,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Remote agent two-model instructions',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: Grid.xs),
            TextField(
              key: const ValueKey('spark-agent-final-message'),
              controller: _agentFinalMessage,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Final message wrapper (use {{message}})',
                alignLabelWithHint: true,
              ),
            ),
            if (_initial.legacyHandoffInstructions != null) ...[
              const SizedBox(height: Grid.xs),
              const Text(
                'Previous manual handoff instructions (inactive, retained for reference)',
              ),
              SelectableText(_initial.legacyHandoffInstructions!),
            ],
            const SizedBox(height: Grid.lg),
            FilledButton(
              key: const ValueKey('spark-save-settings'),
              onPressed: _saving ? null : () => unawaited(_save()),
              child: Text(_saving ? 'Saving…' : 'Save Spark settings'),
            ),
          ],
        ),
      ),
    );
  }
}
