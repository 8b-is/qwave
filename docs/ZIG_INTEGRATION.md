# Zig Integration — Build Pattern & Institutional Knowledge

> Three fixes that make the Zig ↔ Swift build chain work. These are **foundations, not warts** — never remove or simplify them without understanding why each exists.

---

## Build chain overview

```
zig build-lib src/packet.zig -O ReleaseSafe -target aarch64-macos -femit-bin=...
  → libqpacket.a (per-arch slice)
lipo -create arm64.a x86_64.a -output libqpacket.a
  → universal binary
XcodeGen preBuildScript → links into PacketTunnel.systemextension via -lqpacket
```

## Fix 1: Zig must be installed in any job that builds the app

**When:** e34f0f8

**Problem:** The app-build CI job (`xcodebuild -project Qwave.xcodeproj ...`) does not run the `zig-validation` job's steps. The XcodeGen preBuildScript on the PacketTunnel target calls `zig build-lib`, but Zig was only installed in the `zig-validation` job. The app-build job failed with `zig: command not found`.

**Fix:** Add `brew install zig` to the app-build job's steps, before the `xcodebuild` invocation.

**Rule:** Any CI job that builds the app target (Qwave.app or PacketTunnel.systemextension) must have Zig installed. The preBuildScript[0] is load-bearing — it runs during every Xcode build.

---

## Fix 2: Universal binary requires per-`$ARCHS` slices + `lipo`

**When:** 7bc039c

**Problem:** The preBuildScript originally compiled a single `aarch64-macos` slice. On Apple Silicon Macs, Xcode's `ARCHS` is `arm64` — this works. But CI on GitHub-hosted macos-15 can report `ARCHS = "x86_64 arm64"`, so `zig build-lib ... -target aarch64-macos` produces a single-arch `.a` that the linker rejects at the universal-binary stage.

**Fix:** Iterate over `$ARCHS` and build one slice per architecture, then `lipo -create` them into a single universal `.a`:

```bash
cd "${PROJECT_DIR}/zig-core"
ARCHS_ARRAY=($ARCHS)
LIBS=()
for ARCH in "${ARCHS_ARRAY[@]}"; do
  ZIG_TARGET="${ARCH/macOS/macos}"  # x86_64 → x86_64-macos, arm64 → aarch64-macos
  ZIG_TARGET="${ZIG_TARGET/arm64/aarch64}"
  zig build-lib src/packet.zig -O ReleaseSafe -target "${ZIG_TARGET}-macos" \
    -femit-bin="${BUILT_PRODUCTS_DIR}/libqpacket-${ARCH}.a"
  LIBS+=("${BUILT_PRODUCTS_DIR}/libqpacket-${ARCH}.a")
done
lipo -create "${LIBS[@]}" -output "${BUILT_PRODUCTS_DIR}/libqpacket.a"
```

**Rule:** Never ship a single-arch `.a` from a preBuildScript. The `lipo` step is mandatory. The `$ARCHS` variable is set by Xcode and may contain multiple values on CI runners.

---

## Fix 3: `-fcompiler-rt` bundles Zig's runtime symbols

**When:** 9b38405

**Problem:** The `qpacket_filter` static library uses Zig's runtime for stack probing (`__zig_probe_stack`). On `aarch64-macos`, this symbol is resolved by the compiler-rt built into the Zig toolchain. On `x86_64-macos`, the system linker cannot find this symbol — it's not in the system libc/libSystem, and the Zig compiler-rt was not bundled into the `.a`.

**Fix:** Add `-fcompiler-rt` to the `zig build-lib` invocation:

```bash
zig build-lib src/packet.zig -O ReleaseSafe -target "${ZIG_TARGET}-macos" \
  -femit-bin="${BUILT_PRODUCTS_DIR}/libqpacket-${ARCH}.a" \
  -fcompiler-rt
```

This bundles Zig's compiler-rt (including `__zig_probe_stack`) into the static library so the system linker can resolve it on both architectures.

**Rule:** Always pass `-fcompiler-rt` when building a Zig static library for consumption by a non-Zig linker. Without it, cross-architecture linking may fail on missing runtime symbols.

---

## Canonical preBuildScript

```bash
set -euo pipefail
if ! command -v zig >/dev/null 2>&1; then
  echo "error: Zig not found — install with: brew install zig" >&2
  exit 1
fi
cd "${PROJECT_DIR}/zig-core"
ARCHS_ARRAY=($ARCHS)
LIBS=()
for ARCH in "${ARCHS_ARRAY[@]}"; do
  ZIG_TARGET="${ARCH/macOS/macos}"
  ZIG_TARGET="${ZIG_TARGET/arm64/aarch64}"
  zig build-lib src/packet.zig -O ReleaseSafe -target "${ZIG_TARGET}-macos" \
    -femit-bin="${BUILT_PRODUCTS_DIR}/libqpacket-${ARCH}.a" \
    -fcompiler-rt
  LIBS+=("${BUILT_PRODUCTS_DIR}/libqpacket-${ARCH}.a")
done
lipo -create "${LIBS[@]}" -output "${BUILT_PRODUCTS_DIR}/libqpacket.a"
```