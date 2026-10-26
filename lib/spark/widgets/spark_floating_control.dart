import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/theme/theme.dart';
import '../overlay_position.dart';

/// Moves only the folded controls; gestures never reach voice session actions.
class SparkFloatingControl extends ConsumerStatefulWidget {
  const SparkFloatingControl({
    super.key,
    required this.child,
    required this.composerTop,
    required this.onSaveError,
  });

  final Widget child;
  final double? composerTop;
  final VoidCallback onSaveError;

  @override
  ConsumerState<SparkFloatingControl> createState() =>
      _SparkFloatingControlState();
}

class _SparkFloatingControlState extends ConsumerState<SparkFloatingControl>
    with SingleTickerProviderStateMixin {
  final _layoutKey = GlobalKey();
  final _controlKey = GlobalKey();
  late final _snap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  Offset? _dragPosition;
  Offset? _snapFrom;

  @override
  void dispose() {
    _snap.dispose();
    super.dispose();
  }

  RenderBox get _layoutBox =>
      _layoutKey.currentContext!.findRenderObject()! as RenderBox;
  RenderBox get _controlBox =>
      _controlKey.currentContext!.findRenderObject()! as RenderBox;

  _PlacementGeometry _geometry(MediaQueryData media) => _PlacementGeometry(
    viewport: _layoutBox.size,
    control: _controlBox.size,
    media: media,
    composerTop: widget.composerTop,
  );

  void _startDrag(DragStartDetails details) {
    _snap.stop();
    setState(() {
      _dragPosition = _controlBox.localToGlobal(
        Offset.zero,
        ancestor: _layoutBox,
      );
      _snapFrom = null;
    });
  }

  void _updateDrag(DragUpdateDetails details) {
    final geometry = _geometry(MediaQuery.of(context));
    setState(() {
      _dragPosition = geometry.clamp(_dragPosition! + details.delta);
    });
  }

  void _endDrag() {
    if (_dragPosition == null) return;
    final geometry = _geometry(MediaQuery.of(context));
    final end = geometry.clamp(_dragPosition!);
    final position = SparkOverlayPosition(
      right: end.dx - geometry.range.left >= geometry.range.right - end.dx,
      fraction: geometry.range.height == 0
          ? 0
          : (end.dy - geometry.range.top) / geometry.range.height,
    );
    setState(() {
      _snapFrom = end;
      _dragPosition = null;
    });
    _snap.forward(from: 0);
    unawaited(
      ref.read(sparkOverlayPositionProvider.notifier).save(position).catchError(
        (Object _) {
          if (mounted) widget.onSaveError();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final position = ref.watch(sparkOverlayPositionProvider);
    final media = MediaQuery.of(context);
    final defaultRight = Directionality.of(context) == TextDirection.ltr;
    return AnimatedBuilder(
      animation: _snap,
      builder: (context, child) => CustomSingleChildLayout(
        key: _layoutKey,
        delegate: _FloatingPlacement(
          media: media,
          composerTop: widget.composerTop,
          position: position,
          defaultRight: defaultRight,
          dragPosition: _dragPosition,
          snapFrom: _snapFrom,
          progress: Curves.easeOutCubic.transform(_snap.value),
        ),
        child: child,
      ),
      child: GestureDetector(
        key: _controlKey,
        dragStartBehavior: DragStartBehavior.down,
        onPanStart: _startDrag,
        onPanUpdate: _updateDrag,
        onPanEnd: (_) => _endDrag(),
        onPanCancel: _endDrag,
        child: widget.child,
      ),
    );
  }
}

class _PlacementGeometry {
  _PlacementGeometry({
    required Size viewport,
    required Size control,
    required MediaQueryData media,
    double? composerTop,
  }) {
    final left = math.min(
      media.padding.left + Grid.xs,
      math.max(0.0, viewport.width - control.width),
    );
    final top = math.min(
      media.padding.top + Grid.xs,
      math.max(0.0, viewport.height - control.height),
    );
    final right = math.max(
      left,
      viewport.width - media.padding.right - Grid.xs - control.width,
    );
    final bottomEdge = math.min(
      viewport.height - math.max(media.viewInsets.bottom, media.padding.bottom),
      composerTop ?? double.infinity,
    );
    range = Rect.fromLTRB(
      left,
      top,
      right,
      math.max(top, bottomEdge - Grid.xs - control.height),
    );
    defaultTop = viewport.height * .32;
  }

  late final Rect range;
  late final double defaultTop;

  Offset clamp(Offset value) => Offset(
    value.dx.clamp(range.left, range.right),
    value.dy.clamp(range.top, range.bottom),
  );

  Offset dock(SparkOverlayPosition? position, bool defaultRight) => clamp(
    Offset(
      (position?.right ?? defaultRight) ? range.right : range.left,
      position == null
          ? defaultTop
          : range.top + range.height * position.fraction,
    ),
  );
}

class _FloatingPlacement extends SingleChildLayoutDelegate {
  _FloatingPlacement({
    required this.media,
    required this.composerTop,
    required this.position,
    required this.defaultRight,
    required this.dragPosition,
    required this.snapFrom,
    required this.progress,
  });

  final MediaQueryData media;
  final double? composerTop;
  final SparkOverlayPosition? position;
  final bool defaultRight;
  final Offset? dragPosition;
  final Offset? snapFrom;
  final double progress;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final geometry = _PlacementGeometry(
      viewport: size,
      control: childSize,
      media: media,
      composerTop: composerTop,
    );
    final target = geometry.dock(position, defaultRight);
    return geometry.clamp(
      dragPosition ?? Offset.lerp(snapFrom ?? target, target, progress)!,
    );
  }

  @override
  bool shouldRelayout(_FloatingPlacement oldDelegate) => true;
}
