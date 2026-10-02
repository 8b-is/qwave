#!/bin/sh
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
xcodebuild -project Qwave.xcodeproj -scheme QwaveNightly -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= \
  build | tail -1

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
