// MODIFIED FOR RAIJU: video preview geometry is retained, while remote video
// decoding/fetch is disabled for the current text-only OMP slice.
part of '../message_content.dart';

/// A decoded, paused video surface used as a posterless message preview.
class LoadedVideoPreviewFrame {
  /// Widget backed by the initialized native video texture.
  final Widget child;

  /// Aspect ratio reported by the video decoder.
  final double aspectRatio;

  final Future<void> Function() _dispose;

  /// Creates a loaded preview frame with its resource cleanup callback.
  const LoadedVideoPreviewFrame({
    required this.child,
    required this.aspectRatio,
    required Future<void> Function() dispose,
  }) : _dispose = dispose;

  /// Releases the native decoder and any downloaded temporary file.
  Future<void> dispose() => _dispose();
}

/// Loads a paused first-frame surface for a video URL.
typedef VideoPreviewFrameLoader =
    Future<LoadedVideoPreviewFrame?> Function(String url);

/// Loader used when an older video event has no NIP-71 poster URL.
final videoPreviewFrameLoaderProvider = Provider<VideoPreviewFrameLoader>(
  (ref) =>
      (url) async => null,
);

class _MessageVideoPreview extends HookConsumerWidget {
  final String url;
  final ImetaEntry? imeta;
  final VoidCallback? onReply;

  const _MessageVideoPreview({
    required this.url,
    required this.imeta,
    required this.onReply,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rawAspectRatio = imeta?.aspectRatio ?? (16 / 9);
    final aspectRatio = rawAspectRatio.clamp(0.75, 1.91);
    final posterUrl = imeta?.posterUrl;
    final loadPreviewFrame = ref.watch(videoPreviewFrameLoaderProvider);
    final previewFrameFuture = useMemoized(
      () => posterUrl == null
          ? loadPreviewFrame(url)
          : Future<LoadedVideoPreviewFrame?>.value(),
      [loadPreviewFrame, posterUrl, url],
    );

    useEffect(() {
      var disposed = false;
      LoadedVideoPreviewFrame? loadedFrame;
      unawaited(
        previewFrameFuture.then((frame) {
          if (disposed) {
            if (frame != null) unawaited(frame.dispose());
          } else {
            loadedFrame = frame;
          }
        }),
      );
      return () {
        disposed = true;
        final frame = loadedFrame;
        if (frame != null) unawaited(frame.dispose());
      };
    }, [previewFrameFuture]);

    return Padding(
      padding: const EdgeInsets.only(top: Grid.half),
      child: GestureDetector(
        onTap: () => openVideoViewer(
          context,
          videoUrl: url,
          posterUrl: posterUrl,
          onReply: onReply,
        ),
        child: _MessageMediaPreviewFrame(
          previewKey: ValueKey('message-media-video-preview:$url'),
          backgroundColor: Colors.black,
          child: AspectRatio(
            aspectRatio: aspectRatio.toDouble(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (posterUrl != null)
                  MediaImage(
                    url: posterUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const _MediaPreviewFallback(
                      icon: LucideIcons.video,
                      label: 'Video preview unavailable',
                    ),
                  )
                else
                  FutureBuilder<LoadedVideoPreviewFrame?>(
                    future: previewFrameFuture,
                    builder: (context, snapshot) {
                      final frame = snapshot.data;
                      if (frame == null) {
                        return const _MediaPreviewFallback(
                          icon: LucideIcons.video,
                          label: 'Video attachment',
                        );
                      }
                      return ColoredBox(
                        key: ValueKey('message-media-video-first-frame:$url'),
                        color: Colors.black,
                        child: Center(
                          child: AspectRatio(
                            aspectRatio: frame.aspectRatio,
                            child: frame.child,
                          ),
                        ),
                      );
                    },
                  ),
                const ColoredBox(color: Color.fromRGBO(0, 0, 0, 0.28)),
                Center(
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      color: Color.fromRGBO(0, 0, 0, 0.6),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      LucideIcons.play,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
                Positioned(
                  left: Grid.xxs,
                  right: Grid.xxs,
                  bottom: Grid.xxs,
                  child: Text(
                    'Video',
                    style: context.textTheme.labelSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
