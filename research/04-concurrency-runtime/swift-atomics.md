# swift-atomics (`apple/swift-atomics`)

| | |
|---|---|
| **Repo** | https://github.com/apple/swift-atomics |
| **Version** | 1.x — **maintenance mode in practice** |
| **License** | Apache 2.0 |
| **Platforms** | All Swift platforms |
| **Apple Silicon** | Maps to arm64 atomic instructions |
| **Verified** | 2026-08-12 |

---

## What it is

Apple's package providing atomic operations — `ManagedAtomic`, `UnsafeAtomic`, atomic
load/store/exchange/compare-exchange with explicit memory orderings — for Swift code that needs
lock-free primitives.

It was, for years, the only correct way to write atomics in Swift. It no longer is.

## Why it matters for Qwave

**As a "do not add this" entry.**

The Swift standard library absorbed this category. The `Synchronization` module ships `Atomic`
and `Mutex` as first-class stdlib types with the same memory-ordering vocabulary, no package
dependency, and better integration with Swift 6 concurrency's sendability model.

For new code on a current toolchain, `import Synchronization` is the answer:

```swift
import Synchronization

// Instead of: ManagedAtomic<Int>(0) from swift-atomics
let counter = Atomic<Int>(0)
counter.add(1, ordering: .relaxed)

// And for the far more common case — protecting state:
let state = Mutex<TabState>(.init())
state.withLock { $0.isHibernated = true }
```

There is also a prior question worth asking: **does Qwave need atomics at all?**

Almost certainly not. Actors and structured concurrency cover the coordination Qwave actually
does. `TabManager`, `TabHibernator`, and `EnergyGovernor` coordinate at the granularity of tab
lifecycle events — microseconds apart at worst, not nanoseconds. Reaching for lock-free
primitives there is optimising a problem that does not exist, at the cost of code that is
genuinely hard to review.

If a counter or flag needs protecting, `Mutex` from `Synchronization` is clearer, safer, and
carries no dependency. Under the Swift 6.2 approachable-concurrency model — see
[PLATFORM-BASELINE.md](../PLATFORM-BASELINE.md) — even that need shrinks, because
main-actor-by-default removes much of the shared-mutable-state surface that motivates it.

## Apple Silicon notes

Worth knowing regardless of the verdict: **arm64 has a weaker memory model than x86_64**. Code
that happens to work on Intel because of stronger implicit ordering can fail on Apple Silicon
when orderings are specified loosely. Since Qwave is Apple Silicon-only, any hand-written
lock-free code is running on the architecture that punishes ordering mistakes.

That is an argument for `Mutex` over atomics generally, not just for avoiding this package.

## Adoption sketch

None. If atomics are genuinely needed:

```swift
import Synchronization   // stdlib — no package dependency
```

## Risks

Not applicable — the recommendation is not to adopt. The risk being managed is depending on a
package whose job the platform now does, which quietly adds a dependency and diverges new code
from the stdlib idiom every other Swift codebase is converging on.

## Verdict

🔴 **Hold — superseded by the standard library.**

The package remains correct and well-engineered; it simply has no reason to exist in a new
codebase on a current toolchain. `import Synchronization` gives you `Atomic` and `Mutex` with no
dependency.

**The stronger recommendation:** Qwave should need neither. Actors and structured concurrency
cover its coordination requirements, and `Mutex` covers the residue. If a design appears to need
lock-free atomics, that is a signal to re-examine the design.
