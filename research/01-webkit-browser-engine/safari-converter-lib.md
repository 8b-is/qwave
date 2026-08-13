# SafariConverterLib (`AdguardTeam/SafariConverterLib`)

| | |
|---|---|
| **Repo** | https://github.com/AdguardTeam/SafariConverterLib |
| **Version** | **4.3.0** (Jun 4) |
| **License** | LGPL-3.0 — **verify before linking** (see Risks) |
| **Platforms** | macOS, iOS — written in Swift |
| **Apple Silicon** | Pure Swift; runs natively, and is intended to run offline at build time |
| **Verified** | 2026-08-12 |

---

## What it is

AdGuard's converter from **filter-list syntax** (AdGuard rules, EasyList, uBlock-style
cosmetic rules) into the **JSON format `WKContentRuleList` compiles**. It is the library behind
AdGuard's own Safari extensions, and it handles the parts of the translation that are tedious
and easy to get wrong: rule deduplication, `$domain`/`$third-party` modifier mapping, regex
translation to WebKit's supported subset, and the platform's rule-count ceiling.

## Why it matters for Qwave

Qwave ships a **curated 51-rule blocklist** (`Shields/Resources/starter-blocklist.json`) and a
`RuleListCompiler` that feeds it to WebKit. Fifty-one rules is a demonstration that the pipeline
works. EasyList is on the order of tens of thousands.

The gap between those two numbers is not an engineering problem — it is a *sourcing* problem.
Nobody hand-writes `WKContentRuleList` JSON at scale. Every serious Safari-based blocker
consumes community-maintained filter lists, and SafariConverterLib is the mature Swift path
from one to the other.

Critically, this can be a **build-time tool that never ships inside the app**:

```
EasyList / AdGuard Base  ──►  SafariConverterLib  ──►  starter-blocklist.json  ──►  Shields
        (upstream)              (build machine)          (checked in)            (runtime)
```

Under that shape, `Shields/RuleListCompiler.swift` and `BlocklistUpdater.swift` are unchanged.
The app gains a much larger, community-maintained rule set and takes on **zero new runtime
dependencies** — which is the whole point for a sovereign browser.

## Apple Silicon notes

Not a performance-sensitive runtime component under the recommended shape — conversion happens
once on a build machine. The runtime cost that *does* matter is downstream: WebKit compiles the
resulting `WKContentRuleList` into a bytecode matcher, and both compilation time and the
compiled artifact's memory footprint scale with rule count. That is the number to watch on
M-series, and `ShieldsTests/RuleListCompileTests.swift` is already the right place to measure it.

## Adoption sketch

Keep it out of `Package.swift` entirely. Add a separate build-time package:

```
Tools/BlocklistBuilder/          # its own Package.swift, not linked by Qwave.app
  Package.swift                  # depends on SafariConverterLib
  Sources/main.swift             # reads filter lists → writes Shields/Resources/*.json
```

```bash
# Regenerate the shipped blocklist — run manually or in CI, never at app runtime
swift run --package-path Tools/BlocklistBuilder \
  BlocklistBuilder \
  --input  Tools/BlocklistBuilder/Lists/easylist.txt \
  --output Packages/QwaveKit/Sources/Shields/Resources/starter-blocklist.json
```

The generated JSON is committed, reviewed in the diff like any other change, and validated by
the existing `RuleListCompileTests` before it can ship.

## Risks

- **Licensing is the decision.** SafariConverterLib is copyleft-licensed. Under the build-time
  shape above, the *tool* is never distributed and only its JSON output ships — which is the
  standard way this is handled, but **confirm the exact license text and your interpretation
  before writing any code**, and never link it into `Qwave.app`. If that separation cannot be
  maintained cleanly, drop this package.
- **Filter lists have their own licenses.** EasyList and AdGuard lists carry their own terms
  (typically CC BY-SA / GPL). Redistributing generated rules inside a shipped app needs the same
  scrutiny as the converter itself. Attribute in `LICENSE` or a `THIRD-PARTY` notice.
- **WebKit rule limits.** `WKContentRuleList` caps rule counts and supports only a regex subset.
  The converter handles this, but the output must still be validated — a silently truncated
  rule set is worse than a small honest one.
- **Compile cost.** Large rule lists take real time and memory to compile on first launch.
  Compile off the main thread and cache the compiled list; `BlocklistUpdater` is the natural
  owner.

## Verdict

🔵 **Trial — build-time only, pending a license review.**

This is the highest-leverage change available to `Shields`: it takes the blocklist from
demonstration-scale to production-scale without adding a single runtime dependency or changing
the blocking architecture. The engineering is straightforward and reversible.

The license review is a genuine gate, not a formality. Do it first — if the answer is no, the
fallback is generating rules from filter lists with a small purpose-built converter, accepting
lower fidelity on modifier translation.
