import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// Canonical Raiju ears and separate bolt, tinted by the current app theme.
///
/// The transparent mask retains the approved contours from brand/sources.
/// Callers keep ownership of their animation and reduced-motion policy.
class RaijuLogo extends StatelessWidget {
  static const asset = 'assets/images/raiju-mark.png';

  final double width;
  final Color? color;
  final double motion;

  const RaijuLogo({this.width = 60, this.color, this.motion = 0, super.key});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: width,
        child: Transform.scale(
          scale: 1 - 0.08 * motion.clamp(0.0, 1.0),
          child: Image.asset(
            asset,
            width: width,
            height: width,
            color: color ?? context.colors.primary,
            colorBlendMode: BlendMode.srcIn,
            filterQuality: FilterQuality.medium,
            excludeFromSemantics: true,
          ),
        ),
      ),
    );
  }
}
