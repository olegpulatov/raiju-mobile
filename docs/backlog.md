# backlog

Known issues and improvement ideas, not accepted requirements. Move an item into `VISION.md`, `AGENTS.md`, or an ADR only after the owner accepts it. Remove items when done or rejected.

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
- Folded Spark control default place can cover row chevrons in settings and chat; pick a lower default or fade it while the list scrolls
- Show recognized speech partials inside composer while voice runs, so typing and voice share one input place
- Quote selected text into composer from selection toolbar ("Reply with quote")
- Measure frame times while streaming long markdown replies; cache parsed markdown per message revision if rebuilds are heavy
