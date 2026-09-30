import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A compact scalar-level visualization. It paints no audio waveform and keeps
/// no audio samples: only the normalized levels exposed by Spark.
class SparkLevelVisualizer extends StatefulWidget {
  const SparkLevelVisualizer({
    super.key,
    required this.inputLevel,
    required this.outputLevel,
    this.levelRevision = 0,
    this.active = true,
  });

  final double inputLevel;
  final double outputLevel;

  /// Increments for each meter event, including identical consecutive samples.
  final int levelRevision;
  final bool active;

  @override
  State<SparkLevelVisualizer> createState() => _SparkLevelVisualizerState();
}

class _SparkLevelVisualizerState extends State<SparkLevelVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  static const _freshnessWindow = Duration(milliseconds: 500);
  Timer? _expiry;
  bool _fresh = false;

  bool get _hasSignal =>
      _normalizedLevel(widget.inputLevel) > 0 ||
      _normalizedLevel(widget.outputLevel) > 0;

  @override
  void initState() {
    super.initState();
    _refreshLevel();
  }

  void _refreshLevel() {
    _expiry?.cancel();
    _fresh = widget.active && _hasSignal;
    if (!_fresh) return;
    _expiry = Timer(_freshnessWindow, () {
      if (!mounted) return;
      setState(() => _fresh = false);
      _updateMotion();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateMotion();
  }

  @override
  void didUpdateWidget(covariant SparkLevelVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.levelRevision != oldWidget.levelRevision ||
        widget.inputLevel != oldWidget.inputLevel ||
        widget.outputLevel != oldWidget.outputLevel) {
      _refreshLevel();
    } else if (!widget.active) {
      _expiry?.cancel();
      _fresh = false;
    }
    _updateMotion();
  }

  void _updateMotion() {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // Silence or an expired meter cannot pulse, even if its last scalar was
    // positive (for example after playback ends with the microphone muted).
    if (widget.active && _fresh && !reduceMotion) {
      if (!_animation.isAnimating) _animation.repeat();
    } else {
      _animation.stop();
    }
  }

  @override
  void dispose() {
    _expiry?.cancel();
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final input = widget.active && _fresh
        ? _normalizedLevel(widget.inputLevel)
        : 0.0;
    final output = widget.active && _fresh
        ? _normalizedLevel(widget.outputLevel)
        : 0.0;
    return Semantics(
      label: !widget.active
          ? 'Spark is idle'
          : math.max(input, output) > 0
          ? 'Spark voice audio level'
          : 'Spark voice connected, no audio level',
      image: true,
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _animation,
          builder: (context, _) => CustomPaint(
            painter: _LevelPainter(
              input: input,
              output: output,
              phase: reduceMotion ? 0 : _animation.value,
              color: Theme.of(context).colorScheme.primary,
              quietColor: Theme.of(context).colorScheme.outlineVariant,
              active: widget.active,
            ),
            size: const Size(double.infinity, 28),
          ),
        ),
      ),
    );
  }
}

double _normalizedLevel(double level) =>
    level.isFinite ? level.clamp(0.0, 1.0) : 0;

/// Display-only response curve for scalar meters; never applied to PCM.
double sparkVisualResponse(double input, double output) {
  final level = math.max(_normalizedLevel(input), _normalizedLevel(output));
  return math.min(1.0, math.sqrt(level) * 1.8);
}

class _LevelPainter extends CustomPainter {
  const _LevelPainter({
    required this.input,
    required this.output,
    required this.phase,
    required this.color,
    required this.quietColor,
    required this.active,
  });

  final double input;
  final double output;
  final double phase;
  final Color color;
  final Color quietColor;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0) {
      return;
    }
    const gap = 2.0;
    // Narrow strips must not paint bars over adjacent controls.
    final bars = math.min(
      19,
      math.max(1, ((size.width + gap) / (1.5 + gap)).floor()),
    );
    final width = (size.width - gap * (bars - 1)) / bars;
    // RMS is commonly far below 1 even for audible speech. Boost *only* the
    // visual response, with a hard cap; zero remains zero and never pulses.
    final visualLevel = sparkVisualResponse(input, output);
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var index = 0; index < bars; index++) {
      final distance = (index - (bars - 1) / 2).abs() / (bars / 2);
      final pulse = (math.sin((phase * math.pi * 2) + index * .72) + 1) / 2;
      final energy = active ? .10 + visualLevel * (.42 + pulse * .46) : .1;
      final height = math.max(3.0, size.height * energy * (1 - distance * .34));
      final x = index * (width + gap) + width / 2;
      paint
        ..strokeWidth = width
        ..color = Color.lerp(quietColor, color, active ? visualLevel : 0)!;
      canvas.drawLine(
        Offset(x, (size.height - height) / 2),
        Offset(x, (size.height + height) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LevelPainter oldDelegate) =>
      input != oldDelegate.input ||
      output != oldDelegate.output ||
      phase != oldDelegate.phase ||
      color != oldDelegate.color ||
      quietColor != oldDelegate.quietColor ||
      active != oldDelegate.active;
}
