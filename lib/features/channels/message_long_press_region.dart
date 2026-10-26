// Modified for Raiju: text messages use platform selection, with message actions
// available from the selection toolbar instead of a competing long press.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

const _iosMessageLongPressDuration = Duration(milliseconds: 200);
const _maxMessageSnapshotDimension = 2048.0;

double _messageSnapshotPixelRatio(Size size, double devicePixelRatio) {
  final longestSide = size.longestSide;
  if (!longestSide.isFinite || longestSide <= 0) return devicePixelRatio;
  return math.min(devicePixelRatio, _maxMessageSnapshotDimension / longestSide);
}

/// Geometry and snapshot controls for a completed message long press.
///
/// Call [captureSnapshot] while the source is still mounted, then use
/// [setSourceHidden] to hide it behind the lifted preview. Restore the source
/// before the preview is disposed or dismissed.
class MessageLongPressDetails {
  /// The long-pressed source bounds in global logical coordinates.
  final Rect anchorRect;

  /// Captures the current source as an image for the lifted preview.
  ///
  /// The returned future can fail if the source is no longer mounted.
  final Future<ui.Image> Function() captureSnapshot;

  /// Hides or reveals the mounted source while its preview is displayed.
  final ValueChanged<bool> setSourceHidden;

  /// Creates the details passed to a completed long-press callback.
  const MessageLongPressDetails({
    required this.anchorRect,
    required this.captureSnapshot,
    required this.setSourceHidden,
  });
}

/// An [InkWell] whose long press is observed above interactive descendants.
class MessageLongPressInkWell extends StatelessWidget {
  final VoidCallback? onTap;
  final ValueChanged<Rect>? onLongPress;

  /// Handles a completed long press with snapshot and source-visibility access.
  ///
  /// When provided, this callback takes precedence over [onLongPress].
  final ValueChanged<MessageLongPressDetails>? onLongPressDetails;
  final BorderRadius? borderRadius;
  final Color? highlightColor;

  /// Leaves long presses to [MessageSelectionArea] inside this row.
  /// Other rows retain the original long-press interaction.
  final bool preferTextSelection;

  /// Identifies the [RepaintBoundary] to capture for the lifted preview.
  ///
  /// The key's current context must resolve to a boundary covering the message
  /// content. When omitted, this widget inserts and owns that boundary.
  final GlobalKey? snapshotKey;
  final Widget child;

  const MessageLongPressInkWell({
    super.key,
    this.onTap,
    this.onLongPress,
    this.onLongPressDetails,
    this.borderRadius,
    this.highlightColor,
    this.preferTextSelection = false,
    this.snapshotKey,
    required this.child,
  }) : assert(onLongPress != null || onLongPressDetails != null);

  @override
  Widget build(BuildContext context) {
    return _MessageLongPressRegion(
      onTap: onTap,
      onLongPress: onLongPress,
      onLongPressDetails: onLongPressDetails,
      borderRadius: borderRadius,
      highlightColor: highlightColor,
      preferTextSelection: preferTextSelection,
      externalSnapshotKey: snapshotKey,
      child: child,
    );
  }
}

/// Detects a message long press through Flutter's gesture arena.
///
/// Links, media, reactions, and other nested controls keep their normal tap
/// gestures, while a completed hold wins over descendant taps.
class _MessageLongPressRegion extends HookWidget {
  final VoidCallback? onTap;
  final ValueChanged<Rect>? onLongPress;
  final ValueChanged<MessageLongPressDetails>? onLongPressDetails;
  final BorderRadius? borderRadius;
  final Color? highlightColor;
  final GlobalKey? externalSnapshotKey;
  final bool preferTextSelection;
  final Widget child;

  const _MessageLongPressRegion({
    required this.onTap,
    required this.onLongPress,
    required this.onLongPressDetails,
    required this.borderRadius,
    required this.highlightColor,
    required this.externalSnapshotKey,
    required this.preferTextSelection,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final fallbackSnapshotKey = useMemoized(GlobalKey.new, const []);
    final snapshotKey = externalSnapshotKey ?? fallbackSnapshotKey;
    final sourceHidden = useState(false);

    void recognize() {
      final renderObject = snapshotKey.currentContext?.findRenderObject();
      if (renderObject is! RenderRepaintBoundary || !renderObject.hasSize) {
        return;
      }
      final anchorRect =
          renderObject.localToGlobal(Offset.zero) & renderObject.size;

      final detailsCallback = onLongPressDetails;
      if (detailsCallback == null) {
        onLongPress?.call(anchorRect);
        return;
      }
      final maxSnapshotPixelRatio = math.min(
        MediaQuery.devicePixelRatioOf(context),
        2.0,
      );

      Future<ui.Image> captureSnapshot() async {
        RenderRepaintBoundary? boundary;
        final renderObject = snapshotKey.currentContext?.findRenderObject();
        if (renderObject is RenderRepaintBoundary && renderObject.hasSize) {
          boundary = renderObject;
        }
        if (boundary == null) {
          throw StateError('Message snapshot is unavailable');
        }
        final snapshotPixelRatio = _messageSnapshotPixelRatio(
          boundary.size,
          maxSnapshotPixelRatio,
        );
        try {
          return await boundary.toImage(pixelRatio: snapshotPixelRatio);
        } catch (_) {
          await WidgetsBinding.instance.endOfFrame;
          final retryBoundary = snapshotKey.currentContext?.findRenderObject();
          if (retryBoundary is! RenderRepaintBoundary ||
              !retryBoundary.hasSize) {
            rethrow;
          }
          try {
            return await retryBoundary.toImage(
              pixelRatio: _messageSnapshotPixelRatio(
                retryBoundary.size,
                maxSnapshotPixelRatio,
              ),
            );
          } catch (_) {
            if (snapshotPixelRatio <= 1) rethrow;
            return retryBoundary.toImage(
              pixelRatio: _messageSnapshotPixelRatio(retryBoundary.size, 1),
            );
          }
        }
      }

      void setSourceHidden(bool hidden) {
        if (!context.mounted) return;
        sourceHidden.value = hidden;
      }

      detailsCallback(
        MessageLongPressDetails(
          anchorRect: anchorRect,
          captureSnapshot: captureSnapshot,
          setSourceHidden: setSourceHidden,
        ),
      );
    }

    final surface = InkWell(
      onTap: onTap,
      borderRadius: borderRadius,
      highlightColor: highlightColor,
      child: Opacity(
        opacity: sourceHidden.value ? 0 : 1,
        child: externalSnapshotKey == null
            ? RepaintBoundary(key: snapshotKey, child: child)
            : child,
      ),
    );

    final region = Semantics(
      onLongPress: preferTextSelection ? null : recognize,
      customSemanticsActions: preferTextSelection
          ? {const CustomSemanticsAction(label: 'More message actions'): recognize}
          : null,
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: {
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(
                  duration: !preferTextSelection &&
                          defaultTargetPlatform == TargetPlatform.iOS
                      ? _iosMessageLongPressDuration
                      : null,
                ),
                (recognizer) {
                  recognizer.onLongPressStart = (_) => recognize();
                },
              ),
        },
        child: surface,
      ),
    );
    // The standard-duration ancestor loses to the inner selection recognizer.
    // Outside text, a hold still reaches actions (including media-only rows).
    return preferTextSelection
        ? _MessageSelectionActions(showActions: recognize, child: region)
        : region;
  }
}

/// Selects only message content, not author metadata or reaction labels.
class MessageSelectionArea extends StatelessWidget {
  final Widget child;

  const MessageSelectionArea({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final actions =
        context.dependOnInheritedWidgetOfExactType<_MessageSelectionActions>();
    return SelectionArea(
      contextMenuBuilder: (_, state) =>
          AdaptiveTextSelectionToolbar.buttonItems(
            anchors: state.contextMenuAnchors,
            buttonItems: [
              ...state.contextMenuButtonItems,
              if (actions != null)
                ContextMenuButtonItem(
                  label: 'More',
                  onPressed: () {
                    state.clearSelection();
                    state.hideToolbar();
                    // Paint without the selection highlight before capturing
                    // the existing lifted message preview.
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (context.mounted) actions.showActions();
                    });
                  },
                ),
            ],
          ),
      child: child,
    );
  }
}

class _MessageSelectionActions extends InheritedWidget {
  final VoidCallback showActions;

  const _MessageSelectionActions({
    required this.showActions,
    required super.child,
  });

  @override
  bool updateShouldNotify(_MessageSelectionActions oldWidget) =>
      showActions != oldWidget.showActions;
}
