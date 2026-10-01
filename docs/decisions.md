# architecture decisions

Each accepted record states reason, rejected alternative, consequence, and reopening condition. Amend with a new superseding record; do not silently rewrite accepted product constraints.

## adr-001 — complete Buzz copy, then strip

Status: accepted, user-required

- Working app starts as complete tracked `block/buzz/mobile` at `e10a3607b2d4026ae57d9f32b6f6133077d21c7d`
- Baseline checkpoint: `ac84469`; byte-for-byte comparison against archive passed before modification
- Retain actual Dart part libraries, assets, original tests, platform projects, native visual bridges, and Apache notices
- Change data sources and startup paths in place. Unsupported actions retain their interface and explain unavailable behavior
- Rejected: fresh Flutter scaffold, curated widget extraction, handcrafted lookalikes, or archive-only preservation. These shift polishing cost back to future agents and violate user priority
- Consequence: some backend-coupled modules remain during extraction. Track inactive legacy code honestly; do not pretend retained code is removed or invoke it from active paths
- GUI simplification requires explicit user approval and visual evidence. Technical inconvenience alone does not reopen this decision

## adr-002 — native OMP collab for first chat

Status: accepted for first integration

- Use encrypted protocol v3 behind `HarnessClient`, separate from original Buzz UI models
- QR and paste feed one parser. Full and read-only links, welcome/history chunks, streaming, interruption, host questions, and reconnect use same path
- Consulted OMP checkout `34cdcc3698c89016a8df88503e60793f5c063ef0`, `packages/wire` protocol 3 and browser codec/client references
- Reason: shares actual running host conversation and preserves native GUI without another relay or agent runtime
- Rejected: embedding web chat as replacement GUI; terminal mirroring; rebuilding RPC relay before validating collab
- Consequences: host must remain live; `/new`, `/resume`, or room rotation invalidates old link; guest cannot change host model/session using host-only commands; no exactly-once prompt acknowledgement
- Never replay a prompt after reconnect. Show uncertain delivery and require transcript inspection before user retries
- Reopen if protocol limitations block concrete voice/media/harness needs, not for speculative abstraction

## adr-003 — persistent private mobile state

Status: accepted, supersedes initial memory-only proposal rejected by user

- Persist connections, drafts, list/labels, reconnect intent, appearance, and bounded cached history
- Encrypt private chat state with AES-GCM; keep encryption key in OS secure storage. Write atomically and serialize updates
- Restore local shell without network gate; reconnect previously active connections in background. Explicitly disconnected chats stay disconnected
- OMP remains durable conversation authority. Refresh replaces remote replica; cache enables offline reading, not queued writes
- Corrupt/unreadable state or unavailable key produces visible error without destructive reset
- Forget removes local state and capability. No credentials in logs, source, test fixtures, screenshots, or compiled build flags
- Reason: app restart while away from home must not require fetching a new link

## adr-004 — gateway is discovery, not chat transport

Status: assessed; integration deferred, not rejected

- `/srv/dev/oss/omp-session-gateway` v0.4.0 discovers stock OMP hosts, exposes metadata list/SSE, and brokers generation-bound View/Control links
- It does not provide transcript storage, a replacement relay, stable room identity across host session changes, native SDK, or voice
- Future path: authenticated gateway session selection → explicit launch capability → same native collab adapter
- Its supported boundary is loopback gateway behind TUN-mode Tailscale Serve HTTPS and exact identity allowlist. Do not expose with Funnel or an arbitrary proxy
- Native HTTP Origin/auth behavior and physical iOS reachability need qualification; PWA evidence is not native-app evidence
- Gateway capabilities should remain transient; persist gateway origin/session metadata and reacquire capability. This differs intentionally from user-saved direct join links
- No gateway deployment or auth weakening is needed for current QR/paste integration

## adr-005 — iOS-first executable acceptance

Status: accepted, user-required

- Use pinned Flutter 3.41.7 and original application, not a test-only replacement UI
- Simulator run/connect/talk workflow is a maintained product capability, not final-answer instructions left for user to discover
- Deterministic local protocol fixtures cover repeatable failure/stream/reconnect cases. Separate opt-in live smoke uses user-designated cheap OMP host
- Unit/widget success, simulator success, real-host interoperability, and physical-device success are separate claims
- Camera scanning, cellular transitions, and iOS suspension require physical-device evidence before claiming those scenarios verified

## adr-006 — compose future capabilities behind surfaces

Status: direction, not current implementation scope

- Keep UI, session transport, voice session/provider, and memory/persona responsibilities separate
- Reuse existing harnesses/tools whole when useful. Do not turn this repository into another coding-only harness
- Preserve voice/media controls now; attach real implementations in later slices
- Introduce abstractions when second concrete consumer requires them; avoid a speculative plugin framework

## adr-007 — explicit network effects for private chat

Status: accepted for text-only slice

- OMP capability grants collaboration access, not permission for transcript-controlled third-party media downloads
- Disable remote media loaders before native video/audio player creation; a disabled Dart HTTP client alone does not fence native networking
- Preserve original preview/player controls and placeholders. Reopen media loading only with explicit user interaction and a reviewed authorization/cache policy
- Obscure pasted capabilities, disable personalized keyboard learning, and clear submitted input. Saved capability lives only in encrypted chat store
- Search remains an explicitly unavailable Buzz surface; transient query history is memory-only and old plaintext history is retired
- Reason: private text and reusable credentials must not escape through retained UI side effects

## adr-008 — preserve dormant GUI, remove obsolete backend parts

Status: accepted extraction policy

- Full upstream checkpoint/archive is immutable reference; working tree is an adapted app, not a second immutable archive
- Remove unreferenced backend-only Dart parts when their parent implementation is stripped. Do not keep uncompilable orphan parts to satisfy an overbroad file-preservation heuristic
- Preservation guard uses exact backend exclusions, retains shared GUI coverage, and keeps frozen visual primitives/assets/native bridges byte-identical
- Dormant original visual declarations may have a narrowly explained unused-declaration annotation. No blanket analyzer exclusion or suppression of real errors
- Consequence: static cleanliness and GUI retention are compatible, while baseline still preserves original backend source for reference

## adr-009 — native restart evidence without embedded capabilities

Status: accepted acceptance-tooling boundary

- Controller recreation proves a narrower property than process restart. Native acceptance must restore production encrypted file/Keychain state in a distinct normal-entrypoint process
- Default-off debug probe preserves normal widgets, providers, storage, and transport. It emits only booleans, counts, and synthetic-data digests; no capability, draft, transcript, or title
- Acceptance requires available encrypted storage, exact synthetic draft/reply restoration, live reconnect, and unchanged host-history marker count. A changed simulator sandbox or missing probe fails acceptance; it is not a persistence success
- Live fixture receives capability once through loopback IPC on a trusted development machine. No capability in arguments, compiled flags, clipboard, screenshots, or persistent fixtures
- Rejected: compiling a real link into a test build, restoring from a copied test-only store, or claiming same-process controller recreation proves OS-level restoration
- Consequence: native test-runner install/teardown behavior is part of maintained workflow. Instrumented debug evidence remains separate from release-build and physical-device evidence

## adr-010 — native effect fences without replacing native menus

Status: accepted; narrow amendment to adr-008 baseline-only native freeze

- Keep original iOS attachment glass renderer, menu items, layout, and platform selection
- Companion mode passes an effects-disabled flag. Existing Swift action callbacks and Dart method callbacks reject camera/photo/video/file/voice effects and show unavailable explanation
- Exactly three original bridges need data/action edits: `NativeAttachmentPopover.swift`, `NativeAttachmentPopoverCoordinator.swift`, and `NativeAttachmentPopoverMenu.swift`
- Preservation guard pins their exact reviewed Git blob hashes; it does not broadly exempt them from freezing. Other frozen files still match `ac84469`
- Rejected: forcing Flutter fallback on supported iOS, deleting unsupported menu items, or allowing media effects merely to satisfy legacy-mode fixtures
- Original archive/checkpoint remains unchanged. Any later native edit requires source/visual review and explicit pin update

## adr-011 — component-owned mobile workflow

Status: accepted, user-required ownership split

- Keep Flutter directly in `mobile-raiju/`; existing `lib/`, platform, and test directories already separate code responsibilities. An additional `app/` wrapper adds navigation without a second implementation
- Mobile owns its run guide, vision, rules, ADRs, evidence, commands, scripts, environment example, ignored development state, upstream archive, and licenses
- Product root owns shared direction/rules and a thin `just mobile ...` dispatcher. Component rules inherit root rules in the monorepo; mobile implementation details do not constrain future components
- Maintained component checks must work without parent Git history or an original Buzz checkout. Read baseline files from the existing checksum-pinned archive, preserving all GUI classifications, backend exclusions, and exact reviewed native hashes
- Ship existing `pubspec.lock` and `ios/Podfile.lock` as tracked component files. Broad developer-global ignores previously hid them, making a fresh export fail locked dependency resolution; packaging preserves their existing bytes and versions
- Preserve original Buzz README/changelog/huddle notes under `upstream/` as historical references, not active run instructions
- Keep physical-device build/install/launch and private `IOS_DEVICE_ID` / `IOS_BUNDLE_ID` configuration. Root dispatch loads component-local direnv settings when present
- This changes file ownership and development paths only: no app identity, GUI, transport, encrypted state, or Keychain migration
- Rejected: another Flutter nesting layer, duplicated root/mobile workflows, speculative component stubs, or weakening preservation to avoid packaging the baseline
- Reopen nesting/shared-code choices when concrete additional implementations or consumers require them; repository extraction is not required by this decision

## adr-012 — portable Spark voice beside main chat

Status: historical accepted baseline; ADR-013 supersedes separate-conversation presentation, proposal/approval, manual reply-sharing, generic-persona allowance, and deferral of automatic correlated returns. Provider, native, auth, no-audio, and memory-only baseline constraints remain

- Spark is the product name for the mobile adaptation of OMP Iskra. Preserve separate voice session, editable personality/prompt collection, visualizer, start/stop/mute, typed input, and main-agent handoff; omit pure mode and every audio archive
- Keep reusable Rust voice transport/media in component-local `spark-core/`, without Flutter, device audio, OMP agent runtime, or private filesystem credential dependencies. iOS uses Apple Rust targets and an AVAudioSession/AVAudioEngine adapter, not musl. Future desktop reuse does not authorize desktop/root changes now
- First provider intentionally uses canonical private subscription OAuth/Codex realtime protocol. Public Platform Realtime is a different service/auth contract, not an interchangeable fallback. No app identity or attestation spoofing; service entitlement and live interoperability need their own evidence
- Use existing OMP auth broker through an isolated credential-provider boundary. Its bearer exposes broad broker credentials. Store it only in OS secure storage; require explicit trusted-network consent for HTTP, prefer HTTPS, reject redirects, keep provider access tokens ephemeral, and leave refresh-token ownership with broker
- Persist private prompt/configuration data separately from existing encrypted chat store. Voice transcript is bounded and memory-only for this slice; future memory can consume a text boundary. Neither microphone nor provider playback is saved
- Preserve original GUI through additive global strip/minimized control and settings entry, not a new chat implementation or fake main-chat users
- A voice delegation is an editable proposal. Explicit approval sends once to a selected live/control-capable chat with attribution, request ID, configurable main-agent instructions, and bounded finalized context. No hidden execution, automatic permission answers, or retry/replay
- Collab v3 cannot reliably correlate a Spark request with one completion across concurrent clients. Explicit reply preview/share replaces automatic speaking of the next main-agent message. A richer host correlation contract can reopen this choice; arrival order alone cannot
- Stop, background, failure, or disposal releases voice resources without stopping main-agent work. Restart never starts microphone automatically
- Rejected: direct private Codex-file access, a new unauthenticated token server, public API credential substitution, a universal provider framework, saved audio, or broad changes to original voice-note/native visual surfaces
- Detailed contracts, scoped acceptance, and source provenance: [Spark](spark.md). Additional providers, custom memory, automatic correlated returns, and physical audio qualification remain explicit follow-up boundaries, not silent claims

## adr-013 — connected Iskra companion with additive remote seams

Status: superseded in part by explicit user corrections in ADR-014. Memory-only retention, host-extension/capability requirements, and activation-send timing below are withdrawn; historical record is not authority over user intent

- Reason: user requires “exact as iskra, just remote seams”. Phone Spark and workstation OMP participate in one connected conversation; transport limitations must not redefine personality or require manual handoffs
- Supersedes ADR-012's disconnected transcript UI, editable handoff proposals/mandatory approval, and manual reply preview/share. Preserve focused Spark persona, Oleg addressing, delegation behavior, and existing final-response signaling
- Spark owns delegation timing. Voice binds to starting chat/connection, survives navigation, and remains conversational during remote work. Main composer can steer remote work; host permissions remain authoritative. Voice interruption/stop never implicitly aborts remote work
- `CollabReplica` remains remote-history authority. Separate per-chat memory-only overlay holds stable local voice IDs, originators, delivery state, sequence, and host-entry ordering anchors. Merge into bound timeline without modifying replica snapshots or duplicating correlated batch echoes
- Latest user refinement rejects treating chat visibility as authorization for new durable local voice storage. Navigation, replica refresh, and reconnect preserve live overlay. Persistence of undelegated dialogue across app restart remains explicit docs-review decision; delivered batches follow normal remote history retention
- Each delegation forwards all finalized user–Spark dialogue after acknowledged sent boundary, including empty-text delegation events. Meaningful extra request appears once. Stable handoff IDs and acknowledged delivery support deduplication; host storage and run consumption remain distinct states
- Startup instructions plus context share one budget. Use newest eligible user-facing conversation after complete instructions; source-aware extraction excludes thinking, tools, generated statuses, and internal additions on startup, commentary, and final routes
- Markdown prompt assets and participating editable settings preserve Iskra behavior, context-sharing addition, two-model directive, and final wrapper. User name defaults to Oleg; machine IDs/markers remain separate from editable text. Preserve upstream provenance/licenses
- Hidden, non-turn-triggering activation and automatic result ownership require additive versioned companion capability negotiated in hello. Mobile enables integrated delegation only for compatible host; unsupported status replaces unsafe visible-directive or heuristic-correlation fallback
- Host effective model context is authoritative: ensure directive on activation and before handoff consumption; idempotently search after actual latest compaction boundary, or chat start. Activity notices are not completed boundaries; mobile need not receive every durable compaction record
- Host support belongs in OMP `packages/coding-agent/src/collab/` on dedicated local integration branch/worktree. Reference checkout `/srv/dev/oss/oh-my-pi-omp` stays unchanged. Mobile owns client support, timeline, settings, and documentation; no new Raiju host component, desktop change, or transport replacement
- Commentary and terminal final prose route only after matching handoff consumption, under associated run and realtime delegation ID. Non-terminal or unrelated completion cannot trigger final retelling. Preserve `stopReason`, `agent_end.messages`, and `agent_end.isTerminal`
- Rejected: manual approval/share as target experience, invented summarization prompts, latest-message/timestamp completion matching, visible dummy activation turns, replica-injected local turns, and silent durable voice storage
- Consequence: mobile-only changes cannot establish integrated acceptance; bounded host extension and encrypted interoperability evidence are required after documentation review. Existing tests prove only their recorded baseline
- Full transport, prompt, retention, and acceptance contract: [Spark](spark.md). Reopen retention at docs review; revise wire details only while preserving capability gating, hidden context, lossless delivery, and explicit result ownership

## adr-014 — durable voice sessions, existing OMP only

Status: accepted, explicit user correction on 2026-09-24; supersedes ADR-013's memory-only voice retention and host-extension/capability requirements

- Voice dialogue belongs to saved chat transcript. Persist local voice turns, originators, and delivery state in protected local storage, including dialogue not yet delegated; restore on app restart and same-session reconnect
- Keep local voice records separate from authoritative remote replica and deduplicate remote echoes. Local session saving must not depend on remote delivery; future local-only conversations must also be saveable, without introducing that mode now
- NO HOST CHANGES. Implementation stays inside `mobile-raiju` and uses existing OMP transport/interfaces. No new host protocol, capability negotiation, dedicated integration branch, host component, or replacement transport
- Reason: existing OMP integration already exists; user rejected invented host work and memory-only conversations
- Inspect existing host source read-only to establish actual available behavior. Do not invent guarantees or silently substitute timestamp/latest-message ownership. Record concrete limitations where existing transport cannot establish required semantics
- Preserve connected conversation, Iskra personality, automatic delegation, prose-only context, integrated timeline, and no implicit remote abort. Reconcile remaining transport details against actual existing interfaces
- Starting live mode sends nothing by itself. Arm two-model directive locally and attach it to first real outgoing delegation/user message exposing live transcript. Do not repeat while marker remains in relevant context
- Existing collab cannot hide directive on host or inject it without triggering a turn; keep it in real prompt and hide internal addition on mobile. Missing ACK/run identity fields are documented limitations, not permission to change host, drop instructions, or claim false correlation
- User instructions take precedence over generated documentation. No further documentation-review gate is required

## adr-015 — continue active iOS Spark audio in background

Status: accepted, explicit user request on 2026-09-25; supersedes ADR-012's stop-on-background clause for iOS Spark only

- An explicitly started iOS Spark session continues capture/playback and its bound conversation when the user switches apps or locks the screen. Backgrounding does not stop or recreate that session
- Use Apple's `audio` background mode with the existing active `AVAudioSession` `.playAndRecord` / `.voiceChat` engine. No silent keepalive, background task loop, PushKit, or speculative CallKit integration
- New microphone acquisition still requires foreground startup. Backgrounding during incomplete permission/startup cancels it; returning to the foreground never starts or restarts voice automatically
- Mute continues to discard microphone input while preserving the session and incoming audio. Explicit stop, actual audio interruption, media-services reset, Flutter detachment/disposal, and process termination still release voice resources. These never abort remote OMP work
- Android retains stop-on-background behavior; foreground-service support is outside this iOS change. No host, transport, GUI, app-identity, or recording changes
- Reason: switching apps is normal during a live conversation, not an implicit request to end it. Existing native audio category already supports full-duplex background audio; both Dart and native lifecycle teardown must respect it
- Simulator lifecycle injection and native tests prove application policy, not physical-device suspension behavior. Qualify continued microphone uplink, playback, lock/unlock, mute, interruption, and explicit stop on a physical iPhone before claiming those scenarios verified
- Superseded on 2026-09-29 by explicit user correction: locked-screen dialogue and delegation must persist after first device unlock. Lazy first access migrates the existing saved-chat Keychain item in place from WhenUnlocked to AfterFirstUnlock (retaining device-backup behavior), and migrates the existing encrypted App Support file and its parent directory to CompleteUntilFirstUserAuthentication. Atomic replacements receive the same protection. Migration/protection errors fail closed before durable reservations; neither missing keys nor ciphertext are reset or exposed. Following reboot the device must first be unlocked; existing data must undergo migration while unlocked before the first locked-screen use. No microphone startup occurs in background. Physical iPhone lock/suspension/delegation qualification remains outstanding.
- Voice-turn capture time is encrypted with each turn and shown as its bubble clock and date label. Host-entry anchors and local sequence still determine placement; an evicted anchor can therefore place a newer-dated voice turn before older cached host history. Preserve that intentional order rather than sorting by clock or mislabeling the turn with an old host timestamp.
- Rejected: removing only the Dart stop handler, allowing background microphone startup, promising operation after force-quit, or playing synthetic silence to evade suspension
- Apple reference: https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioGuidelinesByAppType/AudioGuidelinesByAppType.html

## adr-016 — incremental voice routing without feedback

Status: accepted, explicit user correction on 2026-09-25; supersedes ADR-013's whole-dialogue forwarding rule and corresponding ADR-014-era implementation

- Saved conversation and main-agent input are different projections. Keep all finalized turns locally; forward only new eligible user context and meaningful conversation needed for the current delegation
- Never forward Spark's retelling of a main-agent answer back to that agent. Omit after-delegation acknowledgement/progress prose. Trim leading/trailing Spark turns around the selected user interval; retain useful conversational Spark turns between new user turns
- If delegation text exactly matches any selected user turn after surrounding whitespace is trimmed, include it once. Do not fuzzy-match or collapse distinct repeated human turns. Preserve divergent request text and order
- Handle delegation-before-final-transcript ordering. Already-dispatched speech must not become a new pending request merely because its final transcript arrived late. Uncertain sends remain quarantined; no blind replay or fabricated ACK
- Existing voice protocol lacks a guaranteed source-turn link on delegation. Wait for known partials; otherwise associate only within a bounded fallback window. Completion/new native-session boundaries close unresolved association to preserve independent repeated speech. A truly late unlinked final after completion remains ambiguous and may remain pending; universal exactly-once attribution requires upstream source identity. Preserve completed aliases and uncertain dispatch markers
- User-derived delegation retains user attribution in the timeline. Transport echo must not become another user request, and generated request text must not be mislabeled as independent Spark speech
- Observe new terminal-origin conversation while voice is active. Add a default-on preference for spoken external replies; external results remain separate from correlated delegation completions. Do not replay bootstrap history, tools, thinking, or internal additions as new speech
- Hide thinking by default, with persisted presentation preference and suitable quick controls in existing chat menu. Display preference never changes voice filtering or source data
- Prefer real host session names when existing collab data provides them. Otherwise show a stable connection timestamp using `YY-MM-DD HH (name)` rather than indistinguishable generic chat names
- Surface live recognized words without creating a second saved transcript. Improve visual activity responsiveness when safe; do not apply speculative output gain that may clip or damage audio
- Shared client-neutral routing contract belongs at `docs/message-routing.md` in repository root. Mobile owns its implementation; concurrent desktop work is not permission to edit or stage desktop files. OMP reference remains read-only, with differences/advice documented rather than patched
- User reported background voice working on device; record as user evidence, not an agent-executed physical qualification

User addendum, 2026-09-25: expose local chat deletion with confirmation in chat controls. Delete the device's saved connection, draft, and local transcript; do not delete remote OMP history or abort remote work. Stop local voice if bound to the deleted chat. Persist removal and surface save failures rather than presenting an unsuccessful deletion as complete.

## adr-017 — locked-screen saved dialogue and typed live input

Status: accepted, user correction on 2026-09-29; supersedes ADR-015's locked-device storage limitation

- After first device unlock, already-started iOS voice must save local dialogue and reserve delegations while screen is locked. Keep AES-GCM encryption and existing key/ciphertext; migrate existing Keychain item and protected file in place to after-first-unlock accessibility. No microphone auto-start, key replacement, host change, or Android background promise
- If protection migration or a save fails, keep dialogue in memory and block delegation instead of sending an unreserved request. A device not yet unlocked since boot and a terminated app remain outside this guarantee
- Each newly finalized local voice turn keeps its own capture time for chat display across refresh and restart. Historical turns without that field retain their previous fallback
- During active voice bound to the current chat, plain typed composer input goes to Spark and remains eligible for its next delegation, not an immediate second host prompt. Without matching active voice, the existing chat send path remains
- Manual bare collaboration codes use an editable saved relay origin; complete QR/full links use their embedded endpoint. New connections pin their selected relay for reconnect, and legacy saved bare codes use only a validated previously observed endpoint. Do not silently redirect a saved chat when the preference changes

## adr-018 — standalone mobile repository and workspace submodule

Status: accepted, user-required extraction on 2026-09-30; supersedes ADR-011's monorepo path

- Mobile lives in standalone `raiju-mobile` repository and appears in the Raiju workspace as submodule `mobile/`, replacing the former tracked `mobile-raiju/` directory
- Keep Flutter, commands, docs, licenses, immutable upstream archive, and application lockfiles together. Exclude generated outputs, private environment files, and local evidence from Git
- Publish the complete mobile source at product version `v0.0.1` (`pubspec.yaml` remains `0.0.1+1`); workspace pins the published mobile commit
- Shared routing contract remains in Raiju's `docs/message-routing.md`. Standalone mobile commands require neither that file nor parent Git history
- Historical path and checkpoint references remain provenance, not current checkout instructions. No app identity, GUI, transport, encryption, or private-state migration changes

## adr-019 — offline licenses in existing settings

Status: accepted, explicit user authorization on 2026-10-01

- Add one Licenses action to the existing settings list, not a new top-level tab. Keep original GUI, logo, application identity, and immutable upstream archive
- Flutter's standard license page remains the viewer. Register local legal assets and native notices lazily through `LicenseRegistry`; opening licenses works without network access and startup reads no legal files
- Explicitly package Buzz Apache, full emoji-mart MIT, OMP MIT, Spark MIT, voluntary NOTICE, and Geist/Inter OFL texts. Flutter keeps generating Dart/SDK/engine notices through its existing `NOTICES.Z` path
- Flutter 3.41.7 only reads package-root `NOTICES` or `LICENSE` (plus declared additional license files); it does not discover local font licenses, Cargo sources, or CocoaPods binary notices. Supply those separately instead of replacing automatic notices
- Check in native notice output, refreshed explicitly after native dependency changes. No new dependency, runtime fetch, repeated global test, or license gate on normal development/builds
- Native inventory covers the union of three Apple Cargo dependency graphs and installed Runner pods, including bundled Opus, ring legal materials, and Google ML Kit embedded notices. Names, versions, source references, hashes, and missing-text entries remain inspectable in the generated artifact
- Exact `asn1-rs-impl 0.2.0`, `webrtc 0.17.2`, and `yasna 0.5.2` packages declare an Apache-2.0 alternative but omit full license files. Select that alternative and reproduce the standard text from installed `asn1-rs 0.6.2/LICENSE-APACHE`, retaining manifest/VCS/text provenance. Do not invent MIT copyright holders
- Google ML Kit/MLImage podspecs declare copyright-only notices, not an open-source grant. Preserve those declarations, full available embedded open-source notices, and a captured official ML Kit terms page with its incorporated Google APIs terms link. This is attribution delivery, not legal approval or evidence that app redistribution is forbidden
- Reopen only for concrete new dependencies, changed upstream terms, or a new distribution platform; Android's transitive Gradle-native inventory is not established by this iOS delivery
