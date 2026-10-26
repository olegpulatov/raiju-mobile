# mobile verification

Choose checks for the changed behavior. This page describes repeatable checks and their limits, not past runs. Report actual commands/results in completion summaries or commit messages; keep generated logs and synthetic screenshots under ignored `.work/`.

## prerequisites

Run from the mobile repository root. Use `just install` for locked dependencies and the pinned SDK wrapper for direct Flutter/Dart commands. iOS checks require macOS, Xcode, an installed simulator runtime, Homebrew `ruby@3.4`, and the Rust/native toolchain described in [development](development.md#toolchain-and-commands).

## local checks

- `just check`: preservation, formatting, analysis, active app/storage/transport/UI tests, and Spark contracts
- `just ios-smoke`: original chat shell, connect/send/reply/offline flow, and saved-state restoration on simulator with a synthetic host. Also covers ADR-021: avatar toggle, text selection with More, detached-reader anchoring during streaming and typing, and debounced draft storage. Jump-to-latest is checked through its Dart callback, not native UIKit touch
- `just ompd-ios-smoke`: app start/attach/chat/restore flow with a synthetic local TCP peer
- `just ompd-smoke /path/to/ompd`: isolated real daemon with a synthetic RPC worker; no model calls
- `just spark-test`: portable Rust, Dart domain, widget, and tooling contracts
- `just spark-ios-smoke`: folded/expanded controls, folded-control drag and edge snap with retained placement, dialogue/delegation, navigation, lifecycle policy, restoration, and stop with synthetic voice

Inspect synthetic light/dark screenshots and source diffs for UI changes; preservation counts and passing tests do not establish visual equivalence. License packaging checks are in [development](development.md#offline-licenses-and-native-notice-refresh).

## live collaboration

Choose an authorized test instance from `omp collab list --json`. Pass its instance ID or PID, never a capability:

```fish
just live-smoke INSTANCE       # encrypted handshake/history; no prompt
just live-chat-smoke INSTANCE  # one marker prompt and reply
just ios-live INSTANCE         # UI chat, then normal-entrypoint process restart
```

Chat checks mutate the designated conversation. The host must remain running. Tooling transfers its capability privately through runtime IPC; do not put real links in arguments, build flags, logs, or screenshots. The restart probe must recover the encrypted chat, draft and reply, reconnect, and show no prompt replay. It is debug instrumentation, not release qualification.

## live daemon relay

Use an already-running authorized relay and test profile. Set runtime values through local direnv or environment:

```fish
env OMPD_TEST_ENDPOINT=relay.example:7427 OMPD_TEST_PROFILE=test just ompd-ios-live
```

Replace the example endpoint/profile with the designated server configuration. This creates a uniquely named worker, sends a small model prompt, browses/attaches, and recreates encrypted storage/controller/preferences to check saved chat and draft restoration without replay. It leaves its worker running; it does not restart or configure the daemon. Attaching takes control from a previous controller, so do not target unrelated work.

The relay journey recreates objects within one app process. It does not prove restoration after OS process termination. See [relay behavior](development.md#optional-daemon-relay) for session identity and history limits.

## live voice and physical devices

`just spark-broker-auth-probe`, `just spark-live-provider-probe`, and `just spark-ios-live` require runtime credentials and `SPARK_LIVE=1`; HTTP also requires `SPARK_ALLOW_HTTP=1`. Follow [Spark probe instructions](spark.md#acceptance-and-commands). Never place credentials in argv, compiled flags, logs, or screenshots.

The native live voice check covers a muted typed request, matching response, fresh output-level event, and resource release. It does not qualify spoken uplink or human-audible quality. For physical iPhone acceptance, start voice in foreground, switch apps, lock/unlock after first device unlock, verify saved dialogue and audio, then test mute, route changes, interruptions, explicit stop, and no automatic restart.

## coverage limits

- Simulator lifecycle injection is not OS suspension, physical microphone/camera, Bluetooth, cellular, or VPN reachability evidence
- Same-process store/controller recreation is not OS restart or installed Keychain/file-protection migration evidence
- macOS relay runs and path-alias fixtures do not qualify a live NixOS host
- Synthetic voice over real collaboration is not a complete live-provider conversation
- Existing collab lacks request/run IDs and idempotent ACKs; byte-identical peer prompts and late unlinked speech can remain ambiguous
- Android runtime/audio, physical-device reliability, release signing/distribution, and store/privacy qualification require separate checks

Do not describe these boundaries as verified without evidence from the corresponding platform and scenario.
