# XcodeGen (`yonaskolb/XcodeGen`)

| | |
|---|---|
| **Repo** | https://github.com/yonaskolb/XcodeGen |
| **Version** | **2.46.0** (Jul 16) |
| **License** | MIT |
| **Install** | `brew install xcodegen` |
| **Apple Silicon** | Native |
| **Status in Qwave** | **Already integrated** — `project.yml` is the source of truth |
| **Verified** | 2026-08-12 |

---

## What it is

A command line tool that generates an `.xcodeproj` from a YAML or JSON spec plus your folder
structure. The project file becomes a build artifact rather than a checked-in binary blob.

The 2.46.0 release added two things that matter here:

- **Swift package traits support** for remote and local package references.
- **Declaration order preserved** for targets in generated projects, rather than alphabetical
  sorting — which makes generated diffs readable.

## Why it matters for Qwave

It is the build system. `AGENTS.md` §1: *"Never manually edit `.xcodeproj` files. Always modify
`project.yml` and run `xcodegen generate --spec project.yml`."* And `.gitignore` backs it up by
excluding `*.xcodeproj` entirely.

That combination delivers three properties worth naming:

1. **No project file merge conflicts.** The single worst class of conflict in Xcode projects
   simply cannot occur.
2. **Reviewable build configuration.** A change to entitlements, build settings, or target
   membership shows up as a readable YAML diff.
3. **Reproducible builds.** A fresh clone plus `xcodegen generate` produces exactly what CI
   produces.

For a browser shipping a **system extension** — with entitlements, an embedded
`PacketTunnel.systemextension`, and specific signing requirements — having that configuration in
reviewable YAML is a security property, not just an ergonomic one. Entitlement changes are
exactly the thing that should never slip through unnoticed.

### The traits support matters now

The 2.46.0 package traits feature is not abstract here. The
[MLX Swift](../02-on-device-ai/mlx-swift.md) note proposes gating on-device AI behind a SwiftPM
trait so the default build carries no inference dependency. That approach requires trait support
end to end — SwiftPM has it (`swift package show-traits`), and now XcodeGen does too.

## Apple Silicon notes

Native and fast. No architecture concerns.

Note that **Xcode 27 is Apple Silicon-only and requires macOS 26.4+ to run**. Qwave's CI runners
must satisfy that if the project moves to the Xcode 27 toolchain — a CI configuration item, not
an XcodeGen one, but it surfaces here first.

## Adoption sketch

Already in place. Practices worth keeping explicit:

```bash
# The only way to modify the project
$EDITOR project.yml
xcodegen generate --spec project.yml
```

Worth adding to CI — verifying that the checked-in spec generates cleanly:

```yaml
- name: Verify project generation
  run: |
    xcodegen generate --spec project.yml
    test -d Qwave.xcodeproj
```

And a guard against the failure mode `AGENTS.md` §1 exists to prevent:

```yaml
- name: Reject committed xcodeproj
  run: |
    if git ls-files | grep -q '\.xcodeproj'; then
      echo "::error::A .xcodeproj was committed — project.yml is the source of truth"
      exit 1
    fi
```

## Risks

- **Single-maintainer project.** Widely used and steadily released, but it is a bus-factor
  consideration for a core build dependency. The mitigating factor is real: the output is a
  standard `.xcodeproj`, so worst case you commit the generated project and move on.
- **Feature lag behind Xcode.** New Xcode capabilities need XcodeGen support. The 2.46.0 traits
  work shows it is keeping pace.
- **`project.yml` grows.** At 4 KB it is very manageable today. Large specs get unwieldy, which
  is where [Tuist](tuist.md)'s Swift-based configuration starts to appeal.
- **Not installed by SwiftPM.** A Homebrew dependency in the build environment; pin the version
  in CI so a Homebrew update cannot change generation output silently.

## Verdict

🟢 **Adopt — already integrated, and the right choice.**

XcodeGen fits Qwave exactly: a 6-module project that wants reproducible builds and reviewable
configuration without the machinery of a full build system. The zero-hand-edits rule is the
single best build practice in this repository.

**Do not migrate to [Tuist](tuist.md).** Its advantage is caching at a scale Qwave does not
operate at, and XcodeGen's 2.46 traits support covers the one forward-looking need identified in
this research.

**Worth adding:** the CI generation check and the committed-xcodeproj guard above. They turn the
`AGENTS.md` rule from a convention into something enforced.
