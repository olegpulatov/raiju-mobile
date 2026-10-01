# development and acceptance

Commands and paths below are relative to this repository root, which is the Flutter project and mobile administration root. In the Raiju workspace, this repository is checked out as the `mobile/` submodule and inherits shared workspace rules.

## working method

1. Read vision/invariants and relevant ADRs. State one user-visible outcome and its non-goals
2. Inspect original implementation and tests. Change data/side-effect seams, not visual composition
3. Manager assigns outcomes, exact file ownership, shared APIs, safety constraints, and acceptance evidence. Agents own investigation and implementation; do not manage them through constant status messages
4. Manager waits while owners work. Escalate only a real decision/blocker or scope conflict. One integration owner receives settled changes and closes cross-component failures
5. Integration owner runs targeted tests and simulator journey. Manager runs final aggregate formatter/analyzer/test/preservation gate once integration settles
6. Inspect source diff and screenshots against baseline. Mechanical gates do not prove visual equivalence
7. Record command, result, platform, and limitation. Do not call mock responses or widget tests live-host evidence
8. Update decisions/run guide and verification record, commit scoped changes, then confirm clean git state without altering unrelated user work

Connected Spark implements user's conversation behavior through existing OMP collab. User corrections override earlier checkpoint prose: durable voice transcript, no host code changes, no new capability protocol, and two-model directive attached to first real delegated/user message after live starts—not a standalone activation turn. See [Spark](spark.md) and ADR-014 for existing-wire limitations; do not turn documentation into another approval gate.

Acceptance covers bound navigation, extended dialogue, empty delegation, observed delivery boundaries, retry/echo deduplication, four origins, source-aware prose and total context budget, first-message directive deduplication, non-terminal/unrelated completion fencing, manual steering, persistent transcripts/prompts/tool modes, and voice-stop isolation. One integration owner runs settled mobile checks, encrypted interoperability, and simulator/visual acceptance. Existing manual-workflow results remain historical, not connected acceptance.

ADR-016 adds incremental source selection and late-transcript overlap tests: persistence is not an obligation to replay every voice turn into main. Cover main-result feedback exclusion, retained intervening clarifications, request/user exact overlap, external-terminal announcements on/off, hide-thinking defaults and quick controls, stable session names, and live partial recognition. Shared client-neutral flow lives in the Raiju workspace at `docs/message-routing.md`, outside this repository. Local chat deletion requires confirmation, durable removal, bound-voice cleanup, and no remote abort/history mutation. Concurrent desktop changes and unrelated mobile dependency changes are not part of this slice.

iOS background voice follows ADR-015: continue only an already-started native audio session, retain foreground-only startup and explicit-stop/interruption fences, and leave Android behavior unchanged. Lifecycle injection tests cover application policy, not OS suspension. Physical acceptance must start voice in foreground, switch apps and lock/unlock during a multi-turn conversation, verify microphone uplink and assistant playback, repeat muted (no uplink), then verify explicit stop and no automatic restart after an audio interruption. Do not treat a simulator pass as this physical-device result.

## toolchain and commands

Flutter 3.41.7 / Dart 3.11.5 is pinned from Buzz's original toolchain. Put that SDK's `bin` on PATH, or set `FLUTTER` and `DART` to executable paths. No original Buzz/OMP checkout or parent Git history is required. Spark adds Rust/Cargo, CMake, and a C compiler for bundled Opus. iOS also needs Xcode, an installed iOS simulator runtime, and Homebrew `ruby@3.4`. `just`, Node, and system `tar` run component gates.

`pubspec.lock` and `ios/Podfile.lock` are committed application dependency snapshots. Component ignore rules override broad global `*.lock` ignores, so a fresh copy can resolve the same versions with `--enforce-lockfile` and native deployment checks. Do not regenerate locks as part of unrelated layout work.

iOS helper resolves `brew --prefix ruby@3.4` and installs CocoaPods 1.16.2 into ignored `.work/cocoapods-1.16.2`. It passes isolated `GEM_HOME`, `GEM_PATH`, and PATH to Flutter; global Ruby/CocoaPods remain unchanged. This avoids observed Ruby 4.0.6 TCP timeouts to CocoaPods CDN/GitHub. Ruby 3.4.10 plus CocoaPods 1.16.2 completed `pod install --deployment` without changing `Podfile.lock`.

Simulator builds retain Xcode signing configuration and bundle identity. Do not use `--no-codesign` for persistence acceptance: retaining ciphertext without access to its OS-held key is not restoration. Native fixtures use `flutter drive --keep-app-running`, because normal driver teardown otherwise uninstalls app data. Verify Keychain access through actual restoration; simulator signing metadata alone is not physical-device evidence.

Maintained entry points live in this component's `justfile`; bare `just` lists them without mutation:

- `just bump-version vX.X.X`: update `pubspec.yaml` product version, preserving platform build number (`node scripts/bump-version.mjs vX.X.X --check` previews)
- `just install`: resolve locked mobile dependencies
- `just clean`: remove generated build outputs and caches
- `just check`: preservation guard, formatting/static checks, active tests, retained visual regressions
- `just ios-build`: run aggregate gate and create signed debug simulator build with same native environment
- `just ios-run`: boot/select simulator and run actual app
- `just ios-device`: build, install, and launch a standalone release app on physical iPhone selected by direnv
- `just ios-smoke`: deterministic original-GUI acceptance journey on simulator
- `just live-smoke HOST`: real encrypted collab handshake/history, no prompt unless explicitly requested
- `just live-chat-smoke HOST`: real encrypted collab chat with one harmless marker prompt
- `just ios-live HOST`: opt-in real GUI connect/send/receive, followed by normal-entrypoint process restart/restore check
- `just spark-test`: focused Rust/domain/widget/tooling contracts; narrower `spark-rust-test`, `spark-domain-test`, and `spark-widget-test` avoid unnecessary native/UI work
- `just spark-ios-build debug`: explicit Apple library preparation; ordinary iOS entry points prepare the required profile automatically
- `just spark-ios-smoke`: synthetic Spark start/mic/text/handoff/minimize/stop journey; fake provider is not live audio evidence
- `just spark-broker-auth-probe` and `just spark-live-provider-probe`: opt-in runtime-credential probes; auth metadata and actual provider text/audio stages are distinct
- `just spark-ios-live`: opt-in production iOS/native provider response, fresh output-level, and stop/release check; default mutes immediately after connection. Runtime credentials and `SPARK_LIVE=1` are required; HTTP also requires `SPARK_ALLOW_HTTP=1`. `SPARK_LIVE_MUTE_TIMING=before-connection` retains the comparison scenario

From Raiju workspace root, initialize the checkout with `git submodule update --init mobile`, then prefix mobile commands with `just mobile`, for example `just mobile ios-run` or `just mobile ios-device`. Root `just check` aggregates implemented components. Root dispatch loads this repository's `.envrc` through `direnv` when that file exists; otherwise it needs no direnv installation.

Mobile version comes from `pubspec.yaml` (`0.0.1+1` initially: `0.0.1` is product version, `1` is iOS/Android build number). Settings footer displays `vX.X.X`, source commit, and local build-start `YY-MM-DD HH:MM`. Maintained Flutter build/run/drive commands inject commit and time when Flutter starts its build through `scripts/flutter-tool.mjs`, including simulator and device entry points. Uncommitted mobile source adds `-dirty` to the displayed commit without blocking builds or tests; release builds require an available Git HEAD. Direct invocations of an unwrapped Flutter binary display unavailable metadata. Existing app identity remains unchanged.

Physical-device settings are developer-local. Inside this repository, copy `.envrc.example` to `.envrc`, set `IOS_DEVICE_ID` and `IOS_BUNDLE_ID`, then run `direnv allow`. Find connected IDs with `node scripts/flutter-tool.mjs flutter devices`; do not commit personal device identifiers. A moved `.envrc` may need approval at its new path. Keep private values in this repository, not workspace root.
`HOST` is an OMP instance ID or PID from `omp collab list --json`, never a join token. Live tooling obtains capability privately and passes it once over a loopback socket; no token in clipboard, files, build flags, or printed URLs. Use a trusted development machine. Live chat test sends one small marker request to that host; use a designated cheap test session, not an unrelated working session.

Commands and tests are implementation deliverables; their presence is not evidence they passed. Actual execution results belong in verification record.

Restart acceptance uses normal `lib/main.dart`, providers, encrypted production store, and collab transport. Default-off debug probe reports booleans, counts, and synthetic-data digests only. It requires available encrypted storage, a distinct process, exact draft/reply restoration, and live reconnect; host-history marker count must remain unchanged. This is instrumented debug-app evidence, not release-build or physical-device evidence.

Deterministic smoke captures original home/chat with synthetic data in light and dark appearance under `.work/screenshots/`. Main inspects those images with source diffs. Live tests do not capture private transcript fixtures or update goldens.

If switching from a physical-iPhone build to simulator produces a native-framework error such as `have 'iOS', need 'iOS-simulator'`, run `node scripts/flutter-tool.mjs flutter clean` from this directory, then repeat the intended command. This clears generated build outputs, not installed app data or Keychain. This recovery resolved the observed `objective_c.framework` platform mismatch without source or dependency changes.

## offline licenses and native notice refresh

Settings → Licenses opens Flutter's standard offline viewer. `lib/raiju/licenses.dart` adds lazy local/native collectors alongside Flutter's built-in collector; it does not clear or replace automatic Dart dependency notices. All local legal texts and `licenses/native-notices.json` are explicit `pubspec.yaml` assets.

Flutter 3.41.7 `flutter_tools/lib/src/license_collector.dart` scans each package in `.dart_tool/package_config.json`, prefers package-root `NOTICES`, otherwise reads `LICENSE`, and appends `flutter.additional-licenses` when declared. `asset.dart` compresses the result into `NOTICES.Z` on native platforms; the services binding registers its own lazy decoder. The app has no root `LICENSE`; its Buzz/OMP/assets are registered explicitly instead. Flutter SDK subpackages without separate root license files inherit Flutter's license, already delivered by the `flutter` package; `sky_engine/NOTICES` supplies bundled engine notices. This mechanism does not scan Cargo, CocoaPods, or arbitrary font directories.

Refresh from component root after changing native dependencies and installing the locked packages/pods:

```sh
node scripts/generate-native-notices.mjs
```

- Inputs: `spark-core/Cargo.toml`, `spark-core/Cargo.lock`, offline locked `cargo metadata --filter-platform` for `aarch64-apple-ios`, `aarch64-apple-ios-sim`, and `x86_64-apple-ios`; only resolved nodes enter the union. Include build/target packages as a safe superset, not an exact linker report
- Read installed Cargo package manifests, VCS provenance, full license/copyright/notice/author texts, license directories, and embedded C/native materials recursively. Missing full-text Apache alternatives use only the three exact reviewed versions in ADR-019
- Inputs: `ios/Podfile.lock`, matching installed `ios/Pods/Manifest.lock`, `Pods-Runner-acknowledgements.markdown`, installed pod legal files, local podspecs, and cached CocoaPods specs. Cache defaults to `~/.cocoapods/repos/trunk/Specs`; `COCOAPODS_SPEC_REPO` must point directly to another repository's `Specs` directory, containing the three-level hash buckets
- Output: checked-in `licenses/native-notices.json`, with input SHA-256 hashes, package names/versions, source/license declarations, explicit fallback provenance, deduplicated full texts, and `unresolved` entries. Current generation: 265 Cargo packages, 36 pods, 213 unique texts, no missing-text entries. This count is delivery evidence, not legal clearance
- Native materials include `opusic-sys` bundled Opus COPYING/AUTHORS, ring's BoringSSL/other-bits licenses, six installed Google ML Kit NOTICES collections, CocoaPods acknowledgments, and MLImage's exact copyright declaration. Google pod copyright declarations are their actual podspec license fields; they are not presumed MIT/Apache because Buzz shipped them
- `MLKitAppleSiliconSimulator` contains only the copied `google_mlkit_commons` Python build helper, not another framework/download. Inspected Ruby helper copies that script; inspected Python code only changes existing frameworks' `LC_BUILD_VERSION.platform`. Generated `platformAdaptations` records both helper sources and installed script hashes; copied script matches original package. No extra local legal files exist there, and locked framework notices remain applicable
- `licenses/google-ml-kit-terms.txt` captures full official ML Kit Terms & Privacy text, last modified 2025-05-14, from https://developers.google.com/ml-kit/terms, including its incorporated https://developers.google.com/terms link (Google APIs terms last modified 2021-11-09). Neither page's website-content license licenses SDK binaries. No runtime network access or dependency removal
- Normal development/builds use checked-in notices and do not run this generator or a new blocking license gate. Refresh requires existing installed dependency sources, not a new dependency or online notice fetch. Android Gradle-native materials and store/privacy qualification remain outside this iOS evidence

Integration owner checks settled changes, not every contributor mid-edit:

```sh
node --check scripts/generate-native-notices.mjs
node scripts/flutter-tool.mjs flutter analyze --no-pub lib/main.dart lib/raiju/licenses.dart lib/features/settings/settings_page.dart
node scripts/check-preservation.mjs
node scripts/flutter-tool.mjs ios-dart run tool/ios_dev.dart build
```

After simulator build, inspect `build/ios/iphonesimulator/Raiju.app/Frameworks/App.framework/flutter_assets/` for `NOTICES.Z`, all declared `licenses/` files, `spark-core/LICENSE`, and both font license assets. Opening Settings → Licenses in a launched app with network disabled verifies actual viewer delivery. Static asset declarations alone are not build or simulator evidence.


## normal user journey

- Launch app: original chat shell appears immediately, including with empty storage or no network
- Open Connect. Scan OMP collab QR on a physical iPhone, or paste complete browser link / bare join token. Simulator uses paste because camera is unavailable
- Successful handshake opens original chat screen. Existing history appears; sending text produces streamed assistant reply
- Read-only capability visibly disables mutation. Offline/reconnecting state preserves transcript and draft; never secretly queues a send
- Quit/relaunch: saved chat and draft return; active saved connection reconnects if same host room remains available
- Disconnect retains saved chat but disables automatic reconnect. Forget removes local saved connection/history
- Host session replacement ends old link. Keep cached chat and show failure; user supplies new link. Do not silently attach a different conversation

## quality gates

- source preservation: full baseline provenance/checkpoint; original GUI/assets/native visual bridges retained; any removal explicitly classified
- standalone baseline: preservation guard verifies bundled `upstream/buzz-mobile.tar.gz` checksum before reading original file hashes; no parent Git checkout or automatic baseline regeneration
- original visuals: original theme/QR/home/frosted-widget regressions plus light/dark screenshots and diff inspection
- boot boundary: no account, age, Buzz relay, Nostr auth, push enrollment, or community server lookup at startup, including indirect appearance-provider paths
- connection: QR/paste parser parity, secret-free errors, encrypted protocol compatibility, permissions, snapshot/stream ordering, bounded reconnect/cancel, no command replay
- persistence: real store/controller recreation, encryption, atomic writes, draft/preference restoration, corruption/key failure without deletion, durable disconnect/forget
- iOS: build and run original app with retained native bridges; launch/connect/talk/relaunch scenario. Simulator results do not qualify physical camera/cellular/background behavior

Original backend tests and unused Buzz helpers remain preserved as upstream reference, but may assert removed behavior or depend on absent Buzz monorepo tooling (for example `scripts/check-file-sizes.mjs`). Only this component's `justfile` defines maintained Raiju commands. Original README, changelog, and huddle notes live under `upstream/buzz-*.md`; they are historical material, not active run instructions. Do not bulk-delete tests, silently skip failures, or claim the complete original server contract passes.

## evidence and review

Keep generated builds/screenshots/logs under ignored `.work/` or Flutter build directories. Never capture real link input or private transcripts in committed evidence. Use synthetic chat data for visual fixtures.

Reviewer checks actual widget/native diffs, not only green tests. New goldens require inspection; automatic regeneration cannot justify a redesigned GUI. Protocol/package version changes require explicit compatibility review and live interoperability check.

Three native attachment bridges use exact reviewed effect-adapter hashes rather than original baseline hashes (ADR-010). Their renderer/layout stays original; both native and Dart callbacks block unsupported effects. Other frozen files remain byte-identical to baseline. Do not broadly thaw bridges or automatically refresh pins.

Before completion report:

- executable app/run/connect path
- exact checks run and observed result
- source/UI changes versus baseline
- retained inactive backend debt and disabled controls
- simulator versus live-host versus physical-device limitations
