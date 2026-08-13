#!/bin/bash
# Local mirror of .github/workflows/release.yml — same gates, same artifact
# shapes, driven by what's available on this machine instead of CI secrets.
#
#   scripts/release.sh v0.3.0
#
# Environment (all optional — absent pieces degrade exactly like CI):
#   QWAVE_SIGN_IDENTITY   "Developer ID Application" identity name/hash
#   QWAVE_TEAM_ID         10-char team id (required with QWAVE_SIGN_IDENTITY)
#   QWAVE_NOTARY_PROFILE  notarytool keychain profile (xcrun notarytool
#                         store-credentials) — enables notarize+staple
#   QWAVE_SPARKLE_KEY     path to the EdDSA seed file — enables appcast
set -euo pipefail

TAG="${1:-}"
if [ -z "$TAG" ]; then
  echo "usage: scripts/release.sh vX.Y.Z[-rc.N]" >&2
  exit 64
fi

SPARKLE_VERSION="2.9.5"
SPARKLE_SHA256="015336b601493e05c237964954bff6191370003d94edefe663724c88840d73cc"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
out_dir="build/release"
rm -rf "$out_dir"
mkdir -p "$out_dir"

# --- Version gates (same as CI) ---------------------------------------------
TAG_VERSION="${TAG#v}"
TAG_VERSION="${TAG_VERSION%%-*}"
grep -q "CFBundleShortVersionString: \"${TAG_VERSION}\"" project.yml || {
  echo "❌ ${TAG} does not match CFBundleShortVersionString in project.yml" >&2
  exit 1
}
IFS=. read -r MAJOR MINOR PATCH <<< "$TAG_VERSION"
EXPECTED_BUILD=$((MAJOR * 10000 + MINOR * 100 + PATCH))
[ "$(grep -c "CFBundleVersion: \"${EXPECTED_BUILD}\"" project.yml)" -eq 2 ] || {
  echo "❌ expected CFBundleVersion \"${EXPECTED_BUILD}\" on both targets" >&2
  exit 1
}

# --- Test + generate + build ------------------------------------------------
swift test --package-path Packages/QwaveKit
xcodegen generate --spec project.yml

SIGNED=false
if [ -n "${QWAVE_SIGN_IDENTITY:-}" ] && [ -n "${QWAVE_TEAM_ID:-}" ]; then
  SIGNED=true
  xcodebuild \
    -project Qwave.xcodeproj -scheme Qwave -configuration Release \
    -destination 'platform=macOS' -derivedDataPath build/DerivedDataRelease \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$QWAVE_SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$QWAVE_TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    CODE_SIGN_ENTITLEMENTS="$repo_root/Resources/CI/Distribution-NoVPN.entitlements" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build | xcbeautify
else
  echo "ℹ️ QWAVE_SIGN_IDENTITY/QWAVE_TEAM_ID absent — building unsigned."
  xcodebuild \
    -project Qwave.xcodeproj -scheme Qwave -configuration Release \
    -destination 'platform=macOS' -derivedDataPath build/DerivedDataRelease \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= \
    build | xcbeautify
fi

APP_PATH="build/DerivedDataRelease/Build/Products/Release/Qwave.app"
[ -d "$APP_PATH" ] || { echo "❌ app not found at $APP_PATH" >&2; exit 1; }

# --- Notarize + staple the app (signed builds with a notary profile) --------
NOTARIZED=false
if $SIGNED && [ -n "${QWAVE_NOTARY_PROFILE:-}" ]; then
  NOTARIZED=true
  ditto -c -k --keepParent "$APP_PATH" "$out_dir/Qwave-notarize.zip"
  xcrun notarytool submit "$out_dir/Qwave-notarize.zip" \
    --keychain-profile "$QWAVE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_PATH"
  rm "$out_dir/Qwave-notarize.zip"
  spctl -a -vv "$APP_PATH"
fi

# --- Package ----------------------------------------------------------------
staging="$(mktemp -d)"
cp -R "$APP_PATH" "$staging/"
create-dmg \
  --volname "Qwave" \
  --window-size 540 380 --icon-size 96 \
  --icon "Qwave.app" 140 180 --app-drop-link 400 180 \
  --hide-extension "Qwave.app" \
  --no-internet-enable --skip-jenkins --hdiutil-quiet \
  "$out_dir/Qwave-${TAG}.dmg" "$staging/"
rm -rf "$staging"

if $NOTARIZED; then
  codesign --force --timestamp --sign "$QWAVE_SIGN_IDENTITY" "$out_dir/Qwave-${TAG}.dmg"
  xcrun notarytool submit "$out_dir/Qwave-${TAG}.dmg" \
    --keychain-profile "$QWAVE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$out_dir/Qwave-${TAG}.dmg"
fi

if ! $SIGNED; then
  ditto -c -k --keepParent "$APP_PATH" "$out_dir/Qwave-${TAG}-unsigned.zip"
fi

# --- Appcast (signed+notarized, non-prerelease, key present — same as CI) ---
case "$TAG" in *-*) IS_RC=true ;; *) IS_RC=false ;; esac
if $NOTARIZED && ! $IS_RC && [ -n "${QWAVE_SPARKLE_KEY:-}" ]; then
  curl -fsSL -o "$out_dir/Sparkle-${SPARKLE_VERSION}.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
  echo "${SPARKLE_SHA256}  $out_dir/Sparkle-${SPARKLE_VERSION}.tar.xz" | shasum -a 256 -c -
  mkdir -p "$out_dir/sparkle-dist" "$out_dir/updates"
  tar -xJf "$out_dir/Sparkle-${SPARKLE_VERSION}.tar.xz" -C "$out_dir/sparkle-dist"
  cp "$out_dir/Qwave-${TAG}.dmg" "$out_dir/updates/"
  curl -fsSL -o "$out_dir/updates/appcast.xml" \
    "https://github.com/8b-is/qwave/releases/latest/download/appcast.xml" || true
  "$out_dir/sparkle-dist/bin/generate_appcast" \
    --ed-key-file "$QWAVE_SPARKLE_KEY" \
    --download-url-prefix "https://github.com/8b-is/qwave/releases/download/${TAG}/" \
    -o "$out_dir/updates/appcast.xml" \
    "$out_dir/updates/"
fi

echo
echo "==> Artifacts in $out_dir:"
ls -la "$out_dir" | grep -v "^total\|sparkle-dist\|Sparkle-"
echo "==> signed=$SIGNED notarized=$NOTARIZED"
