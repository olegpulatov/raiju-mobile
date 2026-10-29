# spark voice

## user intent and scope

Spark is Iskra with remote seams: voice runs on phone, coding agent runs on workstation, one connected conversation. Spark personality is a focused, direct collaborator. Preserve addressing by editable user name, delegation behavior, and natural retelling. No invented summarization instructions.

Current requirements:

- Implement inside this mobile repository only. NO HOST CODE CHANGES, new host capability negotiation, host component, or replacement transport
- Use existing OMP collab connection, including sending two-model instructions. No host code changes does not mean no host messages
- Save local voice transcript in protected storage, including undelegated turns. Restore on app restart and same-session reconnect; local session saving must not depend on remote delivery
- Starting live mode sends nothing. Arm two-model instructions locally; include them in first real outgoing message: first delegation or user message exposing live conversation transcript. No standalone activation prompt or dummy remote turn
- Do not repeat instructions while marker remains in relevant context. Recheck after actual observable compaction, not arbitrary system messages or activity notices
- Document concrete missing collab information/guarantees rather than invent support or silently drop requested behavior

ADR-014 supersedes conflicting retention/host-extension clauses in ADR-013. ADR-016 supersedes whole-transcript forwarding and adds terminal-reply announcements and presentation preferences. Shared behavior is defined in the Raiju workspace's `docs/message-routing.md`, outside this repository. There is no further documentation approval gate; acceptance targets below are not claims that tests passed.

## bound conversation and saved transcript

- Voice binds to chat and connection where it starts; opening another chat does not rebind or stop it
- User and Spark can talk for many turns while remote work runs. Dialogue becomes visible without triggering remote execution before a real delegation/user send
- Bound timeline shows typed user, recognized speech, Spark replies, and remote assistant replies with distinct originator metadata
- `CollabReplica` remains authoritative remote-history mirror. Saved local voice overlay is separate; never insert local turns into remote snapshots
- Stable turn IDs, local sequence, delivery state, and host-entry anchors determine merge order, not phone/host clock comparison alone
- Navigation, replica updates, reconnects, and process restart retain voice turns, including pending dialogue. Protected storage failures remain visible; never reset keys/state or silently truncate pending text
- Collapse only matched delegation transport echo because its individual dialogue turns already appear. Ordinary collab prompts and Spark's natural retellings remain legitimate visible turns
- Future local-only conversations must also be saveable; do not add a local-only mode or speculative framework now

## automatic dialogue delivery

`SparkController` owns bound identity, finalized dialogue, sent boundary, pending local handoff IDs, active realtime delegation IDs, and bound-chat subscriptions.

Spark decides when to delegate without manual approval. Both Rust parser and Dart handler accept delegation events with empty text while retaining event ID. Empty text forwards eligible new context, not an assistant-only transcript replay.

Each delegation selects new user turns and useful intervening Spark conversation, in chronological order, with speaker labels:

```text
User: ...
Voice Assistant Spark: ...
```

Trim leading/trailing Spark turns around the selected user interval. Exclude post-delegation acknowledgement/progress and rewordings of main results even inside that interval. Keep every finalized turn in saved history independently. Compare the active request against each selected user turn using surrounding-whitespace trimming only; suppress an exact request overlap once, not distinct repeated human events. Preserve a divergent additional request once. No unnecessary `[Voice Conversation]` or `[Delegation Request]` headers. Machine correlation state is not conversational prose. Composer exposure uses the same selected-context policy.

Do not advance boundary on socket write. Failed/rejected/uncertain sends retain dialogue and report status. Deduplicate repeated realtime IDs and matched echoes. Existing host has no idempotent prompt retry contract: uncertain delivery must not be blindly replayed. Durable echo confirms storage, not automatically which run consumed it.

Persist an uncertain reservation before socket submission, then advance only on observed consumption plus unique durable echo. Explicitly unsent failures restore pending state. Retain later active-session delegation intents until earlier delivery is confirmed; this is not a retry queue for submitted prompts. Stopping releases native voice and waits for finalized local writes; restarting never replays uncertain batches automatically.

Final user transcription can arrive after delegation. Wait for an observed partial to finalize before sealing its package; otherwise track a bounded unresolved request/source association. An exact late source within that window must not become pending input for a later delegation. A divergent late source remains historical context for a later explicit request, not another automatic execution. Persist enough source/request metadata for restart and echo collapse without treating arrival order as a provider identity guarantee.

Completion and new native-session boundaries close unresolved source association, while completed aliases and uncertain sends remain durable. Without provider source linkage, an old final arriving only after completion cannot be distinguished from independent same-text speech; it can remain pending context. This cutoff preserves independent repeats, not universal exactly-once source attribution. See shared routing contract for upstream advice.

Voice interruption, mute, stop, and disposal never implicitly abort remote work. Navigation alone does not dispose global voice session. An already-started iOS voice session also continues when switching apps or locking the screen; Android retains stop-on-background behavior. New microphone startup remains foreground-only. Backgrounding before native startup completes cancels it. Explicit stop, actual audio interruption/media-services reset, detachment/disposal, and process termination still release resources. Returning to the foreground or restarting the app never starts microphone automatically. Mute discards microphone input without ending the session or incoming audio. Host permission questions still require explicit user answers. See ADR-015; physical background behavior requires separate device evidence.

Screen-lock audio and saved dialogue both continue after the device has been unlocked once since boot. The existing Keychain key and encrypted chat file migrate to after-first-unlock protection without changing their contents; failed migration/save preserves unsaved turns and blocks unreserved delegation. Voice does not restart after termination, and access before first unlock is not promised. See ADR-017.

## prompt assets and settings

Assets under `lib/spark/prompts/`:

- `spark-live-instructions.md`: focused Spark persona and Iskra delegation instructions, adapted only for Spark/mobile/remote seams
- `spark-context-addition.md`: append-only context-sharing addition, no unnecessary template machinery
- `spark-main-agent-directive.md`: user/Spark/remote coding-agent setup, sent with first real outgoing message after live starts
- `spark-agent-final-message.md`: existing internal final-response mechanism

Expose all participating prompt text and editable user name, default `User`, through existing protected settings storage. Persist tool visibility preference. Stable markers and machine IDs stay outside editable prose. Preserve upstream provenance/licenses; upstream `pure-voice.md` does not introduce separate mobile mode.

Markdown assets and synchronous editable defaults have a parity test. Rendered instructions and context delimiters share the startup limit; reject an oversized complete configuration rather than truncate persona. Existing edited presets are never replaced merely because their IDs match an old default.

Existing final signaling stays:

```text
"Agent Final Message":

<remote assistant's final prose>
```

Wrapper is internal Iskra signaling, not an extra displayed message or spoken label. Use `speakable` channel for final result and `commentary` for intermediate context; neither channel authorizes tool narration or invented summaries.

## source-aware context and budget

Startup, commentary, and final routing share source-aware extraction. Rendered `ChatMessage.text` is not source of truth: formatting can include generated tool descriptions such as `Using read…`.

- Include eligible assistant `type == "text"` content, normalized user text/recognized speech, and finalized Spark dialogue
- Include collaboration-carried user messages and prior Spark replies; do not blanket-exclude custom messages
- Exclude thinking, tool calls/results, generated status descriptions, tool metadata, directives, and other internal prompt additions; source identity matters alongside block type
- Do not seed overlay turns and their transport echo twice
- Follow Iskra budget: complete instructions/additions first; newest eligible history fits remaining space and remains chronological. One shared budget, no independent unlimited history or fixed message count
- Tool visibility changes presentation only, never what internal/tool material reaches Spark

## existing collab interaction and limitations

Inspected OMP reference `f225a978e7` read-only. `packages/coding-agent/src/collab/protocol.ts` exposes existing prompt/event/entry frames. `host.ts:875-907` processes prompt as `collab-prompt`, `display: true`, user-attributed, with steering behavior. `packages/wire/src/index.ts` defines prompt text/images and collab attribution `details.from`.

- Existing `event` frames already carry `message_end.stopReason`, `agent_end.messages`, and `agent_end.isTerminal`. Preserve these in mobile rather than flattening them away
- Existing prompt has no hidden/non-turn injection flag. Append marked two-model directive to first real typed/delegated message; hide internal addition in mobile rendering and Spark context. Host can still display it as part of user prompt. No standalone activation turn is sent
- Existing prompt has no host request ACK, idempotency key, handoff ID, or explicit run-consumption notification. Agent lifecycle events have no host run ID. Local IDs must not be described as host guarantees
- Observe exact matching prompt consumption/content and durable entry identity when available. Never equate next `agent_start`, latest assistant reply, wall-clock timing, or any completion after send with ownership
- If available evidence cannot establish consumption/continuity, keep pending/uncertain status and do not forward unrelated final. Reconnect cannot manufacture missing run evidence
- `details.from` is display attribution, not unique device identity. Byte-identical prompts from indistinguishable peers cannot be proven local. A continuation may finish with `agent_end.messages` that no longer includes the original consumed input; `isTerminal: false` alone also covers queued follow-ups/IRC work and does not establish request identity. Without matching terminal evidence, keep transcript and suppress automatic retelling
- Source cache is bounded, but saved voice turns are not silently trimmed with it. Preserve confirmed echo remainders and display anchors independently. Capacity/storage failures remain visible and preserve existing saved state
- Actual compaction entries may be observed in raw history; activity notices alone do not establish boundary. Missing compacted history can limit marker certainty; document observed limits, not hypothetical capabilities

These are transport constraints to report to user, not authorization to change OMP or remove participating instructions.

## result routing

- Route `stopReason == "toolUse"` visible assistant prose as commentary only after matching delegation consumption in observed run
- Terminal completion uses matching run's final visible assistant prose, not whole chat's latest message
- `agent_end.isTerminal == false` does not trigger final retelling
- Forward final once through existing wrapper, `speakable`, and correct realtime delegation ID. Appends keep delegation scope
- Manual typing can steer work; unrelated or unproven completion cannot satisfy pending Spark handoff
- A separate default-on `announceTerminalReplies` preference lets active bound voice present newly observed terminal/main replies without claiming delegation ownership. Expose an off switch in settings and chat quick controls. Do not replay bootstrap/reconnect history or old backlog on enable, and never attach an unrelated final to a pending delegation ID
- Terminal user text is already submitted work. Any voice context for it must identify that fact; a resulting Spark retelling is never forwarded back into main

## integrated presentation

Automatic delivery tracks pending dialogue and uncertain sends; it has no manual handoff-proposal or reply-sharing workflow.

Move useful transcript into original bound chat. Preserve voice strip, visualizer, minimized control, typed input, mute, and stop across navigation. Plain composer input in the active bound voice chat enters Spark as a saved typed user turn for the next delegation; it does not separately submit an immediate host prompt. Keep original Buzz chat composition/native visuals.

Expanded voice controls show the current recognized user partial without saving it as another turn. Input-level visualization may amplify visual responsiveness, not audio gain or fake activity during silence. Actual quiet playback needs route/device evidence before changing PCM or output gain.

Hide thinking by default through persisted `hideThinking`, independently of tool visibility. Existing chat menu exposes suitable thinking/tool/terminal-reply controls. These change presentation or announcement policy only; source history stays intact and thinking never reaches voice.

Prefer session names from existing host metadata and live title changes. Missing/generic names use stable `YY-MM-DD HH (name)` fallback based on session/connection creation, not last-message or render time; preserve explicit local labels.

Chat controls also offer confirmed local deletion: remove saved connection, draft, and local dialogue from this device, not remote OMP history. Stop bound local voice without aborting remote work. Do not navigate away or claim success until removal is persisted; a save failure keeps the chat available for recovery.

Tool modes cover inline and standalone tool calls/results:

- `show`: tools visible
- `hide`: tools hidden
- `hide-in-voice` (default): hidden only in active voice-bound chat; other chats unaffected

Do not mutate underlying remote records. Internal additions remain hidden in mobile regardless of tool mode.

## retained provider and native boundaries

`spark-core/` remains portable Rust subscription WebRTC/Opus transport, without Flutter, device microphone, OMP runtime, or recording filesystem. Swift owns AVAudioSession/AVAudioEngine, permissions, rate conversion, active-session background continuation, and interruption teardown. iOS declares the `audio` background mode for the existing `.playAndRecord` / `.voiceChat` session; no artificial silence or background task keeps an idle app alive. Apple device/simulator libraries, not musl.

Canonical subscription OAuth/private Codex realtime is not public Platform Realtime. No credential substitution, app identity/attestation spoofing, direct login/refresh, or extra provider. Broker owns refresh; access tokens stay ephemeral. Broker bearer is broad: OS secure storage, runtime configuration, no redirects, bounded responses, sanitized errors, HTTPS preference, explicit trusted-network HTTP consent.

C ABI remains `spark_create`, `spark_command`, `spark_poll_event`, `spark_string_free`, `spark_push_audio`, `spark_read_audio`, `spark_destroy`. Commands: connect, sendText (optional delegationId/channel), setMuted, stop. Normalized delegation has id/text including empty text. Input mono float32 16 kHz, output mono float32 48 kHz, bounded queues. No microphone/playback audio, PCM, SDP, or full broker snapshot is saved. Flutter channels remain `raiju/spark/methods` and `raiju/spark/events`.

## acceptance and commands

Verify extended dialogue before delegation, binding across navigation, first-real-message directive timing, empty and successive batches, no dropped pending turns, retry/echo deduplication, four-origin ordering through replica/restart, prose-only extraction and instruction budget, manual steering, unrelated/non-terminal final fencing, settings restoration, all tool modes, and no remote abort on voice stop. Persistent voice acceptance requires real store/controller recreation; native restart evidence is separate.

Run from this repository root:

```fish
just spark-test
just check
just spark-ios-smoke
just ios-smoke
```

Narrow commands: `spark-domain-test`, `spark-widget-test`, `spark-rust-test`, `spark-tooling-test`. `spark-ios-build debug` prepares Apple libraries; ordinary iOS workflows prepare required profile. `ios-run` launches original app. Generated evidence stays in ignored `.work/`.

Opt-in `spark-broker-auth-probe`, `spark-live-provider-probe`, and `spark-ios-live` require runtime credentials and `SPARK_LIVE=1`; HTTP also requires `SPARK_ALLOW_HTTP=1`. Never put credentials in argv/build flags/logs/screenshots. Existing `spark-ios-live` tests muted typed-response/audio-level/release path, not physical spoken uplink/acoustic quality. `live-smoke HOST` exercises real encrypted collab without a prompt; other live commands can mutate designated test session.

## provenance and evidence

Upstream Iskra reference: OMP `ed7c05c288b12e69f6986d8b379eb2c33f55e914`, `nexus/docs/iskra.md`, `packages/coding-agent/src/iskra/`, and `crates/pi-voice/src/live.rs`; Codex comparison `7498521d288b9b3b96ffba4eedf089d8d6e06a84`. Preserve MIT notices for copied OMP assets/code; add Apache notices if copying Codex rather than consulting. Current prompt source hashes belong in component provenance manifest.

[Verification](verification.md) describes repeatable checks and their coverage limits. Report individual run results in completion summaries or commit messages; keep generated logs under ignored `.work/`. Static/mocked, simulator, encrypted-host, live-provider, and physical-device checks support different claims.
