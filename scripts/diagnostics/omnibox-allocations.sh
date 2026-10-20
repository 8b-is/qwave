#!/bin/bash
set -euo pipefail

# No installation or global allocator settings. All output is synthetic.
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
JEMALLOC_PREFIX="${JEMALLOC_PREFIX:-$(brew --prefix jemalloc)}"
PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qwave-allocations.XXXXXX")"
trap 'rm -rf "$PROBE_DIR"' EXIT

xcrun swiftc --version >&2
sw_vers >&2
xcrun swiftc -O -target "$(uname -m)-apple-macosx14.0" \
  "$SOURCE_DIR/OmniboxAllocations.swift" \
  -import-objc-header "$SOURCE_DIR/AllocationCounter.h" \
  -Xcc "-I$JEMALLOC_PREFIX/include" \
  -L "$JEMALLOC_PREFIX/lib" -ljemalloc \
  -Xlinker -rpath -Xlinker "$JEMALLOC_PREFIX/lib" \
  -o "$PROBE_DIR/probe"
DYLD_INSERT_LIBRARIES="$JEMALLOC_PREFIX/lib/libjemalloc.2.dylib" "$PROBE_DIR/probe"
