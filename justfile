set shell := ["env", "-u", "BASH_ENV", "bash", "-eu", "-o", "pipefail", "-c"]

flutter := "node scripts/flutter-tool.mjs flutter"
dart := "node scripts/flutter-tool.mjs dart"

# List supported commands without changing anything.
default:
    @just --list --unsorted

# Resolve pinned mobile dependencies; never update lockfile implicitly.
install: _deps

# Remove generated mobile build outputs and caches.
clean:
    {{ flutter }} clean

[private]
_deps:
    {{ flutter }} pub get --enforce-lockfile

# Bump the product version (vX.X.X), preserving the current build number.
bump-version version:
    node scripts/bump-version.mjs "{{ version }}"

# Check original GUI retention and the guard's own regression tests.
check-preservation:
    node --test scripts/*.test.mjs
    node scripts/check-preservation.mjs

# Run active Raiju contracts and retained original visual regressions.
test: _deps
    {{ flutter }} test --no-pub test/widget_test.dart test/harness test/storage test/companion_controller_test.dart test/raiju test/features/home/home_page_test.dart test/features/pairing/pairing_qr_scanner_test.dart test/features/pairing/ompd_pairing_page_test.dart test/shared/theme/app_theme_test.dart
    node scripts/spark-test.mjs all

# Check preservation, formatting, analysis, and active tests without source changes.
check: _deps check-preservation
    {{ dart }} format --output=none --set-exit-if-changed lib/harness lib/storage lib/raiju lib/spark lib/features/settings/settings_page.dart lib/features/settings/settings_page/spark_section.dart lib/features/pairing/ompd_pairing_page.dart lib/companion_controller.dart test/harness test/storage test/raiju test/spark test/features/settings/settings_page_test.dart test/features/settings/settings_page_loading_test.dart test/features/pairing/ompd_pairing_page_test.dart test/helpers/ompd_fixture.dart test/companion_controller_test.dart test/widget_test.dart tool integration_test test_driver
    {{ flutter }} analyze --no-pub
    just test

# Format new adapter/tool/test code; do not restyle frozen upstream GUI.
fix: _deps
    {{ dart }} format lib/harness lib/storage lib/raiju lib/spark lib/features/settings/settings_page/spark_section.dart lib/features/pairing/ompd_pairing_page.dart lib/companion_controller.dart test/harness test/storage test/raiju test/spark test/features/pairing/ompd_pairing_page_test.dart test/helpers/ompd_fixture.dart test/companion_controller_test.dart test/widget_test.dart tool integration_test test_driver

# Build signed debug simulator app with pinned native tools after acceptance gates.
ios-build: check
    node scripts/flutter-tool.mjs ios-dart run tool/ios_dev.dart build

# Boot/select iPhone simulator and run actual app; optional --device lives in helper.
ios-run: _deps
    node scripts/flutter-tool.mjs ios-dart run tool/ios_dev.dart run

# Build, install, and launch a release app using direnv device settings.
ios-device: _deps
    {{ flutter }} clean
    node scripts/build-spark-ios.mjs release
    env GEM_HOME="$PWD/.work/cocoapods-1.16.2" \
        GEM_PATH="$PWD/.work/cocoapods-1.16.2" \
        PATH="$PWD/.work/cocoapods-1.16.2/bin:$(brew --prefix ruby@3.4 2>/dev/null || true)/bin:$PATH" \
        {{ flutter }} build ios --release --device-id "${IOS_DEVICE_ID:?set IOS_DEVICE_ID via direnv}"
    xcrun devicectl device install app --device "${IOS_DEVICE_ID:?set IOS_DEVICE_ID via direnv}" build/ios/iphoneos/Raiju.app
    xcrun devicectl device process launch --device "${IOS_DEVICE_ID:?set IOS_DEVICE_ID via direnv}" "${IOS_BUNDLE_ID:?set IOS_BUNDLE_ID via direnv}"

# Run repeatable original-GUI connect/send/reply/restore check on iOS simulator.
ios-smoke: _deps
    node scripts/flutter-tool.mjs ios-dart run tool/ios_dev.dart smoke

# Run optional daemon start/attach/chat/restore journey over local TCP on iOS.
ompd-ios-smoke: _deps
    node scripts/flutter-tool.mjs ios-dart run tool/ios_dev.dart ompd-smoke

# Check actual daemon interoperability with a synthetic worker, without model calls.
ompd-smoke daemon="ompd": _deps
    {{ dart }} run tool/ompd_smoke.dart --daemon "{{ daemon }}"

# Read selected real OMP session over encrypted collab without sending a prompt.
live-smoke host: _deps
    {{ dart }} run tool/collab_smoke.dart --host "{{ host }}"

# Send one harmless marker prompt to designated cheap OMP host and await reply.
live-chat-smoke host: _deps
    {{ dart }} run tool/collab_smoke.dart --host "{{ host }}" --send

# Verify real iOS chat and process restore; capability stays in private loopback IPC.
ios-live host: _deps
    node scripts/flutter-tool.mjs ios-dart run tool/ios_dev.dart live "{{ host }}"

# Run all portable Rust, Dart domain, widget, and tooling Spark contracts.
spark-test: _deps
    node scripts/spark-test.mjs all

# Run only portable Rust Spark contracts without resolving Flutter packages.
spark-rust-test:
    node scripts/spark-test.mjs rust

# Run only Dart Spark domain contracts.
spark-domain-test: _deps
    node scripts/spark-test.mjs domain

# Run only Spark widget contracts.
spark-widget-test: _deps
    node scripts/spark-test.mjs widgets

# Run only dependency-free Spark tooling fixture contracts.
spark-tooling-test:
    node scripts/spark-test.mjs tooling

# Build Spark static libraries for Apple device and simulator targets.
spark-ios-build profile="debug":
    node scripts/build-spark-ios.mjs "{{ profile }}"

# Run the synthetic Spark start/talk/handoff/minimize/stop simulator journey.
spark-ios-smoke: _deps
    node scripts/spark-simulator.mjs

# Exercise production Dart/native audio/Core/provider path on the iOS simulator.
spark-ios-live:
    node scripts/flutter-tool.mjs ios-dart run tool/ios_dev.dart spark-live

# Probe only broker/auth metadata; requires explicit environment opt-in.
spark-broker-auth-probe: _deps
    node scripts/spark-broker-auth-probe.mjs

# Probe live provider SDP, peer, sideband, text, and audio; requires explicit opt-in.
spark-live-provider-probe: _deps
    node scripts/spark-live-provider-probe.mjs
