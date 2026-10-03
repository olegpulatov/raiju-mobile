// MODIFIED FOR RAIJU: preserves settings-header geometry with local identity,
// reactive connection state and no Buzz profile/media provider access.
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../raiju/connection_status_provider.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/anchored_popover_menu.dart';
import '../../shared/widgets/masked_avatar_badge.dart';

/// The original large centred avatar/header treatment, backed only by local
/// presentation data because Raiju has no Buzz identity.
class SettingsProfileHeader extends ConsumerWidget {
  const SettingsProfileHeader({super.key});

  static const _avatarSize = 128.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(connectionOnlineProvider);
    void explainUnavailable() {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Unavailable yet')));
    }

    return Padding(
      key: const ValueKey('settings-profile-header'),
      padding: const EdgeInsets.only(top: Grid.sm, bottom: Grid.twelve),
      child: Column(
        children: [
          MaskedAvatarBadge(
            size: _avatarSize,
            avatar: GestureDetector(
              key: const ValueKey('settings-profile-avatar'),
              onTap: explainUnavailable,
              child: ColoredBox(
                key: const ValueKey('settings-profile-avatar-background'),
                color: context.colors.primaryContainer,
                child: const Center(child: _AvatarFallback(initial: 'R')),
              ),
            ),
            badge: _StatusBadge(emoji: '', onTap: explainUnavailable),
          ),
          const SizedBox(height: Grid.twelve),
          Text(
            'You',
            style: context.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          _PresencePill(
            presence: online ? 'online' : 'offline',
            onSelected: (_) => explainUnavailable(),
          ),
        ],
      ),
    );
  }
}

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback({required this.initial});

  final String? initial;

  @override
  Widget build(BuildContext context) {
    return Text(
      initial ?? '?',
      style: context.textTheme.displaySmall?.copyWith(
        color: context.colors.onPrimaryContainer,
      ),
    );
  }
}

class _PresencePill extends StatelessWidget {
  const _PresencePill({required this.presence, required this.onSelected});

  final String presence;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final effectivePresence = switch (presence) {
      'online' || 'away' => presence,
      _ => 'offline',
    };
    final (backgroundColor, foregroundColor) = switch (effectivePresence) {
      'online' => (
        context.appColors.success.withValues(alpha: 0.15),
        context.appColors.success,
      ),
      'away' => (
        context.appColors.warning.withValues(alpha: 0.15),
        context.appColors.warning,
      ),
      _ => (
        context.colors.onSurfaceVariant.withValues(alpha: 0.15),
        context.colors.onSurfaceVariant,
      ),
    };
    final label = _presenceLabel(effectivePresence);

    return Builder(
      builder: (buttonContext) => Semantics(
        button: true,
        label: 'Presence: $label',
        child: SizedBox(
          key: const ValueKey('settings-presence-target'),
          height: Grid.xl,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: const ValueKey('settings-presence-menu'),
              borderRadius: BorderRadius.circular(Radii.full),
              onTap: () async {
                final selected = await showAnchoredPopover<String>(
                  context: buttonContext,
                  width: 176,
                  alignment: AnchoredPopoverAlignment.center,
                  offset: const Offset(0, Grid.half),
                  menuPadding: const EdgeInsets.symmetric(vertical: Grid.half),
                  surfaceKey: const ValueKey('settings-presence-popover'),
                  items: [
                    for (final option in const ['online', 'away', 'offline'])
                      PopupMenuItem<String>(
                        key: ValueKey('settings-presence-$option'),
                        value: option,
                        height: Grid.xl,
                        padding: const EdgeInsets.symmetric(
                          horizontal: Grid.twelve,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: _presenceColor(context, option),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: Grid.xxs),
                            Expanded(
                              child: Text(
                                _presenceLabel(option),
                                style: filterChipTextStyle.copyWith(
                                  color: context.colors.onSurface,
                                  fontWeight: option == effectivePresence
                                      ? FontWeight.w500
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                            if (option == effectivePresence)
                              Icon(
                                LucideIcons.check,
                                size: 16,
                                color: context.colors.primary,
                              ),
                          ],
                        ),
                      ),
                  ],
                );
                if (buttonContext.mounted && selected != null) {
                  onSelected(selected);
                }
              },
              child: Center(
                child: Material(
                  key: const ValueKey('settings-presence-pill'),
                  color: backgroundColor,
                  borderRadius: BorderRadius.circular(Radii.full),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Grid.xs,
                      vertical: Grid.xxs,
                    ),
                    child: Text(
                      label,
                      key: const ValueKey('settings-presence-label'),
                      style: filterChipTextStyle.copyWith(
                        color: foregroundColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
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

String _presenceLabel(String presence) => switch (presence) {
  'online' => 'Online',
  'away' => 'Away',
  _ => 'Offline',
};

Color _presenceColor(BuildContext context, String presence) =>
    switch (presence) {
      'online' => context.appColors.success,
      'away' => context.appColors.warning,
      _ => context.colors.outline,
    };

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.emoji, required this.onTap});

  final String emoji;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Set a status',
      child: GestureDetector(
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.colors.surfaceContainerHighest,
            shape: BoxShape.circle,
          ),
          child: Center(child: _StatusGlyph(emoji: emoji)),
        ),
      ),
    );
  }
}

class _StatusGlyph extends StatelessWidget {
  const _StatusGlyph({required this.emoji});

  final String emoji;

  @override
  Widget build(BuildContext context) {
    if (emoji.isEmpty) {
      return Icon(
        LucideIcons.smilePlus,
        size: 20,
        color: context.colors.onSurfaceVariant,
      );
    }
    return Text(emoji, style: const TextStyle(fontSize: 20));
  }
}
