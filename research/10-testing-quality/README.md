# 10 · Testing & Quality

| Package | Version | Verdict | Qwave usage |
|---------|---------|---------|-------------|
| [swift-testing](swift-testing.md) | Swift 6.3.2 (bundled) | 🟢 Adopt | All six test targets |
| [swift-snapshot-testing](swift-snapshot-testing.md) | 1.19.4 | 🔵 Trial | `Shields`, `VPNKit` fixtures |

---

## Where Qwave stands

The test coverage in v0.1.0 is better than most v0.1.0 releases:

```
QwaveSupportTests   SecretStoreTests
PersistenceTests    HistoryStore · BookmarkStore · SessionStore
ShieldsTests        ShieldsPolicy · RuleListCompile · HTTPSFirstUpgrader
FeatureFlagsTests   FeatureFlagService
BrowserCoreTests    TabManager · Hibernation · EnergyGovernor · SessionRestorer · OmniboxParser
VPNKitTests         MullvadAPIClient · RelaySelector · DeviceKeyAndAccount · TunnelSessionConfig
```

Every module has tests. `VPNKitTests` has a `MockURLProtocol` and a `relays.json` fixture, which
means the network layer is tested without network access — a sign of deliberate test design
rather than coverage-chasing.

This is a good foundation, and the recommendations here are refinements rather than repairs.

## The two moves

1. **Migrate to [swift-testing](swift-testing.md).** Since 2026 it is the default starting point
   for new Swift tests: `@Test` and `@Suite` instead of class inheritance, `#expect` and
   `#require` instead of 40+ `XCTAssert*` variants, parallel by default, and native async/await
   without ceremony. Both frameworks coexist in one target, and `swift test` runs both and merges
   results — so migration is incremental with no flag day.

2. **Consider [swift-snapshot-testing](swift-snapshot-testing.md)** for the places where Qwave
   compares generated artifacts: compiled `WKContentRuleList` JSON, WireGuard tunnel
   configurations, and Mullvad API decoding. Those are exactly what snapshot testing is for.

## What stays in XCTest

XCTest is not going away and still owns:

- **XCUITest** — UI automation
- **XCTMetric** — performance measurement
- **Objective-C tests**

Performance measurement matters here: measuring `TabHibernator`'s memory reclamation is an
`XCTMetric` job, and [package-benchmark](../11-performance-energy/package-benchmark.md) covers
the rest. So the migration is "new tests in swift-testing, migrate as you touch them", not "port
everything".

## The gap worth naming

Qwave has no **integration test** that exercises a real `WKWebView` against real content. Every
test is a unit test against a mock or fixture.

That is a defensible v0.1.0 trade — WebKit tests are slow and flaky in CI. But the highest-value
untested paths run straight through it: does `TabHibernator` actually reclaim memory? Does
`ShieldsDirector` actually block a request? Does `HTTPSFirstUpgrader` actually upgrade a
navigation?

A small suite of local-fixture WebKit tests — serving pages from a local file URL rather than the
network — would cover the claims in the README that nothing currently verifies.
