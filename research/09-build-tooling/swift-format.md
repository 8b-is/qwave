# swift-format (`swiftlang/swift-format`)

| | |
|---|---|
| **Repo** | https://github.com/swiftlang/swift-format |
| **Version** | **603.0.0** (Jun 30) |
| **License** | Apache 2.0 |
| **Ships with** | Xcode (also installable standalone) |
| **Apple Silicon** | Native |
| **Verified** | 2026-08-12 |

---

## What it is

The official Swift formatter and linter, maintained by the Swift project. It formats to the
Swift API Design Guidelines by default and is configurable through a `.swift-format` JSON file.

The 603.0.0 release added `InlineArray` type sugar support and a `multilineTrailingCommaBehavior`
option, alongside rule fixes. The version scheme tracks swift-syntax, so `603.x` corresponds to
the current toolchain generation.

Being **first-party and bundled with Xcode** is the decisive property: no Homebrew dependency, no
version negotiation, and the format it produces is the format the ecosystem is converging on.

## Why it matters for Qwave

Qwave has no formatting enforcement today. For a project with an explicit agent-facing
`AGENTS.md`, that matters more than usual: when both humans and agents write code in a
repository, consistent formatting is what keeps diffs meaningful. A diff full of whitespace
churn hides the change that matters, and reviewing agent-authored code is hard enough without it.

Two commands, both cheap:

```bash
# Check — for CI
swift-format lint --strict --recursive Sources Packages

# Fix — for local use
swift-format format --in-place --recursive Sources Packages
```

Adding this to `.github/workflows/ci.yml` costs seconds per run and removes an entire category of
review comment permanently.

## Apple Silicon notes

Native, fast, no architecture concerns. Because it ships with Xcode, the CI runner already has
it — nothing to install, nothing to cache.

## Adoption sketch

A `.swift-format` at the repository root, kept close to defaults:

```json
{
  "version": 1,
  "lineLength": 110,
  "indentation": { "spaces": 4 },
  "respectsExistingLineBreaks": true,
  "lineBreakBeforeEachArgument": false,
  "multilineTrailingCommaBehavior": "always"
}
```

`lineLength` is the only setting worth arguing about. The existing sources read as a
100–120 column codebase; 110 is a reasonable landing point, and it is easy to change once and
never revisit.

CI:

```yaml
- name: Check formatting
  run: swift-format lint --strict --recursive Sources Packages
```

**Do the initial reformat as a single isolated commit** with no logic changes, so `git blame`
has exactly one line to skip. Add it to `.git-blame-ignore-revs` afterwards.

## Risks

- **The first reformat touches every file.** Unavoidable. Isolate it in its own commit and record
  the hash in `.git-blame-ignore-revs`.
- **Version coupling to swift-syntax.** The 603.x scheme tracks the toolchain. CI and local
  toolchains should match, or lint results diverge between machines. Pin the toolchain in CI.
- **Less configurable than [SwiftLint](swiftlint.md).** This is deliberate and mostly a feature —
  fewer knobs, fewer arguments.
- **Formatting is not linting.** swift-format catches style, not bugs. Correctness rules are a
  separate question, covered in the SwiftLint note.

## Verdict

🟢 **Adopt — the first quality gate to add.**

First-party, bundled with Xcode, zero installation, and it settles formatting permanently. For a
repository where agents and humans both write code, consistent formatting is what keeps review
tractable.

**Sequence:** land the `.swift-format` config and the one-shot reformat commit before evaluating
[SwiftLint](swiftlint.md). Once formatting is mechanical, the remaining question is narrowed to
"which correctness rules do we want?" — which is a much better discussion than the one that
starts with brace placement.
