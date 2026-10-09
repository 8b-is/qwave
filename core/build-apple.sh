#!/bin/bash
# build-apple.sh — build the sovereign core for the platform Xcode is
# currently building, and lipo the slices into one staticlib.
#
# Invoked by the pre-build scripts of the Qwave (macOS) and QwaveIOS targets;
# never run by hand without Xcode's exported build settings. Reads
# PLATFORM_NAME / ARCHS / QWAVE_CHANNEL / PROJECT_DIR from the environment
# and writes core/target/apple/<PLATFORM_NAME>/libqwave_core.a.
set -euo pipefail

if ! command -v cargo >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
  echo "error: cargo not found — the sovereign core needs Rust (rustup.rs)" >&2
  exit 1
fi
# rustup's shim first when present (its std targets are what cross-arch
# builds resolve against); Homebrew cargo is the fallback.
export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0
export IPHONEOS_DEPLOYMENT_TARGET=15.0

# Nightly links the mem|16-10 sovereign library (AGPL-3.0-only); stable must
# not — that keeps the shipped binary's MIT posture. A plain string, not an
# array: this script runs under macOS bash 3.2, where expanding an empty
# array trips `set -u`.
FEATURE_ARGS=""
if [ "${QWAVE_CHANNEL:-stable}" = "nightly" ]; then
  FEATURE_ARGS="--features nightly"
fi

# Map the architectures Xcode wants (ARCHS) onto cargo targets per platform.
# A Release build for `-destination platform=macOS` (or the iOS Simulator) is
# universal, and a single-arch staticlib fails the other slice's link — the
# install-nightly.sh failure this guards against.
CARGO_TARGETS=()
for arch in ${ARCHS}; do
  case "${PLATFORM_NAME:-macosx}-$arch" in
    macosx-arm64) CARGO_TARGETS+=(aarch64-apple-darwin) ;;
    macosx-x86_64) CARGO_TARGETS+=(x86_64-apple-darwin) ;;
    iphoneos-arm64) CARGO_TARGETS+=(aarch64-apple-ios) ;;
    iphonesimulator-arm64) CARGO_TARGETS+=(aarch64-apple-ios-sim) ;;
    iphonesimulator-x86_64) CARGO_TARGETS+=(x86_64-apple-ios-sim) ;;
  esac
done
if [ "${#CARGO_TARGETS[@]}" -eq 0 ]; then
  echo "error: no supported architecture in ARCHS='${ARCHS}' for ${PLATFORM_NAME:-macosx}" >&2
  exit 1
fi

# The toolchain may not know a target at all (rustc 1.99 dropped
# x86_64-apple-ios-sim; Apple dropped x86_64 Simulator slices with it).
# For those slices, compile the safe-fail stubs (core/stubs) with clang so
# the fat staticlib still carries every architecture Xcode links — the
# behavior there is "nothing permitted / nothing valid", which is the
# honest answer for a platform rustc itself no longer supports.
SUPPORTED_TARGETS="$(rustc --print=target-list)"
CARGO_TARGETS_FINAL=()
STUB_ARCHES=()
# Bash 3.2 treats an empty array as unset under set -u. The guarded
# expansions below preserve zero arguments without an unbound-array error.
for target in ${CARGO_TARGETS[@]+"${CARGO_TARGETS[@]}"}; do
  if printf '%s\n' "$SUPPORTED_TARGETS" | grep -qx "$target"; then
    CARGO_TARGETS_FINAL+=("$target")
  else
    case "$target" in
      x86_64-apple-ios-sim) STUB_ARCHES+=(x86_64) ;;
      *) echo "error: rustc does not support $target and no stub exists for it" >&2; exit 1 ;;
    esac
    echo "warning: rustc does not support $target — compiling the safe-fail stubs for that slice" >&2
  fi
done
if [ "${#CARGO_TARGETS_FINAL[@]}" -eq 0 ] && [ "${#STUB_ARCHES[@]}" -eq 0 ]; then
  echo "error: no buildable architecture in ARCHS='${ARCHS}' for ${PLATFORM_NAME:-macosx}" >&2
  exit 1
fi
CARGO_TARGETS=(${CARGO_TARGETS_FINAL[@]+"${CARGO_TARGETS_FINAL[@]}"})

HOST_TRIPLE="$(rustc -vV | sed -n 's/^host: //p')"
for target in ${CARGO_TARGETS[@]+"${CARGO_TARGETS[@]}"}; do
  if [ "$target" = "$HOST_TRIPLE" ]; then
    continue # the host std is always present
  fi
  if ! rustup target list --installed 2>/dev/null | grep -qx "$target"; then
    echo "error: rust target $target is not installed — run: rustup target add $target" >&2
    exit 1
  fi
done

echo "building qwave-core for ${CARGO_TARGETS[*]}${STUB_ARCHES:+ (stub slices: ${STUB_ARCHES[*]})} (${QWAVE_CHANNEL:-stable} channel, ${PLATFORM_NAME:-macosx})"
for target in ${CARGO_TARGETS[@]+"${CARGO_TARGETS[@]}"}; do
  cargo build --release $FEATURE_ARGS \
    --target "$target" \
    --manifest-path "${PROJECT_DIR}/core/Cargo.toml"
done

# Stub slices for targets rustc dropped: a tiny safe-fail staticlib per arch.
for arch in ${STUB_ARCHES[@]+"${STUB_ARCHES[@]}"}; do
  STUB_DIR="${PROJECT_DIR}/core/target/stub-${arch}"
  mkdir -p "$STUB_DIR"
  SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
  xcrun clang -target "${arch}-apple-ios15.0-simulator" -isysroot "$SDK_PATH" \
    -I "${PROJECT_DIR}/core/include" \
    -c "${PROJECT_DIR}/core/stubs/qwave_core_stubs.c" \
    -o "$STUB_DIR/qwave_core_stubs.o"
  xcrun libtool -static -o "$STUB_DIR/libqwave_core.a" "$STUB_DIR/qwave_core_stubs.o"
done

LIPO_IN=()
for target in ${CARGO_TARGETS[@]+"${CARGO_TARGETS[@]}"}; do
  LIPO_IN+=("${PROJECT_DIR}/core/target/${target}/release/libqwave_core.a")
done
for arch in ${STUB_ARCHES[@]+"${STUB_ARCHES[@]}"}; do
  LIPO_IN+=("${PROJECT_DIR}/core/target/stub-${arch}/libqwave_core.a")
done

OUT_DIR="${PROJECT_DIR}/core/target/apple/${PLATFORM_NAME:-macosx}"
mkdir -p "$OUT_DIR"
if [ "${#LIPO_IN[@]}" -eq 1 ]; then
  cp "${LIPO_IN[0]}" "$OUT_DIR/libqwave_core.a"
else
  xcrun lipo -create "${LIPO_IN[@]}" -output "$OUT_DIR/libqwave_core.a"
fi
