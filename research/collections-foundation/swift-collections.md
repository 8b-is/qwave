# swift-collections

| Fact | Value |
|---|---|
| **Repo** | https://github.com/apple/swift-collections |
| **Latest version** | 1.6.0 (verified 2026-08-12) |
| **License** | Apache-2.0 (Swift license) |
| **Platforms** | All Swift platforms |
| **Apple Silicon status** | ✅ Native (pure Swift) |

## What it is

Apple's extended data-structure library: Deque, OrderedSet/OrderedDictionary,
    Heap, TreeSet/Dictionary, and bitsets.

## Why it matters for Qwave

- **ShieldsDirector / TabManager**: ordered semantics without the O(n)
      array scans; an OrderedSet of active content-rule lists or tab order.
    - Bitsets fit the uBO rule pipeline (`UBORuleListCompiler`) nicely.

## Apple Silicon notes

- Pure Swift; identical behaviour on arm64/x86_64; zero risk.

## Adoption sketch

- Add as a direct dependency of QwaveKit; use in TabManager and Shields.

## Risks

- Another Apple package to track; API occasionally shifts on major
      Swift versions (currently very stable).

## Verdict: Adopt
