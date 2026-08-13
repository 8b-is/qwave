# swift-snapshot-testing (`pointfreeco/swift-snapshot-testing`)

| | |
|---|---|
| **Repo** | https://github.com/pointfreeco/swift-snapshot-testing |
| **Version** | **1.19.4** (Jul 28) |
| **License** | MIT |
| **Platforms** | macOS, iOS, tvOS, watchOS, Linux |
| **Apple Silicon** | Pure Swift |
| **Verified** | 2026-08-12 |

---

## What it is

A testing library that records a value's representation to a file on first run and compares
against it thereafter. Snapshots can be text, JSON, property lists, or rendered images.

The idea suits any test where the expected value is **large and structured**. Writing the
expectation by hand is tedious and error-prone; reviewing a recorded snapshot in a diff is easy.

## Why it matters for Qwave

Three places where Qwave generates structured artifacts that are currently either
under-asserted or asserted with hand-written expectations.

### 1. Compiled content rule lists — the strongest case

`Shields/RuleListCompiler.swift` turns a blocklist into `WKContentRuleList` JSON.
`RuleListCompileTests` verifies it compiles. It cannot readily verify the *output is what was
intended* without a large hand-written expectation.

```swift
func testStarterBlocklistOutput() throws {
    let json = try RuleListCompiler.compile(.starter)
    assertSnapshot(of: json, as: .json)
}
```

This becomes far more valuable if the [SafariConverterLib](../01-webkit-browser-engine/safari-converter-lib.md)
proposal lands. Regenerating rules from an upstream filter list produces a large diff, and the
question — *did the upstream update change what we block, and how?* — is exactly what a snapshot
diff answers. Without it, a rule regeneration is an unreviewable blob.

### 2. WireGuard tunnel configuration

`VPNKit/TunnelSessionConfig.swift` generates WireGuard configurations.
`TunnelSessionConfigTests` covers it, and the output is precisely the shape snapshot testing
handles well: multi-line, structured, and security-relevant.

A change that silently alters `AllowedIPs` or DNS settings is a **leak**. A snapshot makes that
change impossible to merge unnoticed.

### 3. Mullvad API decoding

`VPNKitTests/Fixtures/relays.json` already exists. Snapshotting the *decoded and filtered* relay
selection catches regressions in `RelaySelector` that a spot-check assertion would miss.

## Apple Silicon notes

No architecture concerns for text and JSON snapshots.

Image snapshots are a different matter and worth avoiding here: rendered output can differ across
OS versions, display scales, and font availability, which produces exactly the flakiness that
gets a test suite disabled. Qwave's valuable snapshots are all textual.

## Adoption sketch

```swift
// Package.swift — test targets only
.package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.19.4")
```

```swift
import SnapshotTesting
import Testing   // works alongside swift-testing

@Test func tunnelConfigForRelay() throws {
    let config = try TunnelSessionConfig(relay: .fixture, key: .fixture)
    assertSnapshot(of: config.wireGuardConfiguration, as: .lines)
}
```

Snapshots are committed under `__Snapshots__/`. **Review them in pull requests like source code**
— an unreviewed snapshot update is how a snapshot suite silently stops testing anything.

That risk is sharper here than in a typical app: a reviewer waving through a
`TunnelSessionConfig` snapshot change is waving through a possible VPN leak.

## Risks

- **Blind re-recording is the failure mode.** When a snapshot fails, the tempting fix is to
  re-record. For security-relevant output that defeats the purpose entirely. Treat snapshot diffs
  in `VPNKit` and `Shields` as requiring the same scrutiny as a code change.
- **Snapshots grow.** A full compiled rule list is a large committed file. Consider snapshotting a
  representative subset or a stable digest plus a sample.
- **Environment sensitivity.** Avoid image snapshots. Keep to text and JSON.
- **A test dependency, not a shipping one.** Contained to test targets, which is the right place —
  but it is still a Point-Free ecosystem dependency to track.

## Verdict

🔵 **Trial — start with `TunnelSessionConfig`.**

Qwave generates exactly the kind of structured artifacts snapshot testing is built for, and two
of the three are security-relevant enough that catching unintended changes has real value.

Start with `TunnelSessionConfig` — the smallest output, the highest stakes, and the clearest
demonstration of the value. Extend to `RuleListCompiler` if the SafariConverterLib work proceeds,
where snapshot diffs become the mechanism for reviewing upstream rule updates.

**Ship it with a review rule:** snapshot changes in `VPNKit` and `Shields` are reviewed as
carefully as code. A snapshot suite nobody reads is worse than no snapshot suite, because it
looks like coverage.
