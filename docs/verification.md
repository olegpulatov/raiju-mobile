# verification

Commands and paths are now relative to the mobile component. Implementation acceptance below records `bd53565`, before the component ownership split; later layout verification is recorded separately.

## delivered slice

- complete Buzz mobile baseline `ac84469` remains recoverable; active app adapts original screens and native visual bridges in place
- app opens directly into original home shell, without Buzz login, relay, Nostr, push enrollment, or community startup traffic
- QR/paste joins OMP collab v3; original chat/composer supports text, streaming, interruption, read-only permissions, and explicit host questions
- private connections, drafts, and bounded history use AES-GCM file storage with OS-held key; appearance remains local
- reconnect replaces host replica and never automatically replays a prompt; explicit disconnect and forget remain distinct
- unsupported original controls remain visible or explicitly unavailable; voice, gateway discovery, and full Buzz backend replacement are outside this slice

## aggregate gate

Final `just check` passed after GUI repairs; `just ios-build` ran the same gate again:

- locked dependency resolution passed; no implicit package upgrade
- formatter passed for new code; modified adapters received narrow formatting cleanup
- full `flutter analyze --no-pub`: no issues
- active unit/widget suite: 113 passed, including eight focused GUI-repair cases
- preservation guard tests: 13 passed
- preservation scan: 301 original GUI files retained; 82 files match frozen baseline bytes and three native effect adapters match exact reviewed pins
- 52 adapted GUI files remain subject to source/visual review; no baseline or golden regeneration
- `just --list --unsorted`, `just --fmt --check`, and `git diff --check` passed
- `Podfile.lock`, `pubspec.lock`, and unrelated `.omp/config.yml` have no changes

Active suite covers startup, collab parser/codec/replica/client, encrypted storage, controller races/restoration, backend boundaries, original chat/composer/join/settings, local appearance, and retained home/QR/theme regressions. Focused cases cover original avatars/menus, unsupported native and Dart attachment callbacks, confirmed local-send animation/tail following, and distinct author grouping. Original Buzz backend tests remain reference material; no claim that removed server contracts pass.

Pristine baseline separately passed 22 original startup/home/QR/theme tests before extraction. That establishes baseline health, not current native-app behavior or pixel equivalence.

## real host

Executed against designated cheap OMP instance `3e977afc0ab857e3`:

- `just live-smoke`: writable encrypted handshake, initial history, clean close; no prompt sent
- `just live-chat-smoke`: one harmless marker prompt, durable assistant marker, clean close
- capability and private transcript were not printed or committed

## native acceptance

Environment: Flutter 3.41.7 / Dart 3.11.5, Xcode 26.3, iPhone 17 Pro simulator on iOS 26.3.

- `just ios-smoke` passed: original GUI connect/send/reply/offline flow, encrypted flush, and same-process controller/store recreation
- `just ios-live 3e977afc0ab857e3` passed: private capability transfer, real host join, durable reply, draft flush, then distinct normal-`lib/main.dart` process
- Normal-process probe required `storageAvailable=true` and confirmed restored encrypted session, exact synthetic draft/reply, and live reconnect; final rerun observed four saved chats and 14 messages
- Per-run host marker count remained 2 before/after restart: no automatic prompt resend
- Helper exited successfully after acceptance; retained app data and Keychain were not reset or replaced
- `just ios-build` produced signed debug simulator app without probe flags; `just ios-run` reached Flutter readiness and was detached
- Ruby 3.4.10 with isolated CocoaPods 1.16.2 resolved earlier native dependency failures without changing `Podfile.lock`

Earlier restart failure was resolved by consistent Xcode signing/bundle identity and retained-driver lifecycle. Final normal build has signing identifier `dev.raiju.mobile`, bound Info.plist, and sealed resources. Keychain access is established by actual restore, not inferred from file survival. Simulator's displayed entitlement dictionary was empty; this is not physical-device entitlement evidence.

## visual review

Inspected fresh synthetic captures from maintained native smoke:

- `.work/screenshots/raiju-home-light.png`
- `.work/screenshots/raiju-home-dark.png`
- `.work/screenshots/raiju-chat-light.png`
- `.work/screenshots/raiju-chat-dark.png`

Images show original home gradient/navigation, chat rows/header, composer, and restored draft in light/dark appearance. Source review retained original message/menu/avatar implementations; three Swift attachment edits change only data/action boundaries plus modification notices. No real capability or private transcript screenshots were taken in final live acceptance. These captures are review evidence, not newly blessed goldens.

## evidence boundaries

- tests and mechanical source retention do not establish visual equivalence across every original screen
- local-send animation uses best-effort author/text/time correlation, not an ACK; concurrent identical prompts from clients sharing name `raiju` cannot be uniquely attributed. Conversation and retry behavior do not depend on this visual hint
- restart probe uses normal entrypoint/providers/storage/transport, but is default-off debug instrumentation; not release-build evidence
- simulator camera scanning, physical iPhone deployment, cellular transitions, and background/suspension behavior are unverified
- Android source is retained; no Android runtime acceptance performed
- generated logs, screenshots, builds, and private runtime state remain outside committed evidence

## component ownership verification

Layout-only change after `8c5861e`; application code, native identity, transport, and storage behavior remain unchanged.

- Root `just check` passed: formatter, full analyzer with no issues, and 113 active app tests
- Final root `just mobile check-preservation` passed 18 tests, including corrupt-archive, empty/partial-baseline, narrowed-frozen-set, and symlinked-CLI regressions. Baseline coverage must contain 301 GUI files with 85 frozen; scan retained these counts, three reviewed adapters, and 52 adapted GUI files
- Before baseline-count hardening, exported staged component into a temporary directory without parent Git or private configuration. Component `just check` passed its full formatter/analyzer, 17 preservation tests, and 113 app tests; command listing and locked installation also passed. A direct absolute-path CLI invocation from an unrelated directory ran the real scan
- Initial standalone installation exposed globally ignored lockfiles. Existing `pubspec.lock` and `ios/Podfile.lock` are now tracked without byte/version changes; exported installation preserved both locks
- Root dispatch passed with relocated private direnv settings and with no component `.envrc`. Dry runs preserved physical-device build/install/launch paths and argument boundaries; private device settings remain ignored
- Both justfiles passed formatting checks; scoped diff checks passed. Archive SHA-256, provenance manifest, license texts, original Buzz notes, SDK resolver, and environment template match pre-move bytes
- First simulator run failed because cached `objective_c.framework` targeted physical iOS instead of simulator. Cleaning generated Flutter outputs and rerunning component `just ios-smoke` passed connect/send/reply/offline/restore acceptance with relocated CocoaPods cache
- Four fresh synthetic screenshots were written under component `.work/screenshots/`; home-light and chat-dark captures were inspected. No visual source changes or new goldens
- Root `just mobile ios-run` reached Flutter readiness with normal uninstrumented app, then detached successfully with exit code 0
- Real-host chat and physical-device installation were not rerun for this layout change. No app data, encryption key, capability, or private environment value was reset or replaced

## Spark implementation checkpoint

Scope: mobile only; portable `spark-core/`, iOS audio bridge, separate Spark transcript, prompt collection/broker settings, compact/minimized controls, and explicitly approved OMP handoff. Design and contracts: [Spark](spark.md), adr-012. Desktop and root files were not changed by this work.

User stop boundary: finish the currently active bounded native probe, then return control without another subagent or repair cycle. Full delivery acceptance is not complete at this checkpoint.

Observed focused verification reported by integration owner:

- Rust contracts: 17 passed, including cancellation and bounded control-queue repair
- Dart domain: 22 passed; auth/cancellation, protected-state recovery, transcript finalization, typed entries, and one-shot handoff
- Spark widgets: 5 passed; tooling fixtures: 2 passed
- Clean generated-output Apple build passed for device arm64 and simulator arm64/x86_64
- Focused native Spark XCTest: 9 passed
- Signed `just spark-ios-smoke`: 2 passed with injected voice session; `just ios-smoke`: 2 passed for preserved chat/composer flow
- Broker metadata probe passed with one eligible credential
- Host Rust live probe passed connected → text-sent → final-transcript → audio-received → complete. This is host/provider evidence, not proof of mobile playback or causality between the sent text and an unsolicited initial response
- Source review repairs included real connect cancellation, background fencing, truthful microphone/error state, distinct provider item/final transcript IDs, typed-transcript retention, credential reselection, semantic-corruption preservation, automatic native build wiring, and complete upstream MIT notices

Visual review inspected synthetic `.work/screenshots/spark-expanded-light.png`, `spark-minimized-light.png`, and `spark-expanded-dark.png`. The initial light safe-area band was corrected; refreshed light panel and `raiju-chat-light.png` were inspected. Original chat header, transcript, composer, and navigation remain visible beside the additive Spark surface. No original golden or preservation pin was regenerated.

First production `just spark-ios-live` attempt used private one-shot loopback configuration and actual Dart MethodChannel → Swift AVAudioEngine → Rust WebRTC on the existing iPhone 17 Pro simulator. It reached configuration, broker acquisition, native start, connected, microphone mute, and accepted typed request, but no finalized assistant transcript arrived within 90 seconds. Teardown ran. This is a real failed acceptance attempt, not a mock success.

The final bounded retry of `SPARK_LIVE=1 SPARK_ALLOW_HTTP=1 just spark-ios-live` passed in approximately 47 seconds: actual native start → connected → post-connect typed request → request-matching finalized assistant transcript → positive native output/audio level → Stop → post-stop `sendText` rejected with native `not_started`. This fixture mutes the actual native session immediately after start, before connection completes, then reconciles controller state. It proves this muted, typed-input native response/audio path and resource release; it does not prove spoken uplink or acoustic quality. No product code was changed to obtain the result. The earlier after-connect-mute timeout remains a scenario to investigate; successful changed sequencing alone does not close that behavior.

Credentials were supplied at runtime, not through Dart defines, argv, committed files, screenshots, or provider-body logs. Probe launchers strip broker/access variables from child environments with `includeParentEnvironment: false`; the host probe passes selected provider credential through private stdin, and the simulator uses one-shot loopback IPC with only its port in build configuration. Native launcher grants simulator microphone permission without resetting state and terminates the test app during bounded teardown. Neither live path saves audio or captures live screenshots.

Still pending at this checkpoint:

- Final aggregate formatter/analyzer/preservation/regression gate and scoped commit
- Investigate talk/capture → mute after connection → typed response; the successful native fixture deliberately mutes before connection
- Physical iPhone microphone acoustics, spoken-input recognition, Bluetooth/route changes, media-services reset, and cellular/background transitions; Android live voice is not implemented
- Requested `luna:max` / `deepseek:high` execution was unavailable through exposed model-selection controls; actual worker/reviewer models and coordination limitation are recorded in `../.for-user.md`

At the user's requested stop boundary, no further agents or repair cycles were started. Work remains uncommitted and unstaged; final aggregate gate was not run. Mobile-only status was checked, and implementation/fixtures are retained for continuation.

## resumed Spark acceptance

User authorized continuation after restarting the session. Resume only the existing mobile scope: investigate the after-connect-mute response gap, run final aggregate checks, update settled evidence, and commit verified mobile changes. Preserve the successful pre-connect-muted fixture and all earlier evidence; do not replace a failing scenario with an easier one. No new provider, root/desktop change, or physical-device claim is part of this continuation.

Settled continuation results:

- `SPARK_LIVE=1 SPARK_ALLOW_HTTP=1 just spark-ios-live` passed on the existing iPhone 17 Pro simulator, including immediate mute after connection, a newly added finalized assistant entry matching the typed request, a fresh post-request native `levels` event with positive output, Stop, and native post-stop `not_started` rejection. Final native test took approximately 5 seconds; Flutter reported 2 passed
- `SPARK_LIVE_MUTE_TIMING=before-connection` comparison also passed during continuation. The final default rerun strengthened output proof to observe the production session event stream, not a cached controller level, and excluded transcript entries present before the request
- Earlier after-connect-mute timeout did not reproduce. No provider-turn or native event-loss cause was established, so no product media change or weakened mute policy was justified. The historical failure remains recorded rather than being relabeled as a diagnosed/fixed defect
- Only maintained native `flutter drive` executions count as production-path evidence. An exploratory direct integration-test invocation without the selected native runner was not usable and is not counted as a pass
- `just fix`, scoped SDK analyzer fixes, and `cargo fmt --manifest-path spark-core/Cargo.toml` completed. First aggregate attempt stopped at 52 analyzer diagnostics in the new Spark/tooling code; these were corrected without analyzer suppressions or changes to authorization
- Final component `just check` passed: 18 preservation-guard tests; 301 original GUI files retained; 85 frozen files checked, including all 3 exact reviewed native hashes; 59 Dart files format-clean; full analyzer with no issues; 113 existing app/visual tests; Spark Rust 17, domain 22, widget 5, and tooling 2 tests passed
- `just check` and `just fix` explicitly include the new `spark_section.dart` settings part without widening formatting into preserved upstream GUI. Expanded aggregate gate passed; formatter recipe parity was also checked with `just --dry-run fix`
- `just --fmt --check`, bare `just` command listing, `cargo fmt --manifest-path spark-core/Cargo.toml --check`, and scoped `git diff --check` passed
- Normal `just ios-run` built and launched the original app entrypoint, reached Flutter readiness, then detached with exit code 0 while leaving the simulator app running. Runtime broker/access variables were removed from this build/launch environment
- No new visual behavior was introduced during continuation. Earlier inspected synthetic screenshots and signed native/original-GUI smoke evidence remain applicable; no golden, preservation pin, signing identity, encryption key, or private state was replaced

Native live fixture uses memory-only configuration and does not overwrite normal app's saved broker settings. No audio or live-provider screenshots were saved. Physical spoken-input recognition, human-audible acoustic quality, Bluetooth/routes, media-services reset, and cellular/background qualification remain unverified. Android native voice remains outside this slice.

## connected Spark documentation checkpoint — 2026-09-24

Historical generated checkpoint below included incorrect assumptions. User subsequently required durable undelegated dialogue, existing OMP only, and first-real-message instruction delivery; ADR-014 supersedes memory-only storage, host-extension work, and another documentation-review gate. Earlier documentation review is not implementation evidence.

- Documentation only: updated mobile rules, vision, Spark contract, ADR-013, development guide, and mobile/portable-core overviews. ADR-012 and earlier test results remain historical evidence, not connected-companion acceptance
- Recorded user corrections: one bound conversation, Iskra-owned automatic delegation and persona, prose-only context, hidden versioned host capability, run-consumption correlation, integrated timeline, and no implicit remote abort
- Latest retention refinement keeps local voice overlay memory-only. Navigation/replica/reconnect retention is required; persistence of undelegated dialogue across process restart remains a docs-review decision
- Host implementation scope is additive OMP collab support on dedicated local integration branch/worktree; reference checkout remains untouched. No application, prompt asset, protocol implementation, command, dependency, license, or private-state changes in this checkpoint
- `git diff --check` passed. Reviewed active documentation references for superseded approval/share, overlay retention, and compaction/correlation rules; retained Rust/native contract does not require manual approval/share
- Existing command descriptions still describe implemented baseline fixtures; no test was relabeled as connected acceptance. No build, runtime, simulator, live provider/host, or physical-device check was run for documentation-only changes
- Review gate: updated docs → user review → implementation. New acceptance scenarios are requirements, not passed workflows
- Independent read-only contract review found no blockers in changed documentation or retained Rust/native contracts; no build/test execution was part of that review

## connected Spark implementation — 2026-09-24

Scope: ADR-014, mobile only. Existing OMP wire and host implementation are unchanged. Voice activation only arms local instructions; the first real message carries them. Protected per-chat dialogue, observed-delivery tracking, automatic delegation, original editable Iskra prompts, prose-only context, four-origin timeline, and presentation-only tool modes replace the manual workflow.

- Final `just fix && just check` passed: 18 preservation tests; 301 original GUI files retained; 85 frozen files checked, including 3 exact native adapter hashes; 68 Dart files format-clean; analyzer with no issues; 142 app/storage/harness/UI tests; Rust 18, Spark domain 43, Spark widgets 5, tooling 2 tests
- Regression coverage includes empty-text delegation IDs, exact consumption plus durable echo, uncertain pre-send persistence, known-unsent rollback, queued unsent intents, nonterminal/unrelated-run exclusion, multiple typed exposures, failed-save state preservation, stop/failure flush, prose filtering, instruction-budget rejection, editable-default migration, echo remainders, and bounded-cache ordering
- Live commentary and final forwarding strip marked internal additions without changing exact payload matching. Regression checks exact visible commentary and final wrapper
- Earlier aggregate attempts exposed fixture source-envelope/event nesting errors, analyzer diagnostics, connection readiness timing, and an offscreen settings dropdown. These were corrected without suppressions, baseline changes, or weaker authorization
- First connected simulator attempt failed because fixture entered the original collapsed composer without opening it. Fixture now expands the composer, waits for its controls, verifies actual submission, and includes a remote assistant timeline row. Synthetic assistant events no longer invent a `channel` field
- First original-GUI simulator attempt failed loading cached `objective_c.framework`: physical-iOS artifact was incompatible with simulator. Generated Flutter outputs were cleaned before retry; no app data, key, identity, or private configuration was reset
- Existing-host prerequisite `just live-smoke 3e977afc0ab857e3` failed with `The collaboration room does not exist.` Host metadata still reported a connected idle instance. No host restart, replacement room/key, or host code change was used to manufacture success. Real-host `ios-live` connected-loop and encrypted process-restart acceptance remain unexecuted because this prerequisite failed
- Existing wire has no request/run ID or idempotent retry contract. `isTerminal: false` also covers queued follow-ups/IRC work; it cannot prove that a later run belongs to the original delegation. Missing terminal ownership evidence suppresses retelling rather than guessing. Same-byte prompts from indistinguishable peers remain ambiguous
- Earlier live-provider/native audio results remain historical evidence, not proof of this connected loop. No new live-provider, physical microphone/acoustic, Bluetooth, cellular/background, or Android runtime acceptance is claimed
- Clean-rebuild `just ios-smoke` passed, Flutter reporting 2 tests: original connect/send/reply/offline/encrypted-store restoration journey plus teardown
- Final `just spark-ios-smoke` passed, Flutter reporting 2 tests: connected synthetic journey plus teardown. It covers typed and recognized dialogue, automatic empty-text delegation, exact reply routing, navigation without rebinding, all four origins, and controller/store reconstruction without microphone restart. Voice transport and chat store are injected here; this is not OS-process-restart or live-provider evidence
- Intermediate native fixture retries exposed Flutter-only tapping of a native back control and a missing screenshot allowlist entry. Navigation now calls the same `Navigator.maybePop` action as the native control; no native touch-hit-test claim is made. Restored-dialogue screenshot is explicitly allowlisted
- Inspected synthetic light expanded/minimized, dark expanded, and restored-dialogue screenshots under `.work/screenshots/`. Compared preserved light chat with `.work/spark-connected-before/`: header, bubbles, composer, disconnected banner, and Spark strip remain intact. Connected captures show distinct voice/typed/Spark/remote-assistant attribution and no duplicate forwarded dialogue. No golden or preservation pin was regenerated
- `cargo fmt --manifest-path spark-core/Cargo.toml --check` and `git diff --check` passed. OMP reference checkout remained clean at `f225a978e7d7f6740b0d6efee30b0482c1bb72a6`

## iOS Spark background continuation — 2026-09-25

Scope: ADR-015, already-started iOS voice only. Added the `audio` background mode and retained the existing `.playAndRecord` / `.voiceChat` engine. Routine backgrounding no longer tears down an active session. Foreground-only startup, mute, explicit stop, actual audio interruption/reset, detachment/disposal, and Android's previous teardown remain. A background epoch cancels pending native startup even when its serialized audio queue is busy; Dart also cancels credential/connection startup. No host, storage-key policy, identity, audio recording, or native visual changes.

- Native command: `xcrun xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'platform=iOS Simulator,id=0829D0B0-0436-41DB-AF49-F5F8D898DABE' -only-testing:RunnerTests/SparkNativeTests -parallel-testing-enabled NO -resultBundlePath .work/spark-background-native.xcresult test` passed: 12 tests, zero failures, on iPhone 17 Pro / iOS 26.3 simulator
- Native tests exercise production startup/background fencing and notification registration with a private notification center and deferred fake queue. They do not instantiate a live audio bridge or prove physical microphone behavior; bridge callback wiring was source-reviewed
- Independent read-only review found no introduced lifecycle correctness defects. New widget fixtures initially failed on awaiting a void disposal method, then stalled on fake-async stream cancellation; test scheduling/cleanup was repaired without changing production behavior or removing assertions
- Lifecycle coverage includes retained bound identity, mute and incoming transcript events through inactive/hidden/paused/resumed, no session recreation, explicit stop, pending credential/native-start cancellation, no automatic restart, and Android teardown. Detach fixture invokes the actual observer directly; it is not proof of platform notification delivery
- Aggregate initially exposed `MissingPluginException(stop)` from unchanged timeline-test disposal. A fresh baseline checkout passed, but restoring the pre-change Spark shell in the original workspace reproduced the failure; the fixture does not mount SparkShell. Added a stop-only native-channel stub to that fixture, leaving production teardown unchanged. Temporary baseline checkout was removed
- Final `just check` passed: 18 preservation tests; 301 original GUI files retained; 85 frozen files checked; 68 Dart files format-clean; analyzer with no issues; 142 app/storage/harness/UI, 18 Rust, 43 Spark domain, 8 Spark widget, and 2 tooling tests
- First simulator lifecycle attempt rejected a direct paused-to-resumed transition. Fixture now follows paused → hidden → inactive → resumed and processes background events without waiting for disabled render frames
- Final `just spark-ios-smoke && just ios-smoke` passed, each reporting 2 tests including teardown. Synthetic lifecycle events preserve one muted session and its bound chat, process finalized dialogue while frames are paused, resume without restart, then pass existing delegation/navigation/restoration and explicit-stop assertions. Original GUI connect/send/reply/offline/restore also passed
- Compared minimized Spark capture with `.work/spark-background-before.png` and inspected original chat capture: existing controls, dialogue origins, bubbles, composer, and offline banner remain intact. Existing goldens and reviewed native adapter hashes are unchanged
- Final analyzer reported no issues; `git diff --check` passed. Packaged simulator `Raiju.app/Info.plist` reports `UIBackgroundModes` as `["audio"]`, not only the source configuration
- Physical-device background capture/playback, lock/unlock, protected-data availability, real calls/interruptions, Bluetooth transitions, cellular networking, and live-provider background operation were not run. Lifecycle injection is not OS suspension evidence
- Locked-device storage is a known qualification boundary: existing encrypted saves reread the secure key and access ciphertext. Protection failures retain unsaved turns in memory and surface an error; delegation requires durable writes and may wait until access returns. No Keychain/file-protection relaxation or guarantee of durable locked-screen dialogue was introduced

## user-reported background voice — 2026-09-25

- User reports background voice worked: after switching away from the app, Spark continued the conversation and answered
- This is user-reported app-switch evidence, not an agent-executed physical test. Exact device, OS, build, route, lock state, and network conditions were not captured
- User also reports quiet playback and weak input-level feedback. No gain or acoustic-quality conclusion follows from a screenshot or simulator meter
- Routing failures in the same session are separate: prior user text and Spark retellings appeared in later delegations, and a terminal-origin response was not announced. ADR-016 records those corrections

## incremental routing and chat controls — 2026-09-25

Scope: ADR-016 and confirmed local deletion. Shared mobile/desktop contract and OMP advice live in the Raiju workspace's `docs/message-routing.md`, outside this repository.

- Read-only `just live-smoke 32fdd756d6729863` passed: live control-capable connection, 24 cached messages, clean close. This probe sent no prompt and did not test voice/provider audio
- Final `just check` passed: 18 preservation tests; 301 original GUI files retained and 85 frozen files checked; 70 Dart files format-clean; analyzer clean; 167 app/storage/harness/UI tests; Rust 18, Spark domain 66, Spark widgets 19, and tooling 2 tests
- Expanded-strip accessibility was verified against the actual semantics tree: Navigator route semantics previously hid the preceding strip. A semantics-container boundary restores controls/live text without changing the existing Column layout. Focused shell/visualizer tests passed 16/16
- `just ios-smoke` passed the original connect/send/reply/offline/encrypted-store restoration simulator journey (2 Flutter tests including teardown). Reviewed synthetic chat capture: original header, composer, messages, and retry surface remain
- `just ios-live 32fdd756d6729863` passed: 2 integration tests including teardown, real collab prompt consumption plus unique durable echo and correlated Spark final, followed by instrumented normal-main process restart (`markerCount=2`, 5 chats, 28 messages). Selected spoken context reached the host; trailing Spark acknowledgement stayed local. Voice events/credentials were synthetic over real encrypted collaboration, not live provider or acoustic evidence
- `just spark-ios-smoke` passed (2 tests including teardown): live partial text, quick controls, terminal reply announcement/suppression, transcript restoration, explicit restart, cancel deletion, and confirmed durable local deletion with voice stop and zero remote abort calls. Reviewed confirmation capture: device-only scope and preserved remote work are explicit
- Extended fixture initially retained the global Navigator's old route tree while replacing ProviderScope. Fully unmounting before reconstruction fixed the fixture; assertions now verify shared detail/start container, restored controller identity, viewed chat, and enabled start callback. No production startup guard was weakened
- Final fixture formatting and targeted analyzer passed after reconstruction repair; scoped `git diff --check` passed. Preexisting `ios/Podfile.lock` remained unchanged from task baseline (SHA-256 `86a7eb06ac99a7d73f27e403890ec10ecbbe14fbd5ec2fb20539ce760d757830`)
- Initial focused runs exposed title-clear/reconnect authority, widget fixture lifetime/frame assumptions, offscreen controls, and deletion-route timing. Review also found external-result ownership gaps and an obsolete composer text-equality shortcut; focused regressions were added rather than weakening delivery quarantine
- Audio gain, PCM, native routes, and Rust/native bridges remain unchanged. Meter improvement is display-only: sensitive scaling plus 500 ms expiry refreshed by received level-event revision. Existing input/output producers can replace each other's zero-valued channel; this is not proof of acoustic attenuation
- Source attribution remains protocol-bounded: a known partial is awaited; an unlinked final arriving only after terminal completion is indistinguishable from independent same-text speech and can remain pending. Completed aliases and uncertain dispatch reservations remain durable. No universal exactly-once or new host protocol claim

## relay preference, screen-lock storage, and live typing — 2026-09-29

- `just check` passed: 18 preservation tests, 301 original GUI files retained, 85 frozen files checked; 72 scoped Dart files format-clean, analyzer clean, 185 app/harness/storage/UI tests, Rust 18, Spark domain 66, Spark widgets 19, tooling 2
- `just spark-ios-smoke` passed on iOS simulator: 2 tests including teardown. The synthetic main composer text reached Spark first, then appeared in exactly one host delegation; saved dialogue, simulated lifecycle, chat navigation, and reply presentation remained intact. `just ios-smoke` separately passed 2 tests including teardown for connect/send/reply/offline/restore using synthetic host/store
- Inspected `.work/screenshots/spark-chat-quick-controls.png`, `spark-minimized-light.png`, and `raiju-chat-light.png`: original chat header, rows, composer, Spark strip, and origin labels retained; typed composer suffix appears locally before remote reply. No golden was replaced. Additional targeted GUI formatter, analyzer, and scoped `git diff --check` passed after simulator fixture update
- Relay tests cover default persistence, full QR URLs and wrapped links, invalid endpoints, pinned reconnect, and legacy bare-code migration without redirect. Protected-store tests cover retained ciphertext/key failure, protection hook failure, and voice timestamp serialization/recreation. Swift Keychain query attributes were compared with pinned `flutter_secure_storage_darwin-0.3.2` and `flutter_secure_storage-10.3.0` defaults; simulator Xcode build compiled the native bridge
- Initial focused widget run exposed off-screen settings control; fixture viewport was adjusted. Explicit `spark.stop()` in the new widget fixture remained unresolved after delegation, so these focused UI tests assert dispatch/draft only. Existing non-widget `SparkController` test sends typed input, delegates, then awaits `stop()` successfully (`controller_test.dart:520-542`); synthetic iOS journey also stops. This isolates the observed hang to widget-fixture scheduling, not a demonstrated production stop failure. Initial Spark simulator expectation assumed immediate host send; fixture now asserts one host delegation. One overlapping simulator build produced an invalid generated XCFramework; serialized rerun passed without source/native changes
- Physical iPhone lock/unlock, existing installed Keychain migration under actual data protection, remote reconnect during lock, live provider/audio, and encrypted live-host interoperability were not executed. iOS simulator synthetic lifecycle does not prove OS suspension. After-first-unlock accessibility permits protected chat key/file access while locked but relaxes the prior unlocked-only confidentiality policy; data remains encrypted at rest and unavailable before first unlock

## mobile version and build identity — 2026-09-29

- Scope: `pubspec.yaml` product version `0.1.0+1`, `just bump-version vX.X.X`, and existing settings footer showing version, source commit, and local build-start `YY-MM-DD HH:MM`. Build/run/drive metadata travels through maintained Flutter wrapper; platform build number and app identity remain unchanged
- `node --test scripts/bump-version.test.mjs scripts/flutter-tool.test.mjs` passed: 5 tests for bump/check mode, timestamp/commit formatting, override fences, and child iOS build wiring. `node scripts/bump-version.mjs v0.1.0 --check` reported `Would set mobile version 0.1.0+1` without mutation
- Focused settings footer widget tests passed (three build-number variants); loading/footer test passed. Full original `settings_page_test.dart` run also showed failures in retained Buzz push/invite/layout cases. Layout case checks only `AppListCard.verticalPadding == Grid.twelve`; the change touches only footer `Text`, not cards or section padding. These legacy cases are not included in maintained aggregate; footer cases are
- `just check` passed preservation, formatting, analyzer, app/storage/harness/UI, Rust, Spark domain/widget, and tooling checks. Focused Dart format check (three changed settings files), `flutter analyze --no-pub`, and scoped `git diff --check` passed
- `node scripts/flutter-tool.mjs ios-dart run tool/ios_dev.dart build` produced signed debug simulator `Raiju.app`. Generated `ios/Flutter/Generated.xcconfig` recorded `FLUTTER_BUILD_NAME=0.1.0` and base64 Dart defines decoding to `RAIJU_SOURCE_COMMIT=d62e8b7337ce`, `RAIJU_BUILD_STARTED=26-09-29 12:44`. Concurrent desktop commits advanced repository HEAD afterward; that later hash is not build provenance. `just ios-smoke` passed 2 simulator integration tests including teardown: original app connect/send/reply/offline/restore with synthetic transport
- Inspected `.work/screenshots/raiju-home-light.png`: original home header, list, and navigation retained. Settings footer was verified in widget tests at narrow viewport and doubled text scale in loading test, but no simulator settings screenshot or physical-device/release build was captured; no live host was used. Direct Flutter binary builds bypass maintained metadata wrapper and show explicit unavailable fields

## dirty build provenance correction — 2026-09-29

- The earlier debug build above used uncommitted mobile source but displayed only its base Git HEAD (`d62e8b7337ce`), which did not identify the full source state. Corrected wrapper samples mobile component Git status at Flutter build execution: dirty source now displays `<hash>-dirty`, including for release builds; development builds and tests remain runnable. Missing Git HEAD still blocks release builds
- Focused `node --test scripts/flutter-tool.test.mjs scripts/bump-version.test.mjs` passed (5 tests); `flutter test --no-pub test/features/settings/settings_page_test.dart --plain-name 'shows version with build number'` passed 3 footer variants. `node scripts/flutter-tool.mjs flutter build ios --simulator --debug` passed with dirty source. Generated `ios/Flutter/Generated.xcconfig` encoded `RAIJU_SOURCE_COMMIT=5117d4805622-dirty` and `RAIJU_BUILD_STARTED=26-09-29 12:52`; this is build-define evidence, not a release/device run

## initial mobile version and simpler workflow — 2026-09-29

- Supersedes `0.1.0+1` as starting product version: `pubspec.yaml` now has `0.0.1+1` (`0.0.1` user-facing, `1` platform build number). Kept one Flutter wrapper because both maintained iOS entry paths use it; removed separate build-identity formatter and dedicated version/wrapper test files. Historical checks above describe earlier revision, not current checks
- Manual `node scripts/bump-version.mjs v0.0.1 --check` returned `Would set mobile version 0.0.1+1`; `just bump-version v0.0.1` returned `Set mobile version 0.0.1+1`. `node --check` accepted both edited scripts. `node scripts/flutter-tool.mjs ios-dart run tool/ios_dev.dart build` built simulator `Raiju.app`; its Info.plist reports `CFBundleShortVersionString=0.0.1`, `CFBundleVersion=1`. Generated Flutter build defines decoded to `RAIJU_SOURCE_COMMIT=5d373ed1a923-dirty`, `RAIJU_BUILD_STARTED=26-09-29 13:03`, matching uncommitted mobile changes at build time
- No new automated tests were added or run for this simplification, per user correction. The app was built but no fresh simulator GUI journey, release/device build, or live host check was run

## standalone repository extraction — 2026-09-30

- Scope: publish complete mobile source at `v0.0.1` and mount it in Raiju as `mobile/` submodule; no application behavior changes
- `just check-preservation` passed: 18 tests, 301 original GUI files retained, 85 frozen files checked
- `node scripts/bump-version.mjs v0.0.1 --check` confirmed existing `0.0.1+1`; `just --summary` parsed standalone commands
- Staged-tree comparison against Raiju's previous `mobile-raiju/` tree showed only extraction documentation and ignore-rule changes; source, assets, lockfiles, licenses, and immutable upstream archive remained identical
- Git index includes `pubspec.lock`, `ios/Podfile.lock`, and `spark-core/Cargo.lock`; private environment files, Flutter caches, local evidence, native dependency caches, and build outputs remain ignored
- No app build, simulator journey, live-provider check, or physical-device check was run for this packaging-only change

## dual-checkout builds and fresh startup — 2026-09-30

- Built both standalone `raiju-mobile` checkout and Raiju's `mobile/` submodule through `node scripts/flutter-tool.mjs ios-dart run tool/ios_dev.dart build`, after locked dependency resolution. Initial builds passed in 112.67 s and 144.81 s
- Both artifacts were ad hoc signed universal arm64/x86_64 simulator apps, `dev.raiju.mobile`, version `0.0.1+1`. `codesign --verify --deep --strict --verbose=2 build/ios/iphonesimulator/Raiju.app` passed; source commit and build-start defines were also found in compiled Dart kernels
- Normal launch on isolated iPhone 17 Pro / iOS 26.3 simulator revealed an existing fresh-install storage error in both artifacts. Controller reported `Saved chats could not be read.`; home showed `Could not load channels`
- Foundation `attributesOfItem(atPath:)` returns `NSFileReadNoSuchFileError` (260) for absent ciphertext or support directory. Native protection catches accepted only `NSFileNoSuchFileError` (4). Both exact missing-file codes are now accepted; Cocoa domain, path/filename confinement, symlink rejection, encryption, key migration, and file protection remain unchanged
- Isolated Foundation predicate checks accepted missing files/directories and rejected permission, corrupt-file, and POSIX errors. Fixed standalone and submodule rebuilds passed in 44.81 s and 40.94 s, with strict signature verification. Fixed artifacts identify uncommitted source as `09e9045380df-dirty`
- Installed and launched both fixed normal-entrypoint artifacts sequentially, without erasing or uninstalling simulator state. Reviewed screenshots show `No conversations yet` and `Connect OMP session`, with no startup error. Synthetic before/after captures remain under ignored Raiju workspace `.work/split-verification/`
- Final `just check-preservation` passed: 18 tests, 301 original GUI files retained, 85 frozen files checked. Application locks, app identity, private developer settings, and immutable upstream remained unchanged
- No widget tree or rendering changes, new test files, full test suite, physical-device/release build, live-host connection, provider audio, or saved-chat restart qualification was part of this check

## offline license delivery — 2026-10-01

- Scoped `flutter analyze --no-pub lib/main.dart lib/raiju/licenses.dart lib/features/settings/settings_page.dart` through SDK wrapper passed with no issues
- `node --check scripts/generate-native-notices.mjs` passed; mobile preservation retained 301 original GUI files and checked 85 frozen files, with 52 existing adapted GUI paths
- Focused `flutter test --no-pub test/features/settings/settings_page_loading_test.dart` passed 1/1. Existing doubled-text-scale loading fixture now collects real bundled licenses, verifies emoji-mart permission text and native entries, and opens the standard license page through settings
- Test fixture initially lacked the foundation import, then blocked asset/isolate work in fake-async. `tester.runAsync` handles collection; settling scroll layout and pumping route transition handles navigation. Production code did not change to accommodate the fixture
- Maintained `node scripts/flutter-tool.mjs ios-dart run tool/ios_dev.dart build` produced debug simulator `build/ios/iphonesimulator/Raiju.app`
- Inspected nine packaged legal assets against source bytes: NOTICE, Buzz Apache, emoji-mart MIT, OMP MIT, Spark MIT, Google ML Kit terms, native notices, and Geist/Inter OFL. All matched; native JSON contains 265 Cargo packages, 36 pods, 213 unique texts, and no unresolved missing-text entries. Automatic Flutter `NOTICES.Z` is also present and contains Flutter attribution
- Native refresh is explicit after dependency changes; checked-in notices ship through ordinary asset packaging. No new gate or network fetch runs at startup or during normal builds
- Bounded acceptance decision: user requested limited testing and no development-blocking over-testing. For this isolated offline settings action, use scoped analysis, actual asset-backed widget navigation, and fresh package inspection instead of broader connect/send/restart simulator journey and screenshot capture from component's default GUI workflow. Transport, persistence, and native visual bridges did not change; chosen evidence does not claim a launched-simulator acceptance
- Evidence is scoped analysis, widget behavior, and simulator-package contents. App was not launched on simulator or physical device; release signing/store qualification, Android native inventory, privacy behavior, and live-host/provider checks were not run

## worktree bootstrap — 2026-10-03

- macOS arm64, Worktrunk 0.80.0 / Git 2.56.0: home `main`, current project hook approved, existing fish wrapper loaded successfully without full user startup
- `wt switch --create --base=main --no-cd verify-wt-mobile-20261003-a` ran `just install` / `node scripts/flutter-tool.mjs flutter pub get --enforce-lockfile` successfully
- `wt hook pre-start project:dependencies --worktree-path=/srv/dev/spikes/raiju-mobile.verify-wt-mobile-20261003-a` passed again; lockfile and all tracked files unchanged
- `.dart_tool` and `ios/Flutter/ephemeral` regenerated locally; no build, Pods, `spark-core/target` or `.work` created, no private `.envrc` copied, tracked/untracked status clean
- All ten configured symlink paths rejected individually with exit 1; harmless external fixture target unchanged
- `wt remove --foreground verify-wt-mobile-20261003-a` passed without force; branch and disposable tree removed
- No native build, app/widget tests, simulator/device action, launch, signing, credential access, remote write or Linux verification. This qualifies dependency bootstrap and isolation only

## optional ompd relay — 2026-10-03

- Added optional Connect → Daemon relay alongside unchanged QR/paste collaboration. Start new, resume known session file/id, list/attach running instances, streamed chat, explicit trusted-network consent, and encrypted attach-only restoration use existing chat screens. No daemon or OMP source changes, dependency changes, model calls, or remote deployment
- Scoped `flutter analyze --no-pub` through `scripts/flutter-tool.mjs` covered harness, controller, Raiju projections, pairing, changed Spark controller/context, their tests, relay simulator fixture, driver and tools; passed with no issues
- Ran `flutter test --no-pub test/harness test/companion_controller_test.dart test/features/pairing/ompd_pairing_page_test.dart test/raiju test/storage test/spark/domain/controller_test.dart test/widget_test.dart test/features/home/home_page_test.dart test/features/pairing/pairing_qr_scanner_test.dart test/shared/theme/app_theme_test.dart` through SDK wrapper. Harness, controller, encrypted-store, existing chat/UI, QR and theme regressions passed. Initial new-fixture failures were corrected; focused final reruns passed relay pairing 11/11 and Spark controller 38/38. Separate changed-context regression passed 10/10
- Protocol fixtures exercise actual local TCP framing, split/coalesced UTF-8, bounded/paged history, streaming bootstrap races, transcript-file identity, controller takeover during bootstrap/live, cancellation before attach, compaction context refresh, callback permission fences, errors/timeouts and no prompt replay. Existing encrypted collaboration codec/client tests also passed
- `just check-preservation` passed 23 tooling/guard tests; retained 301 original GUI files and checked 85 frozen files. `just --summary` accepted new `ompd-smoke` and `ompd-ios-smoke` recipes. Lockfile/source dependency diff remained empty
- `node scripts/flutter-tool.mjs dart run tool/ompd_smoke.dart --daemon /Users/hegpolat/.cargo/bin/ompd` passed against installed `ompd 0.1.0`: isolated actual daemon, synthetic RPC worker, start/readiness, state/history, prompt events, controller takeover, known-session resume, offline history on reconnect, no restart/replay, and owned-process cleanup. Zero provider/model calls
- `node scripts/flutter-tool.mjs ios-dart run tool/ios_dev.dart smoke` passed on iPhone 17 Pro simulator: original no-login connect/talk/offline/restore journey. `... ompd-smoke` also passed: actual app and TCP adapter, consent, running-instance attachment, start-once, streamed reply, draft, disconnect, encrypted store/controller recreation and reconnect without another start
- Inspected synthetic screenshots under `.work/screenshots/`: existing chat layout remains intact; relay adds its own optional form and reuses existing chat/header/composer. Reviewed relay consent/list/streaming and restored light/dark screenshots. No goldens or preservation pins changed
- Verification corrections: regenerated stale `.dart_tool` metadata with locked pub get; fixed nullable-expression parsing and interface cast; adjusted asynchronous/lazy-scroll test setup and fake voice readiness. Simulator fixture originally looked for empty-home controls after a chat existed; corrected selector to saved chat plus existing new-conversation action. Actual-daemon fixture originally raced shared audit appends during concurrent shutdown; per-worker audit files fixed cleanup verification
- Limits: simulator restoration recreates controller/store in one process, not a new OS process. Real-model replies, physical-device Tailscale/Wi-Fi reachability, Android native execution, voice audio/provider behavior and release distribution were not tested. Relay history is current model context, not complete archived transcript; old-session browsing and durable pending-question replay are absent from current daemon API. Plain TCP remains unauthenticated and relies on restricted network access
