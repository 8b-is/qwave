# Swift 6.3 Modernization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Qwave’s owned Swift code to Swift 6 language mode with Swift 6.3 concurrency and observation practices while preserving behavior on macOS 14.

**Architecture:** Migrate package targets in dependency order, keeping UI-owned mutable state on `MainActor` and making cross-boundary values explicitly `Sendable`. Keep Objective-C framework delegates and vendored WireGuard code behind narrow compatibility boundaries.

**Tech Stack:** Swift 6.3.1, Swift Package Manager, XcodeGen, macOS 14 SDK, Swift Concurrency, Observation, Swift Testing, WebKit, NetworkExtension.

**Spec:** `docs/superpowers/specs/2026-08-13-swift-63-modernization-design.md`

## Global Constraints

- Preserve behavior and keep the deployment target at macOS 14.
- Modify `project.yml` and package manifests; never manually edit `Qwave.xcodeproj`.
- Keep vendored/external WireGuard implementation on its compatibility baseline unless a package-boundary diagnostic requires a contained fix.
- Treat complete-concurrency diagnostics as failures; do not silence them with broad `@unchecked Sendable` or `@preconcurrency` imports.
- Use `@concurrent` only for pure, measured CPU-heavy work that should leave an actor.
- Preserve unrelated worktree changes and avoid changing generated/build artifacts.

### Task 1: Establish Swift 6.3 compiler gates

**Files:**
- Modify: `project.yml`
- Modify: `Packages/QwaveKit/Package.swift`
- Modify: `.github/workflows/ci.yml` if the CI compiler/checking flags do not match local builds
- Create: `docs/superpowers/verification/swift-63-baseline.md` only if the existing verification commands need recording

**Interfaces:**
- Consumes: existing mixed Swift 5/6 target settings.
- Produces: reproducible Swift 6 language/concurrency settings for all owned targets and a known baseline diagnostic set.

- [ ] **Step 1: Record the current baseline**

Run:

```bash
swift --version
swift test --package-path Packages/QwaveKit
```

Expected: capture compiler version and all pre-migration test failures before changing settings.

- [ ] **Step 2: Enable owned-target Swift 6 mode and complete checking**

Update `project.yml` from `SWIFT_VERSION: "5.10"` to the Xcode-supported Swift 6 language mode and change `SWIFT_STRICT_CONCURRENCY` from `targeted` to `complete`. In `Packages/QwaveKit/Package.swift`, remove the per-target `.v5` settings from owned targets and use one shared Swift 6 setting with complete strict concurrency. Leave `Packages/WireGuardKit/Package.swift` unchanged unless package diagnostics prove its boundary must change.

- [ ] **Step 3: Generate and compile to expose the first diagnostic set**

Run:

```bash
xcodegen generate --spec project.yml
swift build --package-path Packages/QwaveKit
```

Expected: generated project is current, and failures are compiler diagnostics attributable to the migration rather than stale generated files.

### Task 2: Finish value and service isolation in QwaveKit

**Files:**
- Modify: `Packages/QwaveKit/Sources/URLIdentity/*.swift`
- Modify: `Packages/QwaveKit/Sources/FeatureFlags/*.swift`
- Modify: `Packages/QwaveKit/Sources/Shields/*.swift`
- Modify: `Packages/QwaveKit/Sources/VPNKit/*.swift`
- Modify: `Packages/QwaveKit/Sources/WebExtensions/*.swift`
- Modify: associated tests under `Packages/QwaveKit/Tests/`

**Interfaces:**
- Consumes: Task 1’s Swift 6/complete-checking diagnostics.
- Produces: `Sendable` value models, actor-isolated service ownership, and async APIs that compile without data-race diagnostics.

- [ ] **Step 1: Add or correct tests for cross-task value transfer**

Cover `TunnelSessionConfig`, Mullvad model values, relay selection, feature flag values, URL identity values, extension messages, and blocklist results at their existing test seams. Tests must assert behavior, not compiler implementation details.

- [ ] **Step 2: Make value types explicitly safe to transfer**

Add `Sendable` only to structs/enums whose stored properties are already `Sendable`; replace reference captures in async closures with immutable snapshots. Keep WebKit and NetworkExtension objects actor-bound instead of forcing them into `Sendable`.

- [ ] **Step 3: Isolate mutable services at their ownership boundary**

Mark UI-observed services and registries `@MainActor`; keep URLSession, persistence, and pure policy work nonisolated or actor-isolated according to actual mutable state. Use isolated conformances only when a protocol implementation is intentionally actor-bound.

- [ ] **Step 4: Replace avoidable callback hops**

Use the SDK’s native async APIs where available. Retain checked continuations only for delegate APIs without async equivalents, and enforce one resume path for success, failure, and cancellation.

- [ ] **Step 5: Run focused package tests**

Run:

```bash
swift test --package-path Packages/QwaveKit --filter URLIdentityTests
swift test --package-path Packages/QwaveKit --filter FeatureFlagsTests
swift test --package-path Packages/QwaveKit --filter ShieldsTests
swift test --package-path Packages/QwaveKit --filter VPNKitTests
swift test --package-path Packages/QwaveKit --filter WebExtensionsTests
```

Expected: focused suites pass with no new concurrency warnings or errors.

### Task 3: Modernize compute, persistence, and BrowserCore boundaries

**Files:**
- Modify: `Packages/QwaveKit/Sources/PostQuantum/*.swift`
- Modify: `Packages/QwaveKit/Sources/MemoryWave/*.swift`
- Modify: `Packages/QwaveKit/Sources/Persistence/*.swift`
- Modify: `Packages/QwaveKit/Sources/BrowserCore/*.swift`
- Modify: associated tests under `Packages/QwaveKit/Tests/`

**Interfaces:**
- Consumes: Task 2’s value and service isolation contracts.
- Produces: actor-safe browser state, explicit async boundaries, and isolated CPU-heavy operations.

- [ ] **Step 1: Test actor-safe state transitions**

Extend existing `TabManager`, hibernation, session restoration, persistence, and memory-store tests to exercise operations through their public async APIs and verify state after suspension points.

- [ ] **Step 2: Remove legacy main-thread dispatch from owned async flows**

Replace `DispatchQueue.main.async` in navigation and browser coordination paths with `@MainActor` isolation, `MainActor.assumeIsolated` only when the caller already proves main-actor execution, or `await MainActor.run` at a true boundary.

- [ ] **Step 3: Mark pure expensive operations with explicit execution intent**

For cryptographic, parsing, compression, or summarization work that is proven independent of actor state, use `@concurrent` under Swift 6.3. Do not annotate WebKit, SQLite handles, or mutable stores as concurrent.

- [ ] **Step 4: Run focused and full package tests**

Run:

```bash
swift test --package-path Packages/QwaveKit --filter BrowserCoreTests
swift test --package-path Packages/QwaveKit --filter MemoryWaveTests
swift test --package-path Packages/QwaveKit --filter PersistenceTests
swift test --package-path Packages/QwaveKit
```

Expected: all package tests pass with complete concurrency checking enabled.

### Task 4: Adopt modern observation and app-target isolation

**Files:**
- Modify: `Sources/QwaveApp/BrowserEnvironment.swift`
- Modify: `Sources/QwaveApp/BrowserWindowController.swift`
- Modify: `Sources/QwaveApp/VPNStatusItem.swift`
- Modify: `Sources/QwaveApp/SettingsWindow/*.swift`
- Modify: `Sources/QwaveApp/*.swift` where diagnostics identify app-owned observable state or legacy dispatch hops

**Interfaces:**
- Consumes: Task 2 and Task 3 actor/value contracts.
- Produces: UI state modeled with Observation where appropriate and app callbacks isolated to `MainActor` without redundant dispatching.

- [ ] **Step 1: Add UI state regression coverage**

Cover VPN login/logout state, shield preparation, tab selection, hibernation actions, and settings updates through existing controller/service tests or focused package tests where app-target testing is unavailable.

- [ ] **Step 2: Convert app-owned observable models selectively**

Use `@Observable` for app-owned state models whose views only need Observation. Preserve `ObservableObject` where external Combine publishers or framework integration require it; do not rewrite view code solely for syntax.

- [ ] **Step 3: Apply app-wide main-actor isolation**

Set the Qwave executable target to default main-actor isolation if supported by the Xcode toolchain, then remove redundant annotations and replace main-thread dispatch with structured tasks. Keep background work explicitly `@concurrent` or in a dedicated actor.

- [ ] **Step 4: Build the generated app project**

Run:

```bash
xcodegen generate --spec project.yml
xcodebuild -project Qwave.xcodeproj -scheme Qwave -configuration Debug -sdk macosx build CODE_SIGNING_ALLOWED=NO
```

Expected: the app and PacketTunnel targets compile, with any remaining diagnostics limited to the vendored WireGuard boundary or unavailable signing configuration.

### Task 5: Modernize tests and final verification

**Files:**
- Modify: selected files under `Packages/QwaveKit/Tests/`
- Modify: `.github/workflows/ci.yml`
- Modify: `README.md` or `docs/` only if build/toolchain requirements changed

**Interfaces:**
- Consumes: all migrated module contracts.
- Produces: CI-enforced Swift 6.3 checks and a verified migration with no hidden compatibility flags.

- [ ] **Step 1: Convert stable unit suites to Swift Testing**

Use `@Test`, `#expect`, and parameterized tests for pure parsers, selectors, value models, and policy logic. Keep integration tests using XCTest when they depend on framework lifecycle or existing async test helpers.

- [ ] **Step 2: Add concurrency diagnostics to CI**

Make CI use the same Swift language mode and complete-checking settings as local builds. Ensure generated Xcode projects come from `project.yml` during CI.

- [ ] **Step 3: Run the complete verification set**

Run:

```bash
git diff --check
swift test --package-path Packages/QwaveKit
xcodegen generate --spec project.yml
xcodebuild -project Qwave.xcodeproj -scheme Qwave -configuration Debug -sdk macosx build CODE_SIGNING_ALLOWED=NO
git status --short
```

Expected: package tests and app build exit successfully; generated files are not hand-edited; only intended source/config/docs changes exist on `swift-6.3-modernization`.

