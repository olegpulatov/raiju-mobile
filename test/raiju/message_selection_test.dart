import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:raiju_mobile/features/channels/message_actions.dart';
import 'package:raiju_mobile/features/channels/message_content.dart';
import 'package:raiju_mobile/features/channels/message_long_press_region.dart';
import 'package:raiju_mobile/features/channels/timeline_message.dart';
import 'package:raiju_mobile/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _content =
    'hello **bold world**\n\nsecond paragraph with `inline code`'
    '\n\n```dart\nprint("selected");\n```';

Finder _paragraph(String text) => find.byWidgetPredicate(
  (widget) => widget is RichText && widget.text.toPlainText().contains(text),
);

Offset _firstWord(WidgetTester tester) {
  final paragraph = tester.renderObject<RenderParagraph>(
    _paragraph('hello').first,
  );
  final box = paragraph
      .getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 5))
      .first;
  return paragraph.localToGlobal(box.toRect().center);
}

Future<void> _pumpMessage(
  WidgetTester tester, {
  String content = _content,
  ScrollController? scrollController,
  ValueChanged<String>? onMentionTap,
  ValueChanged<String>? onChannelTap,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [savedPrefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => SingleChildScrollView(
              controller: scrollController,
              child: Column(
                children: [
                  const SizedBox(height: 120),
                  MessageLongPressInkWell(
                    preferTextSelection: true,
                    onLongPressDetails: (details) => showMessageActions(
                      context: context,
                      ref: ref,
                      message: TimelineMessage(
                        id: 'selection-message',
                        pubkey: 'assistant',
                        createdAt: 1000,
                        content: content,
                      ),
                      channelId: 'selection-chat',
                      canManageMessage: false,
                      companionMode: true,
                      anchorRect: details.anchorRect,
                      captureAnchorSnapshot: details.captureSnapshot,
                      onPopoverPreviewVisibilityChanged:
                          details.setSourceHidden,
                      onPopoverDismissed: () => details.setSourceHidden(false),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('author metadata'),
                        MessageSelectionArea(
                          child: MessageContent(
                            content: content,
                            mentionNames: const {'alice': 'Alice'},
                            channelNames: const {'general': 'general'},
                            onMentionTap: onMentionTap,
                            onChannelTap: onChannelTap,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 1600),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'non-text row area keeps a standard-duration actions fallback',
    (tester) async {
      await _pumpMessage(tester, content: '');
      final hold = await tester.startGesture(
        tester.getCenter(find.text('author metadata')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.byKey(const ValueKey('message-action-surface')),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 400));
      await hold.up();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('message-action-surface')),
        findsOneWidget,
      );
      Navigator.of(
        tester.element(find.byKey(const ValueKey('message-action-surface'))),
      ).pop();
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'tap leaves actions closed; long press selects; More opens actions',
    (tester) async {
      await _pumpMessage(tester);
      final text = _paragraph('hello').first;
      final paragraph = tester.renderObject<RenderParagraph>(text);
      final word = _firstWord(tester);

      await tester.tapAt(word);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('message-action-surface')),
        findsNothing,
      );

      await tester.longPressAt(word);
      await tester.pumpAndSettle();
      expect(
        paragraph.selections.single.textInside(paragraph.text.toPlainText()),
        'hello',
      );
      expect(
        find.byKey(const ValueKey('message-action-surface')),
        findsNothing,
      );
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Select All'), findsOneWidget);
      expect(find.text('More'), findsOneWidget);

      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('message-action-surface')),
        findsOneWidget,
      );
      expect(paragraph.selections, isEmpty);
      Navigator.of(
        tester.element(find.byKey(const ValueKey('message-action-surface'))),
      ).pop();
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Select All and Copy include formatted paragraphs of one message',
    (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _pumpMessage(tester);
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(copied, contains('print("selected");'));
      expect(copied, isNot(contains('hello')));
      await tester.pump(const Duration(seconds: 3));
      await tester.longPressAt(_firstWord(tester));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select All'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(copied, contains('hello bold world'));
      expect(copied, contains('second paragraph with inline code'));
      expect(copied, contains('print("selected");'));
      expect(copied, isNot(contains('author metadata')));
      expect(
        find.byKey(const ValueKey('message-action-surface')),
        findsNothing,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'selection handle extends through formatted message paragraphs',
    (tester) async {
      await _pumpMessage(tester);
      await tester.longPressAt(_firstWord(tester));
      await tester.pumpAndSettle();
      final first = tester.renderObject<RenderParagraph>(
        _paragraph('hello').first,
      );
      final last = tester.renderObject<RenderParagraph>(
        _paragraph('second paragraph').first,
      );
      final handle = first
          .getBoxesForSelection(first.selections.single)
          .last
          .toRect()
          .bottomRight;
      final secondParagraphOffset = last.text.toPlainText().indexOf('second');
      final target = last
          .getBoxesForSelection(
            TextSelection(
              baseOffset: secondParagraphOffset,
              extentOffset: secondParagraphOffset + 6,
            ),
          )
          .first
          .toRect()
          .bottomRight;
      final start = first.localToGlobal(handle);
      await tester.dragFrom(start, last.localToGlobal(target) - start);
      await tester.pumpAndSettle();
      final selected = tester
          .renderObjectList<RenderParagraph>(
            find.byWidgetPredicate((widget) => widget is RichText),
          )
          .expand(
            (paragraph) => paragraph.selections.map(
              (selection) => selection.textInside(paragraph.text.toPlainText()),
            ),
          )
          .join();
      expect(selected, contains('hello bold world'));
      expect(selected, contains('second'));
      expect(
        find.byKey(const ValueKey('message-action-surface')),
        findsNothing,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'finger scroll starting on text stays a timeline scroll',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await _pumpMessage(tester, scrollController: scroll);
      await tester.dragFrom(_firstWord(tester), const Offset(0, -250));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(100));
      expect(
        find.byKey(const ValueKey('message-action-surface')),
        findsNothing,
      );
      expect(find.text('More'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'mention, channel and markdown link taps keep their callbacks',
    (tester) async {
      String? mention;
      String? channel;
      await _pumpMessage(
        tester,
        content:
            'hello @Alice and #general\n\n'
            '[Open channel](buzz://channel/580ca78b-9dae-46f3-8854-bd671853ba32)',
        onMentionTap: (value) => mention = value,
        onChannelTap: (value) => channel = value,
      );
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('general'));
      await tester.pumpAndSettle();
      expect(mention, 'alice');
      expect(channel, 'general');
      await tester.tap(find.text('Open channel'));
      await tester.pumpAndSettle();
      expect(channel, '580ca78b-9dae-46f3-8854-bd671853ba32');
      expect(
        find.byKey(const ValueKey('message-action-surface')),
        findsNothing,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
