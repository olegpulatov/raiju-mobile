import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// Keeps the same message at the same pixel when a reversed timeline changes.
///
/// PositionedList normally centers index 0. Growth below a detached reader then
/// shifts every older row, even when no scrollTo call runs. Recenter on a visible
/// message before the changed children are laid out, not in a post-frame repair.
class TimelineViewportAnchor extends StatefulWidget {
  const TimelineViewportAnchor({
    super.key,
    required this.enabled,
    required this.itemIds,
    required this.revision,
    required this.itemScrollController,
    required this.itemPositionsListener,
    required this.child,
  });

  final bool enabled;
  final List<String> itemIds;
  final Object revision;
  final ItemScrollController itemScrollController;
  final ItemPositionsListener itemPositionsListener;
  final Widget child;

  @override
  State<TimelineViewportAnchor> createState() => _TimelineViewportAnchorState();
}

class _TimelineViewportAnchorState extends State<TimelineViewportAnchor> {
  List<String> _laidOutIds = const [];
  ScrollPosition? _position;
  bool _rebasing = false;
  Object? _previousRevision;
  Widget? _renderedChild;
  bool _hasDeferredUpdate = false;
  double _laidOutHeight = 0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _buildViewport(constraints.maxHeight),
  );

  Widget _buildViewport(double height) {
    // jumpTo would cancel an active drag or its ballistic continuation. Keep
    // rendering that list until the gesture settles, then apply the newest
    // revision with its reading anchor intact.
    if (widget.enabled &&
        (_position?.isScrollingNotifier.value ?? false) &&
        _renderedChild != null) {
      _hasDeferredUpdate = true;
      return _observeScroll(_renderedChild!);
    }
    final contentChanged =
        !identical(_previousRevision, widget.revision) ||
        height != _laidOutHeight;
    _previousRevision = widget.revision;
    if (widget.enabled &&
        contentChanged &&
        widget.itemScrollController.isAttached) {
      final candidates =
          widget.itemPositionsListener.itemPositions.value
              .where((item) => item.index < _laidOutIds.length)
              .where(
                (item) => item.itemLeadingEdge < 1 && item.itemTrailingEdge > 0,
              )
              .toList()
            ..sort(
              (a, b) => (a.itemLeadingEdge - 0.5).abs().compareTo(
                (b.itemLeadingEdge - 0.5).abs(),
              ),
            );
      if (candidates.isNotEmpty &&
          candidates.every((item) => item.index == 0) &&
          _laidOutIds.length > 1) {
        // When the growing newest row fills the screen, anchor its top via
        // the older neighbour's bottom, not its changing bottom edge.
        candidates.insert(
          0,
          ItemPosition(
            index: 1,
            itemLeadingEdge: candidates.first.itemTrailingEdge,
            itemTrailingEdge: candidates.first.itemTrailingEdge,
          ),
        );
      }
      for (final item in candidates) {
        final index = widget.itemIds.indexOf(_laidOutIds[item.index]);
        if (index < 0) continue;
        // Item positions are fractions measured from the bottom. Keep the
        // absolute distance from the screen's top across keyboard resizing.
        final leadingEdge = _laidOutHeight > 0 && height > 0
            ? 1 - (_laidOutHeight / height) * (1 - item.itemLeadingEdge)
            : item.itemLeadingEdge;
        final alignment = leadingEdge.clamp(0.0, 1.0);
        _rebasing = true;
        widget.itemScrollController.jumpTo(index: index, alignment: alignment);
        // A single very tall row can cover the entire viewport, with its bottom
        // below the screen. Viewport.anchor only accepts [0, 1]; retain the extra
        // pixel distance in the existing scroll position instead.
        if (alignment != leadingEdge && _position != null) {
          _position!.jumpTo((alignment - leadingEdge) * height);
        }
        _rebasing = false;
        break;
      }
    }
    final nextIds = widget.itemIds;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _laidOutIds = nextIds;
      if (mounted) _laidOutHeight = height;
    });
    _renderedChild = widget.child;
    return _observeScroll(widget.child);
  }

  Widget _observeScroll(Widget child) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 && notification.context != null) {
          _position = Scrollable.maybeOf(notification.context!)?.position;
        }
        if (!_rebasing &&
            notification.depth == 0 &&
            notification is ScrollEndNotification &&
            _hasDeferredUpdate) {
          _hasDeferredUpdate = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }
        if (_rebasing) return true;
        return false;
      },
      child: child,
    );
  }
}
