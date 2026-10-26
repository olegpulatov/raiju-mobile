# backlog

Known issues and improvement ideas, not accepted requirements. Move an item into `VISION.md`, `AGENTS.md`, or an ADR only after the owner accepts it. Remove items when done or rejected.

## known issues

- `just check` stops at its format step: `lib/raiju/licenses.dart` is not `dart format` clean on `main` (present before ADR-021 work). Later steps (`flutter analyze`, `just test`, Spark tests) must be run by hand until fixed
- `test/raiju/chat_avatar_test.dart` "companion chat keeps the original avatar badge and long-press rows" fails on `main` before and after ADR-021: chat-list row has no avatar `Stack`. Either the test or the grouped home list changed meaning; decide which is right
- `just test` stops at its first failing command, so the failure above hides the second test group and Spark tests in that recipe
- Legacy Buzz suites under `test/features/channels/` have about 400 failures, identical before and after ADR-021. Their fixtures feed Buzz relay providers, but chat detail now reads only `CompanionController`. Two composer-dock regressions ("keeps the followed tail anchored through composer and keyboard resize", "thread keeps its tail above a growing composer dock") are among them. Port relevant cases to companion fixtures or mark them as reference-only
- `test/features/channels/message_content_test.dart` expects a Nostr `Authorization` header for local file links; legacy expectation, fails on `main`
- Quick reaction row in message actions shows placeholder `?` glyphs for most emoji on iOS simulator (`.work/screenshots/raiju-message-actions.png`); only the heart renders. Renderer unchanged by ADR-021; not checked on device or against baseline
- Folded Spark control can cover row chevrons in settings and chat. Dragging solves it per user; a smarter default place or auto-hide while scrolling may help

## limits of ADR-021 changes

- Text selection works inside one message. Selecting across several messages needs one shared selection area over the timeline and careful interaction with the reversed list
- Timeline updates that arrive during an active drag or fling are shown after the gesture ends. Streaming text pauses visually while the finger moves
- If a refresh removes every visible row, there is no row to anchor; the list then falls back to its normal position
- Own send while scrolled up does not jump to the new message. Jump-to-latest shows it. Reverse in ADR-021 if this feels wrong in daily use
- Drafts save 400 ms after the last keystroke. A process kill inside that window, or before the asynchronous disposal save finishes, loses the newest characters
- Spark control position is stored per device, not per chat or orientation

## ideas

- Jump-to-latest button with unread count or "new reply" label while detached
- Double tap on message to open reactions, if it does not conflict with word selection in daily use
- Compact density preference: smaller author line and spacing, together with hidden avatars
- Spark control: tuck to a thin edge tab after idle, tap to restore; long press for mute
- Show recognized speech partials inside composer while voice runs, so typing and voice share one input place
- Quote selected text into composer from selection toolbar ("Reply with quote")
- Measure frame times while streaming long markdown replies; cache parsed markdown per message revision if rebuilds are heavy
