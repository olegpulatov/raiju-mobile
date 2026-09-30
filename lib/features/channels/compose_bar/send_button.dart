part of '../compose_bar.dart';

// MODIFIED FOR RAIJU: retains the Buzz send control with a stable automation
// key; enabled state now comes from the OMP companion snapshot.

class _SendButton extends StatelessWidget {
  final bool isSending;
  final bool isDisabled;
  final VoidCallback onTap;
  final Key? automationKey;

  const _SendButton({
    required this.isSending,
    required this.onTap,
    this.isDisabled = false,
    this.automationKey,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: IconButton(
        key: automationKey,
        onPressed: (isSending || isDisabled)
            ? null
            : () => _runComposerAction(onTap),
        style: IconButton.styleFrom(
          backgroundColor: context.colors.primary,
          disabledBackgroundColor: context.colors.primary.withValues(
            alpha: 0.5,
          ),
          shape: const CircleBorder(),
        ),
        padding: EdgeInsets.zero,
        icon: isSending
            ? BuzzLoadingIndicator(
                size: 18,
                color: context.colors.onPrimary,
                semanticLabel: 'Sending message',
              )
            : Icon(
                LucideIcons.arrowUp,
                size: 18,
                color: context.colors.onPrimary,
              ),
      ),
    );
  }
}

String _formatUploadError(Object error) {
  return error.toString().replaceFirst('Exception: ', '');
}
