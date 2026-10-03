# mobile worktrees

Develop in standalone `raiju-mobile`. Raiju's `mobile/` submodule is a separate checkout, not this clone's linked worktree. ADR-018 ownership remains unchanged; setup changes no GUI, app identity, signing, device or private storage.

## setup and use

Requires Git, Worktrunk (`wt`), `just`, Node and Flutter 3.41.7 / Dart 3.11.5. The existing `scripts/flutter-tool.mjs` resolves the SDK; `FLUTTER`/`DART` overrides remain supported. Native iOS tools are not installed by the hook; see `development.md`. On a new machine use `wt config shell install` for interactive switching.

From primary:

```fish
wt config state default-branch set main
wt config approvals add
wt switch --create topic-name --base=main
```

Review hooks before approving. Default path is sibling `raiju-mobile.topic-name`. Local `main` is home/base; setup does not fetch branch tips or publish.

The synchronous `pre-start` hook runs target's `just install`, resolving packages through `flutter pub get --enforce-lockfile`. Flutter regenerates checkout-specific package/plugin paths. Do not copy `.dart_tool`, `build`, Pods, native output or `.work` from primary. Linked artifact/source roots are rejected; the SDK and package download cache may remain shared. Do not point `CARGO_TARGET_DIR` at another worktree's outputs.

No CocoaPods installation, Rust/iOS build, simulator/device action, app launch or credential access. No private `.envrc` copy or automatic `direnv allow`. Ordinary package-resolution hooks may run as part of Flutter's maintained install command.

Physical-device setup remains explicit: create target-local `.envrc` from `.envrc.example`, configure private values locally, review and approve with `direnv allow`. Never commit those values. Worktrees retain the same app identity and can address the same installed app data; they are not separate device profiles.

## repair and removal

Switching to an existing worktree does not rerun setup. From primary:

```fish
wt hook pre-start --worktree-path=/absolute/path/to/raiju-mobile.topic-name
```

Use this after `git worktree add` or a failed install. Fix missing SDK/toolchain or lock incompatibility without blindly regenerating locks. Remove only rejected symlinks, not their targets.

Review tracked, untracked and ignored files and unpublished commits before:

```fish
wt remove topic-name --foreground
```

Do not force-remove user work. `wt merge` can stage all changes by default; inspect staged files before integration. No automatic push or Raiju workspace submodule update occurs.
