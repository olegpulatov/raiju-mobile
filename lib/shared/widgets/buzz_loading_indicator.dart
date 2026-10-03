// Modified for Raiju: shared themed ears mark replaces the inherited arc spinner.

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../theme/theme.dart';
import 'raiju_logo.dart';

/// The shared mobile loading indicator with the canonical Raiju mark.
class BuzzLoadingIndicator extends HookConsumerWidget {
  /// The mark diameter.
  final double size;

  /// An optional mark color. Defaults to the active accent color.
  final Color? color;

  /// The accessibility announcement for this loading state.
  final String semanticLabel;

  /// Creates a looping Raiju loading indicator.
  const BuzzLoadingIndicator({
    this.size = 40,
    this.color,
    this.semanticLabel = 'Loading',
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final animation = useAnimationController(
      duration: const Duration(milliseconds: 500),
    );

    useEffect(() {
      if (reducedMotion) {
        animation
          ..stop()
          ..value = 0;
      } else {
        animation.repeat();
      }
      return animation.stop;
    }, [animation, reducedMotion]);

    final spinnerColor = color ?? context.colors.primary;

    return Semantics(
      liveRegion: true,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: RotationTransition(
          key: const ValueKey('buzz-loading-indicator-spinner'),
          turns: animation,
          child: RaijuLogo(width: size, color: spinnerColor),
        ),
      ),
    );
  }
}
