# mobile raiju

iOS-first mobile surface for Raiju, a private personal AI companion. Complete Buzz mobile copy: original GUI, no Buzz login/server, OMP collab chat behind QR or pasted link. Spark brings Iskra voice into same saved conversation through existing OMP connection. Android source remains preserved; Spark's native audio target is iOS.

## run

Run commands from this directory. Flutter project and mobile administration share one component root; no parent repository or original Buzz checkout is needed for maintained mobile checks.

Requires Flutter 3.41.7 / Dart 3.11.5, Rust/Cargo, CMake, a C compiler, Node, system `tar`, and `just`. iOS also requires macOS, Xcode, an installed iPhone simulator runtime, and Homebrew `ruby@3.4`. Native helper prepares device/simulator Spark libraries automatically and installs isolated CocoaPods 1.16.2 under ignored `.work/`. SDK resolver accepts `FLUTTER`/`DART` executable overrides, reuses pinned standard Hermit cache, or uses PATH.

```fish
just                 # list commands; no changes
just check           # preservation, analysis, active tests
just ios-run         # boot/select simulator and launch app
just ios-smoke       # repeatable original-GUI test journey
just ios-device      # build/install/launch release on configured physical iPhone
just spark-test      # focused portable voice, auth, handoff, and UI contracts
just spark-ios-smoke # synthetic Spark controls and handoff journey
```

For physical iPhone, configure repository-local `.envrc` from `.envrc.example` and approve it with `direnv allow`; see [development guide](docs/development.md). In the Raiju workspace, this repository is the `mobile/` submodule; root `just mobile COMMAND` forwards to these same commands, including local direnv settings.

App opens original chat shell directly. Choose Connect, scan OMP collab QR or paste link/token, then chat. Simulator uses paste. OMP host must stay running; reconnect never automatically replays ordinary typed prompts.

Saved connections, drafts, and bounded history cache are encrypted; key stays in OS secure storage. Appearance is local. Disconnect retains chat; Forget removes local saved state. OMP owns full history, so cache is not an independent archive.

Configure voice through Settings → Spark: protected broker configuration, voice, editable Iskra prompts, user name, and tool visibility. Voice stays bound to starting chat while navigating. Bound transcript includes recognized speech, Spark replies, typing, and remote replies; local voice turns are saved even before delegation. Spark delegates automatically; no manual proposal or reply-sharing workflow. No audio is saved.

Starting live sends nothing remotely. Two-model directive goes with first real delegation/user message exposing live dialogue. Existing collab remains unchanged: host may display directive and does not supply explicit handoff/run IDs or idempotent ACKs. Mobile must retain uncertain dialogue rather than invent delivery/ownership. Details and concrete limitations: [Spark](docs/spark.md); executed evidence: `docs/verification.md`.

## real-host verification

Use `omp collab list --json` to identify designated test host. Pass its instance ID or PID, never its token:

```fish
just live-smoke INSTANCE       # handshake/history only
just live-chat-smoke INSTANCE  # one harmless marker prompt
just ios-live INSTANCE         # real UI chat, then normal-entrypoint restart
```

Live tooling obtains capability privately; iOS test receives it through a one-shot loopback socket, not clipboard or build flags. Use a trusted development machine. No real token in command arguments, screenshots, logs, or committed fixtures. Use cheap, dedicated host because chat checks mutate its conversation.

## boundaries and decisions

- OMP history and Spark session retain separate internal ownership while target UI presents one connected conversation. Retained unsupported Buzz controls still explain unavailability
- Connected Spark behavior, broker security, prompts, automatic delegation, persistence, and existing-collab limitations: [Spark](docs/spark.md), ADR-014. User intent overrides earlier checkpoint mistakes; evidence remains in `docs/verification.md`
- Full original source/asset/native UI baseline was committed as `ac84469` in Raiju history; immutable provenance and archive live under `upstream/` in this repository
- Preservation checks read the bundled checksum-pinned snapshot, not parent Git history; reviewed native adapter pins remain exact
- Unit/widget tests, simulator runs, real OMP interop, and physical iPhone behavior are separate evidence. See `docs/verification.md` for observed results and remaining limits

Project direction: `VISION.md` · invariants: `AGENTS.md` · ADRs: `docs/decisions.md` · operating process: `docs/development.md`

Buzz source is Apache-2.0; OMP protocol references are MIT. Attribution summary and third-party credits are in `licenses/NOTICE`; original notices remain in `licenses/` and the vendored tree.

## component map

- `lib/`, `assets/`, `ios/`, `android/`: application and platform projects
- `test/`, `integration_test/`, `test_driver/`: contract tests and native acceptance
- `justfile`, `scripts/`, `tool/`: mobile commands, SDK/preservation helpers, native/live tooling
- `spark-core/`, `lib/spark/`: portable Rust voice transport/media and mobile voice session/settings/UI adapter
- `docs/`, `VISION.md`, `AGENTS.md`: mobile decisions, workflow, evidence, scope, and component rules
- `upstream/`, `licenses/`: immutable Buzz snapshot, provenance, original notes, and attribution
- `.work/`: ignored development caches and synthetic evidence; Flutter build output stays in `build/`

`upstream/buzz-readme.md`, `buzz-changelog.md`, and `buzz-huddles.md` preserve original Buzz documentation, not current Raiju instructions. Retained backend tests/helpers are reference material; supported commands are exactly those listed by this component's `just`.
