// Modified for Raiju: authorized replacement of the active Buzz bee mark.
import 'package:flutter/material.dart';

import 'raiju_logo.dart';

/// Compatibility surface for retained callers of the original animated mark.
///
/// The shared Raiju artwork replaces the bee. Existing controllers now drive
/// a gentle pulse instead of wing movement; refresh expressions remain intact.
class FlappingBee extends StatelessWidget {
  final double width;
  final Color color;
  final double flapAmount;
  final double? eyeProgress;

  const FlappingBee({
    required this.width,
    required this.color,
    required this.flapAmount,
    this.eyeProgress,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return RaijuLogo(width: width, color: color, motion: flapAmount);
  }
}
