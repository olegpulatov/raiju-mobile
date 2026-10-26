# mobile working contract

These rules govern this repository. When checked out as Raiju's `mobile/` submodule, they extend shared workspace rules; paths below are relative to this repository root. Keep mobile implementation and administration here, with Flutter directly at repository root.

Read `VISION.md`, `docs/decisions.md`, and `docs/development.md` before nontrivial work.

## relay and interface requirements

- Prioritize working real-relay flows and logical menus. Private-VPN relay access is an accepted deployment assumption; do not add daemon trust gates
- Use only a user-designated test relay/profile for integration checks. Do not restart, reconfigure, or modify the server or interfere with unrelated workers
- Verify relay failures against the designated real server, not only synthetic workers. Persist endpoint and last profile independently of chats
- Relay endpoint/port and integration profile are runtime configuration (CLI/env/direnv), not hardcoded development values. No relay checkout location is required to connect
- Relay identity must work with macOS and NixOS hosts, including arbitrary remote path aliases; do not add platform-specific path rewriting
- Active Raiju logos use canonical sources from the Raiju workspace's `brand/`; preserve upstream attribution and inactive reference assets
- Approved GUI adaptations include removal of obsolete identity/invite/settings-chat controls, grouped menus/chats, local search, Raiju branding, Material/green fresh defaults, folded Spark startup, message text selection before reactions (actions via selection toolbar More), optional chat avatars hidden by default, draggable folded Spark controls, and detached-reader scroll anchoring
- Commit separate features separately. These requirements take precedence over conflicting original preservation rules below

## non-negotiable product constraints

- Complete Buzz mobile copy is working base. Strip backend behavior in place; never scaffold or selectively recreate GUI
- Preserve actual screens, controls, assets, animations, native iOS visual bridges, QR, appearance choices, and original UI tests. Unsupported actions may be disabled, not silently removed
- No login gate. Persist mobile connections, drafts, and preferences across restart. iOS is primary acceptance platform
- Apply user corrections immediately and stop conflicting work. Update lasting requirements where needed, not a chronological conversation log
- Resolve demonstrated review conflicts with these invariants before continuing; explain rejected concerns in the completion summary rather than appending a documentation log

## connected Spark requirements

- Read `docs/spark.md` for voice work. ADR-013 supersedes ADR-012's disconnected conversation, mandatory handoff approval, and manual reply-sharing policy
- Durable local voice transcripts and NO HOST CHANGES supersede conflicting ADR-013 clauses
- User intent outranks generated docs and past decisions. Starting live sends nothing: attach two-model instructions to first real outgoing delegation/user message exposing live transcript, then deduplicate against relevant context. No new docs-review gate
- Preserve focused Spark persona, Oleg addressing, delegation ownership, and natural retelling. No invented summary instructions
- Bind voice to chat and connection where it starts. Navigation does not rebind or stop voice. Show typed user, recognized speech, Spark replies, and remote assistant prose with distinct originators in bound timeline
- Keep local voice overlay separate from authoritative `CollabReplica`, but persist it in protected local storage. Voice turns, including undelegated dialogue, must survive app restart, same-session reconnect, navigation, and replica updates. Future local-only sessions must also be saveable; no local-only mode is added now
- Delegation forwards incremental, selected context, not the entire saved transcript. Never replay already-dispatched user turns or Spark's backend retellings/after-delegation acknowledgements. Suppress exact request-versus-user overlap without deduplicating distinct repeated human turns. Preserve useful Spark conversation between selected user turns, not leading/trailing filler
- Spark receives user-facing prose only, never thinking, tools, generated tool descriptions, or internal prompts. Complete instructions consume startup budget before newest eligible history
- Implement only inside this mobile repository, using existing OMP transport and supported interfaces. Do not add host capability negotiation, host directives API, run-correlation protocol, or any other host change
- Inspect existing host interfaces read-only when needed; do not invent capabilities or silently replace missing semantics with unsafe heuristics. Record concrete transport limitations with mobile implementation evidence
- No new Raiju host component, replacement collaboration transport, desktop changes, pure-voice mode, or implicit remote abort on voice interruption/stop. Automatic delegation does not grant automatic answers to host permission questions
- Active iOS Spark audio continues across app switching and screen lock (ADR-015). New microphone startup stays foreground-only; background continuation never authorizes automatic restart after interruption or process exit. Android background support is not implied
- Concurrent desktop implementation may share this checkout. Own mobile changes only; shared routing documentation may define client-neutral behavior, but do not edit or stage desktop work. Existing unrelated mobile changes must also be preserved
- New terminal-origin conversation must be observable by active bound voice through a user-controlled preference, without inventing delegation ownership or replaying old history
- Hide thinking by default as presentation only; retain source data and keep thinking out of voice regardless of display preference. Prefer real session titles and useful live recognized-speech feedback

## version and build identity

- Keep mobile product version in `vX.X.X` form, with component-local bump command; keep Flutter's platform build number intact unless deliberately releasing a new build
- Capture source commit hash and build-start time (`YY-MM-DD HH:MM`) during build, and show version, commit, and time together in the existing settings GUI. Mark uncommitted mobile source as dirty without blocking development builds or tests. Do not derive build time from app launch or displayed commit from later checkout state
- Verify bump command and actual build metadata on a maintained build path; manual confirmation is sufficient for this narrow version workflow

## execution

- Keep complete upstream checkpoint `ac84469`, bundled archive, and provenance manifest immutable. Standalone checks use the checksum-pinned archive, not parent Git history
- Prefer narrow data/provider changes over replacing widget build trees. Any visual change needs before/after evidence; deletion needs explicit rationale
- Keep new transport/storage code independent of Buzz protocol. Inactive legacy code must not make network calls or be described as removed
- Preserve licensing and add changed-file notices to modified upstream files
- No secrets in source, examples, command logs, snapshots, screenshots, or compiled flags. Use synthetic capabilities in fixtures
- Native preservation exceptions use exact reviewed adapter hashes (ADR-010). Never regenerate pins automatically to hide renderer changes

## evidence before completion

- Run targeted production-seam tests, static analysis, preservation gate, and relevant original UI regressions
- Run actual iOS simulator journey for user-facing changes: launch without login, connect, send, receive, restart/restore
- Protocol changes require encrypted interoperability check; persistence changes require controller/store recreation check
- Inspect screenshots; tests alone do not establish visual preservation. Do not automatically bless new goldens
- Report exact checks and failures in completion summaries or commit messages; keep generated logs under ignored `.work/`. Distinguish simulator, live host, and physical-device evidence
- Keep docs focused on current behavior, repeatable instructions, architecture rationale, and coverage limits. `docs/verification.md` is a check guide, not a per-run diary
- Leave maintained commands to run app, connect, and talk. Do not finish with only “done” or unexecuted instructions
- Commit verified scoped changes and check git status. Preserve unrelated user work; never stage it merely to make status look clean
- Do not expand into voice, gateway deployment, or other harnesses without a concrete scoped request
