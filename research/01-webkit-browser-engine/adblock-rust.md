# adblock-rust (`brave/adblock-rust`)

| | |
|---|---|
| **Repo** | https://github.com/brave/adblock-rust |
| **Version** | **No tagged GitHub releases** — versioned on crates.io as `adblock` |
| **License** | MPL-2.0 |
| **Platforms** | Rust library; C FFI available |
| **Apple Silicon** | Compiles arm64-native via `cargo`; requires a Rust toolchain in the build |
| **Verified** | 2026-08-12 |

---

## What it is

The content-blocking engine inside Brave. It parses filter-list syntax natively and matches
requests **in-process**, supporting the full modifier vocabulary that `WKContentRuleList` cannot
express: `$redirect`, `$removeparam`, `$csp`, cosmetic filtering with scriptlet injection, and
per-request procedural rules.

Qwave's README describes its shields as **"Brave-style"**. This is the actual Brave engine.

## Why it matters for Qwave

It is the ceiling of what content blocking can be — and understanding *why it does not fit
today* is more useful than adopting it.

`WKContentRuleList` is declarative and evaluated inside WebKit's networking process. You hand
WebKit a compiled rule set and WebKit enforces it, at native speed, with no per-request
round-trip to your code. That is why Qwave's `EnergyGovernor` story is credible: blocking costs
approximately nothing in the app process.

adblock-rust inverts that. To match in-process you must see every request, which on WebKit means
either a `WKURLSchemeHandler` (only for custom schemes — not usable for `https://`) or routing
traffic through your own networking layer. Brave can do this because Brave forks Chromium and
owns the network stack. **Qwave is WebKit-native by design and does not own the network stack.**

That leaves one honest use: **build-time rule generation**, the same shape as
[SafariConverterLib](safari-converter-lib.md) — parse filter lists with adblock-rust, emit
`WKContentRuleList` JSON. But SafariConverterLib is already written in Swift, already targets
exactly this output format, and adds no Rust toolchain to the build. For that job it wins on
every axis.

## Apple Silicon notes

Rust's `aarch64-apple-darwin` target is fully mature and adblock-rust compiles cleanly for it.
The engine's matching is genuinely fast — Brave has invested heavily in the data structures.
None of that helps here, because the bottleneck is architectural, not computational.

The build-side cost is real: adding `cargo` to Qwave's toolchain means CI installs and caches a
Rust toolchain, `project.yml` gains a build phase, and reproducible builds now depend on
`Cargo.lock` as well as `Package.resolved`.

## Adoption sketch

Not recommended — recorded for completeness. If a spike is ever justified, the shape is a
static library plus a C header consumed through a SwiftPM system library target:

```bash
cargo build --release --target aarch64-apple-darwin   # → libadblock.a
```

```swift
// Package.swift — a systemLibrary target wrapping the C FFI header
.systemLibrary(name: "CAdblock", path: "Sources/CAdblock")
```

Doing this properly also means owning cross-language memory safety at the boundary, `cbindgen`
header generation, and a signing/notarisation story for a statically linked Rust artifact.

## Risks

- **Architectural mismatch.** In-process matching requires owning the network stack. Qwave
  deliberately does not.
- **Toolchain weight.** Rust in the build pipeline, for a browser whose entire build story is
  currently "XcodeGen + SwiftPM".
- **MPL-2.0 file-level copyleft.** Manageable — it is per-file, not viral across the app — but
  it is another obligation to track and document.
- **Supply chain.** A sovereign browser adding a Rust dependency tree is adding a second
  ecosystem's worth of transitive dependencies to audit.

## Verdict

🟡 **Assess — documented so it is not re-proposed.**

The right response to "Qwave's shields should be more like Brave's" is
[SafariConverterLib](safari-converter-lib.md) plus a larger rule set, not this. adblock-rust
becomes worth revisiting only if Qwave ever gains its own request-interception layer — for
instance if the VPN's `PacketTunnel` grows DNS-level or packet-level filtering, at which point
the engine would live in the extension, not the browser.

That is a genuinely interesting future, and it is **Stage C territory**, not now.
