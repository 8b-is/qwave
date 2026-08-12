# SwiftLint (`realm/SwiftLint`)

| | |
|---|---|
| **Repo** | https://github.com/realm/SwiftLint |
| **Version** | **0.65.0** "Fresh Folded Fixtures" (Jun 27) |
| **License** | MIT |
| **Install** | `brew install swiftlint` |
| **Apple Silicon** | Native |
| **Verified** | 2026-08-12 |

---

## What it is

The long-standing Swift linter: 200+ rules covering style, conventions, and a meaningful set of
correctness patterns, with custom-rule support via regex. The 0.65.0 release raised the
development requirement to Swift 6.1 and added Bazel 7–9 support.

Its reach beyond formatting is what distinguishes it from [swift-format](swift-format.md):

- `force_unwrapping`, `force_try`, `force_cast`
- `implicitly_unwrapped_optional`
- `weak_delegate`
- `discarded_notification_center_observer`
- Cyclomatic complexity and file/function length thresholds
- Custom regex rules

## Why it matters for Qwave

The correctness rules matter more here than the style rules, and three are directly relevant to
this codebase:

| Rule | Why it matters in Qwave |
|------|------------------------|
| `force_unwrapping` | A `!` in `VPNKit` or `Persistence` is a crash on malformed API data or a corrupt database. In a browser, a crash loses the user's tabs. |
| `weak_delegate` | `NavigationCoordinator`, `DownloadManager`, and `FindInPageController` are all WebKit delegates. Retain cycles there leak `WKWebView` instances — directly against `TabHibernator`'s entire purpose. |
| `discarded_notification_center_observer` | Same leak class, common in AppKit code. |

The `weak_delegate` case is the strongest. Qwave's memory story *is* the product. A leaked
`WKWebView` from a retained delegate defeats hibernation silently — the tab reports as
hibernated while its content process stays alive.

### Custom rules for Qwave's own invariants

Custom regex rules can encode project-specific rules that no general linter knows:

```yaml
custom_rules:
  no_print:
    regex: '(^|\s)print\('
    message: "Use QwaveSupport.Log — print() leaks to the system log"
    severity: error

  no_direct_keychain:
    regex: 'SecItem(Add|Copy|Update|Delete)'
    message: "Use QwaveSupport.SecretStore, not the Keychain API directly"
    severity: error
```

Both encode real Qwave invariants. `QwaveSupport/Log.swift` and `SecretStore.swift` exist
precisely so nothing else does that work — and `SecretStoreTests` guards the behaviour, but
nothing today guards the *bypass*.

## Apple Silicon notes

Native and fast. Runs against source without a build, so it is much cheaper in CI than
[Periphery](periphery.md).

## Adoption sketch

Add **after** [swift-format](swift-format.md) is in, with formatting rules disabled to avoid
fighting it:

```yaml
# .swiftlint.yml
disabled_rules:              # swift-format owns these
  - line_length
  - trailing_comma
  - opening_brace
  - statement_position

opt_in_rules:
  - force_unwrapping
  - weak_delegate
  - discarded_notification_center_observer
  - empty_count

excluded:
  - .build
  - Packages/WireGuardKit    # vendored upstream — not ours to restyle
```

Excluding vendored WireGuard code is not optional. Linting a pinned upstream dependency produces
noise and creates pressure to modify code that must stay identical to the reviewed revision.

## Risks

- **Overlaps swift-format.** Running both without disabling the overlapping rules produces
  contradictory demands. The `disabled_rules` list above is required, not decorative.
- **200+ rules invites bikeshedding.** Start with the correctness rules listed above and add
  style rules only when there is a concrete reason.
- **0.x version with an active cadence.** Rule behaviour changes between releases and can newly
  fail CI on unchanged code. Pin the version in CI.
- **Homebrew dependency.** Unlike swift-format, it does not ship with Xcode. One more thing to
  install and pin on runners.

## Verdict

🟡 **Assess — adopt the correctness rules, skip the style rules.**

The style half of SwiftLint is redundant once [swift-format](swift-format.md) is in place. The
correctness half is genuinely valuable, and `weak_delegate` alone would justify it in a browser
whose defining feature is memory management.

Held at Assess rather than Trial because the sequencing matters: adopt swift-format first, live
with it, then add SwiftLint with a **deliberately small** rule set focused on correctness and
Qwave's own invariants. Adopting both at once produces a configuration nobody understands and a
CI job everyone learns to ignore.
