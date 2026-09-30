# mobile raiju

Mobile surface for Raiju, a personal AI companion rather than a coding-only product. Reuse existing harnesses and tools; this component owns mobile interaction and local state, not desktop or an agent runtime. Spark provides voice and personality within the same connected conversation, behind a portable provider boundary; a shared memory engine remains outside current scope.

## current product

An iOS-first mobile client using the complete Buzz mobile application as its starting point. Open directly into chats; connect to an already-running OMP session by QR or pasted join link/token. The host executes the agent and tools. Mobile is another surface on the same conversation.

Android source remains preserved. iOS simulator is the primary local development and acceptance target; physical-device camera, backgrounding, and network transitions need separate evidence.

Spark is Iskra with remote seams: voice runs on phone, OMP coding agent runs on workstation, and both participate in one conversation. Voice stays bound to starting chat during navigation. Saved timeline includes typing, recognized speech, Spark replies, and remote assistant prose; undelegated voice dialogue survives restart too. Spark chooses delegation and naturally retells observed results without manual handoff/share. Preserve focused Spark persona, Oleg addressing, visualizer/mute/stop, and editable prompts. Starting live arms two-model instructions for first real outgoing message, never a dummy turn. Existing OMP transport is reused without host code changes; document missing wire guarantees. No audio recording or pure mode. User intent supersedes earlier checkpoint prose: [Spark](docs/spark.md), ADR-014.

An already-started iOS Spark conversation continues when switching apps or locking the screen. Explicit stop and real audio interruptions still end local voice; foregrounding never starts the microphone automatically. This does not promise survival after force-quit or Android background support. Physical-device background reliability requires separate acceptance evidence.

Delegation is incremental, not a replay of everything Spark said. Keep useful dialogue between new user turns, but exclude result retellings and delegation filler, and never resend already submitted speech because transcription arrived late. Active voice can announce new terminal replies through a user-controlled preference. Hide thinking by default, show live recognition clearly, prefer real session names, and allow confirmed local chat deletion without deleting remote work. Shared routing contract lives in the Raiju workspace at `docs/message-routing.md`, outside this repository.

## user preferences and invariants

- GUI preservation is primary: copy all, then strip backend behavior in place. Do not scaffold a replacement, selectively rebuild screens, or substitute generic widgets because extraction is easier
- Preserve existing layouts, typography, animations, navigation, menus, appearance controls, native iOS visual bridges, QR, composer, and reusable media/voice surfaces
- Unsupported actions may be disabled with an explanation. Their interface must not disappear merely because its backend is not connected yet
- Archive alone is not preservation: actual working application must descend from the complete source copy
- No account/login gate. Empty chats is a valid launch state. Connect is an action, not onboarding required to enter the app
- Phone must remain useful away from home and after process restart. Persist connections, chat list, drafts, appearance choices, and bounded offline history; restore and reconnect without repasting a link
- Credentials and private chat data stay protected at rest. Never put real join links in source, fixtures, logs, command output, screenshots, analytics, or compiled Dart defines
- Persisted state must not be silently reset on migration, corruption, missing key, or transient network failure. Surface recovery errors
- One remote session has one authoritative history: OMP. Reconnect replaces a replica; it never duplicates history or silently resends a prompt
- Disconnect stops reconnecting. Forget removes local saved state. Neither action stops the host session
- Host permission is authoritative. Read-only links cannot send or interrupt. Host questions require explicit user answers, never automatic approval
- Source Buzz relay/auth/push/Nostr behavior is not the product backend. Its inactive retained code is extraction debt, not a reason to call its services
- Live voice is the main interaction need in the Spark slice. Keep provider, personality, memory/context, and UI boundaries separable so a future backend change does not require replacing the GUI
- Terminal-on-phone is not current priority
- Architecture decisions and acceptance evidence must survive agent sessions. Record decisions rather than repeatedly reopening them or starting again

## sequence

1. Checkpoint complete upstream mobile source, assets, tests, and platform projects; prove baseline renders
2. Remove login and server startup paths, preserving existing screens and controls
3. Connect original chat data seams to OMP collab; preserve QR and paste
4. Persist and restore mobile state; verify iOS launch → connect → talk → restart
5. Add live voice behind separate provider/session boundary, reusing preserved surfaces
6. Add gateway-based session discovery, other harness adapters, memory/persona composition as concrete needs appear

Later steps are direction, not permission to expand current change.

## decisions

Accepted rationale and consequences: `docs/decisions.md`
Development and acceptance process: `docs/development.md`
Upstream provenance: `upstream/buzz-mobile.json`
