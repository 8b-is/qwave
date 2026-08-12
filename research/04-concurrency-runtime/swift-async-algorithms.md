# swift-async-algorithms (`apple/swift-async-algorithms`)

| | |
|---|---|
| **Repo** | https://github.com/apple/swift-async-algorithms |
| **Version** | **1.1.5** (Jun 29) |
| **License** | Apache 2.0 |
| **Platforms** | All Swift platforms |
| **Apple Silicon** | Pure Swift |
| **Verified** | 2026-08-12 |

---

## What it is

Apple's package of algorithms over `AsyncSequence` — the async counterparts to `map`, `filter`,
`zip`, plus the ones that only make sense in time: `debounce`, `throttle`, `merge`, `combineLatest`,
`chunked(byTime:)`.

The 1.1.5 release was substantial on the streaming side: final-element support in
`AsyncStreaming`, bidirectional adapters for async writers, a new
`MultiProducerSingleConsumerChannel`, and a redesigned `AsyncReader.collect`.

## Why it matters for Qwave

Three places where the code currently does by hand what an operator does correctly.

### 1. Omnibox input — `debounce`

`QwaveApp/OmniboxField.swift` and `BrowserCore/OmniboxParser.swift` handle typed input. Every
browser debounces this: you do not want to hit `HistoryStore` and rank suggestions on every
keystroke. Hand-rolled debouncing with `Task` cancellation and timers is a classic source of
races — a cancelled task that already scheduled its continuation, a stale result arriving after
a newer one.

```swift
for await query in omniboxInput.debounce(for: .milliseconds(150)) {
    await suggestions.update(for: query)
}
```

That is the whole thing, and it is correct by construction.

### 2. Blocklist updates — `throttle` and `chunked`

`Shields/BlocklistUpdater.swift` fetches and recompiles rule lists. Recompiling a
`WKContentRuleList` is expensive — WebKit builds a bytecode matcher — so coalescing update
signals rather than reacting to each one directly serves the `EnergyGovernor` story.

### 3. VPN state — `combineLatest`

`VPNKit/TunnelManager.swift` and `QwaveApp/VPNStatusItem.swift` must reflect tunnel status,
relay selection, and account state together. `combineLatest` expresses "the menu bar item
depends on all three" without a hand-written coordinator holding three cached values and a
dirty flag.

## Apple Silicon notes

No architecture-specific behaviour. The relevant property is energy, not throughput: `debounce`
and `throttle` reduce work that would otherwise wake cores. On Apple Silicon, where the
efficiency/performance core split makes wakeup patterns matter to battery life, doing less work
less often is the whole game — and it is Qwave's stated differentiation.

## Adoption sketch

```swift
.package(url: "https://github.com/apple/swift-async-algorithms", from: "1.1.5")
```

```swift
// BrowserCore — replace hand-rolled debounce
import AsyncAlgorithms

func observeOmnibox(_ input: some AsyncSequence<String, Never>) async {
    for await query in input.debounce(for: .milliseconds(150)) {
        await updateSuggestions(for: query)
    }
}
```

Start with the omnibox. It is user-visible, easy to feel, and `OmniboxParserTests` gives a place
to prove behaviour.

## Risks

- **Interacts with the concurrency migration.** These operators are most ergonomic under the
  Swift 6.2 model. Adopting them while still on the 5.10 `targeted` stance may produce sendability
  friction. Sequencing suggestion: migrate `BrowserCore` to 6.2 first, then adopt.
- **`AsyncSequence` ergonomics are still sharp-edged.** Typed-throws `AsyncSequence` improved
  matters, but bridging AppKit callbacks (`NSTextField` delegates) into an `AsyncStream` is
  boilerplate you write once and get subtly wrong the first time.
- **Cancellation semantics.** Operators like `debounce` hold pending work. Ensure cancellation
  propagates when a tab closes mid-flight — a genuine leak class.
- **1.x, but moving.** 1.1.5 restructured streaming APIs. Source-stable within 1.x, but read
  release notes on minor bumps.

## Verdict

🔵 **Trial — start with the omnibox debounce.**

Apple-maintained, directly applicable to at least three existing Qwave subsystems, and it
replaces hand-rolled timing logic — reliably among the buggiest code in any app — with tested
operators.

Held at Trial rather than Adopt only because it is best sequenced **after** the Swift 6.2
concurrency migration. Adopting async operators while still on the 5.10 `targeted` stance means
fighting sendability diagnostics that the newer model simply removes.
