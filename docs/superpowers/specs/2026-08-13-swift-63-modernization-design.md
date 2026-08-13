# Swift 6.3 Modernization Design

## Goal

Move Qwave’s owned Swift code to the current Swift 6.3 language model and use modern concurrency and observation features consistently, while preserving behavior and keeping the vendored WireGuard implementation isolated from the migration.

## Scope

- Set the Qwave app target and owned QwaveKit targets to Swift 6 language mode.
- Enable complete concurrency checking for owned targets and migrate diagnostics module by module.
- Add explicit `Sendable`, actor isolation, and isolated conformances where they describe real ownership and data-flow boundaries.
- Replace avoidable `DispatchQueue` hops and callback-based continuations with native async APIs.
- Use Swift 6.2/6.3 concurrency features, including caller-isolated async functions and `@concurrent` only for work that should leave an actor.
- Migrate app-owned observable state to Observation where it reduces existing `ObservableObject`/Combine plumbing without changing UI behavior.
- Convert suitable package tests to Swift Testing and retain existing XCTest coverage where framework or integration constraints make conversion noisy.
- Evaluate Swift 6.3 `@c` only at the existing Zig/C interop boundary; do not introduce it into unrelated Swift APIs.

## Non-goals

- No broad API redesign or feature changes.
- No migration of vendored or externally sourced WireGuard UI/support code unless required to compile its package boundary.
- No deployment-target increase beyond macOS 14.
- No speculative adoption of experimental Swift features that are not needed by Qwave’s current architecture.

## Migration order

1. Align package and Xcode language/concurrency settings and establish the baseline build/test commands.
2. Migrate foundational modules: `QwaveSupport`, `Persistence`, and `URLIdentity`.
3. Migrate policy and service modules: `FeatureFlags`, `Shields`, `VPNKit`, and `WebExtensions`.
4. Migrate compute/storage modules: `PostQuantum` and `MemoryWave`.
5. Reconcile `BrowserCore`, the Qwave app target, and Objective-C framework boundaries.
6. Modernize tests and remove only migration-created compatibility code.

## Concurrency rules

- UI-facing reference types are `@MainActor` when their mutable state is UI-owned.
- Cross-actor value types conform to `Sendable` only when their stored values make that guarantee true.
- Delegate and framework callbacks keep the isolation required by their SDK signatures, with narrow adapters at the boundary.
- CPU-heavy pure work may use `@concurrent`; network, WebKit, and persistence operations retain the executor appropriate to their ownership model.
- Checked continuations remain only where the SDK has no async alternative and must have one-shot completion handling.

## Verification

- Run package tests before and after each migration stage.
- Build the generated Xcode project from `project.yml`; never edit the generated project directly.
- Treat complete-concurrency diagnostics as migration failures, not warnings to suppress.
- Verify the parent worktree remains unchanged and report any pre-existing failures separately.

