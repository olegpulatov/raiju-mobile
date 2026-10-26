// Modified for Raiju: companion drafts stay local, debounce encrypted writes,
// and flush when the composer leaves its chat.
part of '../compose_bar.dart';

Future<void> _sendTextOnlyDraft({
  required BuildContext context,
  required _MarkdownEditingController controller,
  required ObjectRef<Map<String, MentionCandidate>> mentionMap,
  required ObjectRef<int> draftRevision,
  required int submittedDraftRevision,
  required FocusNode focusNode,
  required VoidCallback clearComposer,
  required Future<void> Function() addMentionedNonMembers,
  required _ComposeDraftPayload payload,
  required _OutgoingMentions outgoing,
  required ComposeBarOnSend onSend,
  required ScaffoldMessengerState? messenger,
}) async {
  TextEditingValue? clearedDraftText;
  Map<String, MentionCandidate>? clearedDraftMentions;
  int? clearedDraftRevision;

  void restoreClearedDraft() {
    if (!context.mounted ||
        clearedDraftText == null ||
        clearedDraftMentions == null ||
        clearedDraftRevision == null ||
        draftRevision.value != clearedDraftRevision) {
      return;
    }
    mentionMap.value
      ..clear()
      ..addAll(clearedDraftMentions);
    controller.value = clearedDraftText;
    focusNode.requestFocus();
  }

  try {
    await addMentionedNonMembers();
    // Clear before optimistic insertion so the outgoing row and draft never
    // appear simultaneously during the send transition. If the user edited
    // while membership changes were pending, preserve that newer draft.
    if (context.mounted && draftRevision.value == submittedDraftRevision) {
      clearedDraftText = controller.value;
      clearedDraftMentions = Map<String, MentionCandidate>.of(mentionMap.value);
      clearComposer();
      clearedDraftRevision = draftRevision.value;
    }
    await onSend(
      payload.content,
      outgoing.pubkeys,
      mediaTags: [...payload.mediaTags, ...outgoing.referenceTags],
    );
  } on StateError {
    restoreClearedDraft();
    _reportSendCancelledByCommunitySwitch(messenger);
  } catch (error) {
    // The caller runs unawaited, so surface publish failures and restore the
    // sent draft unless the user has already started a new one.
    restoreClearedDraft();
    messenger?.showSnackBar(
      SnackBar(content: Text(_composeSendErrorMessage(error))),
    );
  }
}

void _useComposeDraftLifecycle({
  required ObjectRef<Map<String, MentionCandidate>> mentionMap,
  required WidgetRef ref,
  required _MarkdownEditingController controller,
  required bool companionMode,
  required String companionDraft,
  required String draftKey,
  required String channelId,
  required String? threadHeadId,
  required String draftIdentity,
  required ObjectRef<int> draftRevision,
  required ValueNotifier<List<_PendingAttachment>> attachments,
  required ObjectRef<int> uploadGeneration,
  required ObjectRef<UploadCancellationToken?> activeUploadCancellation,
  required ValueNotifier<int> uploadingCount,
  required ValueNotifier<bool> isSending,
  required ValueNotifier<_AttachmentSurface> attachmentSurface,
  required ValueNotifier<String?> uploadError,
  required _IOSAttachmentPopoverController iosAttachmentPopover,
  required VoidCallback onDraftIdentityChanged,
  // MODIFIED FOR RAIJU: companion drafts are encrypted/persisted by the
  // CompanionController and never touch Buzz identity or relay draft state.
}) {
  final lastDraftIdentity = useRef<String?>(null);
  useEffect(() {
    if (!companionMode) return null;
    final companion = ref.read(companionControllerProvider);
    return () => unawaited(companion.flush().catchError((Object _) {}));
  }, [channelId, companionMode]);
  useEffect(() {
    if (companionMode) {
      final companion = ref.read(companionControllerProvider);
      // The provider deliberately does not notify on local edits. Read the
      // latest draft if another hook dependency changes while typing.
      final draft = companion.chat(channelId)?.draft ?? companionDraft;
      if (controller.text != draft) {
        controller.value = TextEditingValue(
          text: draft,
          selection: TextSelection.collapsed(offset: draft.length),
        );
      }
      var lastPersistedText = controller.text;
      void persistCompanionDraft() {
        final text = controller.text;
        if (text == lastPersistedText) return;
        lastPersistedText = text;
        draftRevision.value += 1;
        companion.updateDraft(channelId, text);
      }

      controller.addListener(persistCompanionDraft);
      return () => controller.removeListener(persistCompanionDraft);
    }

    final identity = '$draftIdentity\u0000$draftKey';
    final shouldHydrate = lastDraftIdentity.value != identity;
    final identityChanged =
        lastDraftIdentity.value != null && lastDraftIdentity.value != identity;
    lastDraftIdentity.value = identity;
    final saved = ref.read(composeDraftsProvider.notifier).draftFor(draftKey);
    if (shouldHydrate) {
      mentionMap.value
        ..clear()
        ..addAll({
          for (final entry
              in (saved?.mentionKeys ?? <String, String>{}).entries)
            entry.key: MentionCandidate(
              pubkey: entry.value,
              displayName: entry.key,
              requiresRevalidation: true,
            ),
        });
    }
    if (identityChanged) {
      draftRevision.value += 1;
      onDraftIdentityChanged();
      uploadGeneration.value += 1;
      activeUploadCancellation.value?.cancel();
      activeUploadCancellation.value = null;
      uploadingCount.value = 0;
      isSending.value = false;
      attachmentSurface.value = _AttachmentSurface.closed;
      uploadError.value = null;
      unawaited(iosAttachmentPopover.dispose());
      final staleAttachments = attachments.value;
      attachments.value = const [];
      unawaited(_deleteOwnedAttachments(staleAttachments));
      controller.text = saved?.text ?? '';
    } else if (saved != null && controller.text.isEmpty) {
      controller.text = saved.text;
    }

    var lastPersistedText = controller.text;
    var lastBindings = <String, String>{
      for (final e in mentionMap.value.entries) e.key: e.value.pubkey,
    };
    void persistDraft() {
      final text = controller.text;
      if (text != lastPersistedText) {
        // Prune before the atomic snapshot, not in a later editor listener.
        // Code formatting hides a binding without deleting its literal.
        final retained = mentionOccurrences(
          text.replaceAll('`', ' '),
          mentionMap.value.keys,
        ).map((range) => range.label).toSet();
        // Whole-record taint has no literal to prune. Removing every @ is a
        // safe reset; unrelated edits must not turn lost keys into name lookup.
        mentionMap.value.removeWhere(
          (label, _) =>
              label.isEmpty ? !text.contains('@') : !retained.contains(label),
        );
      }
      final bindings = <String, String>{
        for (final e in mentionMap.value.entries) e.key: e.value.pubkey,
      };
      if (text == lastPersistedText && mapEquals(bindings, lastBindings)) {
        return;
      }
      lastBindings = bindings;
      lastPersistedText = text;
      draftRevision.value += 1;
      ref
          .read(composeDraftsProvider.notifier)
          .save(
            key: draftKey,
            channelId: channelId,
            threadHeadId: threadHeadId,
            text: text,
            mentionKeys: bindings,
          );
    }

    controller.addListener(persistDraft);
    return () => controller.removeListener(persistDraft);
  }, [
    controller,
    channelId,
    companionMode,
    companionDraft,
    draftKey,
    draftIdentity,
    onDraftIdentityChanged,
  ]);
}
