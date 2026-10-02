#!/bin/bash
# install-nightly — build the bleeding edge and swap it into /Applications.
#
#   tools/install-nightly.sh
#
# Builds the QwaveNightly scheme (every experimental WebKit feature ON),
# quits the running Qwave, and replaces /Applications/Qwave.app. Your
# profile, memory, and history live in ~/Library/Application Support/Qwave
# and survive the swap. Run it again after `git pull` to stay bleeding edge.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="/Applications"
APP="$APP_DIR/Qwave.app"

cd "$ROOT"

echo "── building QwaveNightly ──"
xcodegen generate --spec project.yml

# Pin the destination to the host architecture: a plain `platform=macOS`
# destination builds both slices, and the Rust staticlib cross-compile then
# needs the other arch's rust std installed. Nightly installs are for the
# machine in front of you — one arch, the native one, no extra toolchain.
case "$(uname -m)" in
  arm64) DEST="platform=macOS,arch=arm64" ;;
  x86_64) DEST="platform=macOS,arch=x86_64" ;;
  *)
    echo "error: unsupported host architecture $(uname -m)" >&2
    exit 1
    ;;
esac

BUILD_LOG="$(mktemp -t qwave-nightly-build)"
if ! xcodebuild -project Qwave.xcodeproj -scheme QwaveNightly -configuration Release \
  -destination "$DEST" \
  ONLY_ACTIVE_ARCH=YES \
  QWAVE_CHANNEL=nightly \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= \
  build >"$BUILD_LOG" 2>&1; then
  echo "error: build failed — last lines of the log:" >&2
  tail -40 "$BUILD_LOG" >&2
  echo "full log kept at $BUILD_LOG" >&2
  exit 1
fi
echo "  build succeeded"

BUILT="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path '*Release/Qwave.app' -type d 2>/dev/null | head -1)"
if [ -z "$BUILT" ]; then
  echo "error: built app not found" >&2
  exit 1
fi

echo "── swapping into /Applications ──"
osascript -e 'tell application "Qwave" to quit' 2>/dev/null || true
sleep 1

if [ -d "$APP" ]; then
  echo "  removing previous version"
  rm -rf "$APP"
fi
echo "  installing $BUILT"
ditto "$BUILT" "$APP"

echo "── done ──"
echo "open $APP"
