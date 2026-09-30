import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String source(String path) => File(path).readAsStringSync();

  test('active detail overflow uses the preserved channel actions sheet', () {
    final detail = source('lib/features/channels/channel_detail_page.dart');
    final sheet = source('lib/features/channels/channel_actions_sheet.dart');

    expect(detail, contains("import 'channel_actions_sheet.dart';"));
    expect(
      detail,
      contains(
        RegExp(
          r'onPressed: \(\) =>\s*showChannelActionsSheet\([\s\S]*?companionMode: true,',
        ),
      ),
    );
    expect(detail, isNot(contains('void showCompanionActions()')));

    expect(sheet, contains('bool companionMode = false'));
    expect(
      sheet,
      contains("title: Text(isMuted ? 'Unmute channel' : 'Mute channel')"),
    );
    expect(sheet, contains("title: const Text('Copy channel name')"));
    expect(sheet, contains("title: const Text('Copy channel ID')"));
    expect(sheet, contains("title: const Text('Disconnect')"));
    expect(sheet, contains('controller.disconnect(channel.id)'));
    expect(sheet, contains(RegExp(r'copyToClipboard\(\s*pageContext,')));
    expect(
      sheet,
      contains(
        RegExp(
          r"if \(companionMode\) \{\s*explainUnavailable\('Muting channels'\);\s*return;",
        ),
      ),
    );
  });

  test('companion message menus gate unsupported actions in every surface', () {
    final actions = source('lib/features/channels/message_actions.dart');
    final popover = source(
      'lib/features/channels/message_actions/message_action_popover.dart',
    );
    final reactionPopover = source(
      'lib/features/channels/message_actions/reaction_popover.dart',
    );
    final quickReactions = source(
      'lib/features/channels/message_actions/quick_reaction_row.dart',
    );
    final reactionTray = source(
      'lib/features/channels/message_actions/message_reaction_tray.dart',
    );
    final systemRows = source(
      'lib/features/channels/channel_detail_page/system_rows.dart',
    );
    final messageBubble = source(
      'lib/features/channels/channel_detail_page/message_bubble.dart',
    );
    Matcher explains(String callbackContext, String feature) => contains(
      RegExp(
        "_explainCompanionMessageAction\\(\\s*$callbackContext,\\s*'$feature',?\\s*\\)",
      ),
    );

    expect(
      messageBubble,
      contains(
        RegExp(
          r'final canManageMessage =\s*currentPubkey\?\.toLowerCase\(\) == pk',
        ),
      ),
    );
    expect(
      messageBubble,
      isNot(contains(RegExp(r'final canManageMessage =\s*!isCompanion'))),
    );
    expect(
      messageBubble,
      contains(
        RegExp(
          r'showMessageActions\([\s\S]*?canManageMessage: canManageMessage,[\s\S]*?companionMode: isCompanion,',
        ),
      ),
    );
    expect(actions, contains('bool companionMode = false'));
    expect(actions, contains('message.isSystem && !canManageMessage'));
    expect(systemRows, contains('final bool companionMode;'));
    expect(systemRows, contains('this.companionMode = false'));
    expect(
      systemRows,
      contains(
        RegExp(
          r'final userCache = companionMode[\s\S]*?: ref\.watch\(userCacheProvider\);',
        ),
      ),
    );
    expect(
      systemRows,
      contains(
        RegExp(
          r'companionMode[\s\S]*?\? null[\s\S]*?: ref\.read\(userCacheProvider\.notifier\)',
        ),
      ),
    );
    expect(
      systemRows,
      contains(
        RegExp(
          r'showMessageActions\([\s\S]*?companionMode: companionMode,[\s\S]*?\);',
        ),
      ),
    );
    expect(
      systemRows,
      contains(
        RegExp(
          r'onToggle: \(emoji\) \{\s*if \(companionMode\) \{[\s\S]*?return;[\s\S]*?toggleReaction\(ref, message, emoji\);',
        ),
      ),
    );
    expect(actions, explains('pageContext', 'Replies'));
    expect(actions, explains('pageContext', 'Message links'));
    expect(actions, explains('pageContext', 'Following threads'));
    expect(actions, contains('if (canManageMessage) ...['));
    expect(actions, contains('ClipboardData(text: message.content)'));
    expect(
      actions,
      contains('companionMode || ref.watch(reminderServiceProvider) != null'),
    );
    expect(actions, explains('rootContext', 'Reminders'));
    expect(actions, explains('context', 'Editing messages'));
    expect(actions, explains('context', 'Deleting messages'));

    expect(popover, contains('required bool companionMode'));
    expect(popover, explains('context', 'Replies'));
    expect(popover, explains('context', 'Message links'));
    expect(popover, explains('context', 'Following threads'));
    expect(
      popover,
      contains('companionMode || ref.read(reminderServiceProvider) != null'),
    );
    expect(popover, explains('context', 'Reminders'));
    expect(popover, explains('context', 'Editing messages'));
    expect(popover, explains('context', 'Deleting messages'));
    expect(
      popover,
      contains(
        RegExp(
          r'showMessageActions\([\s\S]*?companionMode: companionMode,[\s\S]*?\);',
        ),
      ),
    );

    expect(reactionPopover, contains('required bool companionMode'));
    expect(
      reactionPopover,
      contains(
        RegExp(r'_AnimatedReactionTray\([\s\S]*?companionMode: companionMode,'),
      ),
    );
    expect(
      reactionPopover,
      contains(
        RegExp(r'_QuickReactionRow\([\s\S]*?companionMode: companionMode,'),
      ),
    );
    expect(
      reactionTray,
      contains(
        RegExp(r'_AnimatedReactionTray\([\s\S]*?companionMode: companionMode,'),
      ),
    );
    expect(quickReactions, explains('pageContext', 'Reactions'));
    expect(quickReactions, contains("'More reactions'"));
    expect(
      quickReactions,
      contains(
        RegExp(
          r'if \(companionMode\) \{[\s\S]*?return;[\s\S]*?pageRef\.read\(channelActionsProvider\)\.addReaction',
        ),
      ),
    );
  });
}
