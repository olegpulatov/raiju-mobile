# spark-core

Portable Rust transport/media module for Spark, adapted from OMP Iskra. First provider uses ChatGPT subscription OAuth and the private Codex realtime protocol. It is not the public OpenAI Platform Realtime API; service entitlement is not guaranteed by a successful build.

The crate does not depend on Flutter, an OMP agent runtime, device microphone APIs, a credential file, or sibling desktop code. It never records audio. Mobile consumer supplies credentials, microphone samples, personality instructions, and bound-chat delegation integration.

## boundaries

- `src/provider/`: provider-specific signaling, authenticated sideband, wire events, and context encoding
- `src/media.rs`: WebRTC/Opus and bounded PCM queues; no device audio or filesystem archive
- `src/session.rs`: session lifetime, command/event boundary, mute and cancellation
- `include/spark.h`: C ABI for iOS and future non-Rust hosts
- `src/bin/live_probe.rs`: opt-in live interoperability probe with redacted stage output; not a microphone/acoustic test

Input PCM: mono float32, 16 kHz. Output PCM: mono float32, 48 kHz. These are the canonical Iskra Opus media rates, not a public-API PCM contract. Hosts must convert device rates, stop stale playback, and release their own microphone/audio-session resources.

Provider changes stay behind the provider module and normalized event boundary. This is a first-provider implementation, not a claim that other providers already work. Memory and main-agent execution remain host responsibilities; finalized text and delegation events provide their integration boundary.

## build and tests

Requires Rust/Cargo, a C compiler, and CMake for bundled Opus. Dependencies are pinned by `Cargo.lock`; building does not require an upstream OMP checkout. Run from this mobile repository root:

```fish
cargo test --locked --manifest-path spark-core/Cargo.toml
just spark-ios-build debug
```

Apple build additionally needs macOS/Xcode and Rust device/simulator targets. It produces generated libraries under ignored `.work/spark-ios/`. iOS uses Apple targets, not musl. Native app workflows prepare their required library profile through component commands.

The standalone crate can also be built from its own directory with `cargo test --locked`. A host build proves protocol/ABI contracts, not iOS microphone behavior or provider entitlement.

## host contract

Full command/event shapes and mobile integration: [Spark design](../docs/spark.md).

- Create a handle with `spark_create`; a zero handle means creation failed
- Pass UTF-8 JSON commands to `spark_command`; parse the returned result, then free it with `spark_string_free`
- Poll normalized JSON events with `spark_poll_event`; free every returned string, including JSON `null`
- Supply bounded float PCM with `spark_push_audio`; consume playback through `spark_read_audio`
- Stop and destroy explicitly. Do not start microphone automatically after failure, background, or process restart
- Keep broker/access credentials, SDP, and provider errors out of logs and persistent audio/transcript archives

Dart/Swift mobile adapters are consumers, not part of C ABI. Spark owns automatic delegation through existing OMP collab; no host code changes or new capability protocol. Rust and Dart retain delegation event ID even with empty text. Mobile integration owns chat permissions, observed delivery/consumption evidence, duplicate suppression, prompt settings, and protected durable voice transcript including undelegated turns. Voice stop never aborts remote work. Rust transport is not an authorization boundary for agent tools; host permission questions remain explicit. See ADR-014 and Spark guide for actual collab limitations, not invented protocol guarantees.

## provenance and evidence

Adapted upstream: OMP `ed7c05c288b12e69f6986d8b379eb2c33f55e914`, particularly `crates/pi-voice/src/live.rs` and `packages/coding-agent/src/iskra/{protocol,transport}.ts`. Exact source hashes and license reference: [manifest](../upstream/spark-omp.json).

Observed checks and limitations are recorded in [mobile verification](../docs/verification.md). Mock, host-native, simulator, provider interoperability, and physical-device audio results are separate evidence categories.
