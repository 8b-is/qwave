# Swift Testing (`swiftlang/swift-testing`)

| | |
|---|---|
| **Repo** | https://github.com/swiftlang/swift-testing |
| **Version** | **Swift 6.3.2 Release** (May 13) — versioned with the toolchain |
| **License** | Apache 2.0 |
| **Ships with** | Xcode 16+ and the Swift 6 toolchain |
| **Apple Silicon** | Native |
| **Verified** | 2026-08-12 |

---

## What it is

Apple's modern test framework, introduced at WWDC24 and now the default starting point for Swift
tests. It replaces XCTest's class inheritance and 40+ assertion variants with macros:

- **`@Test`** on any function, with any name — no `test` prefix, no subclassing.
- **`@Suite`** to group tests.
- **`#expect`** for soft assertions and **`#require`** for assertions that stop the test.
- **Parallel by default.**
- **Native async/await**, with no expectation-and-waiter ceremony.

Both frameworks coexist in the same test target. SwiftPM's `swift test` and Xcode run both and
merge results, so migration is incremental with no cutover.

## Why it matters for Qwave

Qwave's six test targets are XCTest. Three properties of swift-testing map onto them directly.

### 1. Parameterised tests

`ShieldsPolicyTests`, `OmniboxParserTests`, and `HTTPSFirstUpgraderTests` are all
input→expectation tables — the shape XCTest expresses worst.

```swift
// Every case reported individually; a failure names the input that failed
@Test("Omnibox distinguishes URLs from search queries", arguments: [
    ("example.com",           OmniboxIntent.navigate),
    ("http:\\\\example.com",  .navigate),
    ("swift testing",         .search),
    ("localhost:8080",        .navigate),
    ("what is 2+2",           .search),
])
func omniboxIntent(input: String, expected: OmniboxIntent) {
    #expect(OmniboxParser.parse(input) == expected)
}
```

Under XCTest this is a `for` loop where one failure obscures the rest and the failure message
does not say which input broke.

### 2. Async without ceremony

`VPNKitTests` exercises async API calls; `BrowserCoreTests` covers hibernation, which is
inherently asynchronous. XCTest's `XCTestExpectation` and `wait(for:timeout:)` are a common
source of flaky tests — a timeout that is too short on a loaded CI runner fails a correct test.

```swift
@Test func hibernatedTabRestoresScrollPosition() async throws {
    let tab = try #require(await manager.openTab(url: fixture))
    await hibernator.hibernate(tab)
    let restored = try #require(await manager.wake(tab.id))
    #expect(restored.scrollPosition == tab.scrollPosition)
}
```

### 3. Runtime concurrency diagnostics

Swift 6.2 added runtime detection of concurrency issues while running tests, complementing static
analysis. `BrowserCoreTests` drives exactly the concurrent paths — `TabManager` ↔ `TabHibernator`
↔ `EnergyGovernor` — where a data race would be both plausible and hard to reproduce.

This pairs with the concurrency migration in [PLATFORM-BASELINE.md](../PLATFORM-BASELINE.md):
runtime diagnostics under test are how you gain confidence the migration did not introduce
races.

## Apple Silicon notes

No architecture-specific behaviour. Parallel-by-default execution uses the available cores, which
on M-series means the suite runs meaningfully faster than XCTest's serial default — a real
benefit for CI turnaround.

One caution: parallel execution surfaces shared-state assumptions. `PersistenceTests` targets a
SQLite database, and tests that share a database file will now genuinely run concurrently. Use a
distinct temporary database per test, or `@Suite(.serialized)` where isolation is required.

## Adoption sketch

No package dependency — it ships with the toolchain:

```swift
import Testing        // alongside existing `import XCTest` files
```

Migrate incrementally, highest value first:

1. **`ShieldsPolicyTests`** and **`OmniboxParserTests`** — the biggest parameterisation win.
2. **`VPNKitTests`** — the async ergonomics win.
3. **`BrowserCoreTests`** — concurrency diagnostics, but audit shared state first.
4. **`PersistenceTests`** — last, because parallel execution against SQLite needs isolation work.

New tests use swift-testing from now on regardless of migration progress.

## Risks

- **Parallel-by-default surfaces latent shared state.** The main migration hazard, concentrated in
  `PersistenceTests`. Give each test its own database file.
- **XCTest still owns some ground.** XCUITest, `XCTMetric` performance measurement, and
  Objective-C tests stay. Do not attempt a total migration.
- **Macro-based.** Diagnostics can be less direct than XCTest's when an expectation fails to
  compile.
- **Toolchain coupling.** Versioned with the toolchain, so CI and local toolchains should match —
  another argument for pinning Xcode in CI (see [swift-build](../09-build-tooling/swift-build.md)).

## Verdict

🟢 **Adopt — incrementally, starting with the table-driven suites.**

First-party, bundled, no dependency, and it coexists with XCTest so there is no flag day. The
parameterised-test support alone materially improves `ShieldsPolicyTests` and
`OmniboxParserTests`, which are the suites protecting Qwave's security-relevant parsing.

**The rule worth recording:** new tests use swift-testing. Existing XCTest suites migrate when
they are being modified anyway — no big-bang port.
