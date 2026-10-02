#!/bin/bash
# release-nightly.sh — package the bleeding edge and publish it to the
# GitHub `nightly` prerelease channel.
#
#   scripts/release-nightly.sh
#
# The nightly posture: QwaveNightly (every experimental WebKit feature ON,
# mem|16-10 linked, AGPL included), universal Release build, UNSIGNED, no
# appcast — nightly must never enter the EdDSA-trusted stable update feed,
# and the signed+notarised lane is the stable release's job. Artifacts land
# in build/release-nightly/ and are attached to the rolling `nightly`
# prerelease by the caller (gh release delete nightly && gh release create).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

STAMP="$(date -u +%Y%m%d)"
out_dir="build/release-nightly"
rm -rf "$out_dir"
mkdir -p "$out_dir"

echo "── tests ──"
swift test --package-path Packages/QwaveKit

echo "── building QwaveNightly (universal Release) ──"
xcodegen generate --spec project.yml
xcodebuild \
  -project Qwave.xcodeproj -scheme QwaveNightly -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/DerivedDataNightly \
  QWAVE_CHANNEL=nightly \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= \
  build | xcbeautify

APP_PATH="build/DerivedDataNightly/Build/Products/Release/Qwave.app"
[ -d "$APP_PATH" ] || { echo "❌ app not found at $APP_PATH" >&2; exit 1; }

echo "── packaging ──"
ditto -c -k --keepParent "$APP_PATH" "$out_dir/Qwave-nightly-${STAMP}.zip"

if command -v create-dmg >/dev/null 2>&1; then
  staging="$(mktemp -d)"
  cp -R "$APP_PATH" "$staging/"
  create-dmg \
    --volname "Qwave Nightly" \
    --window-size 540 380 --icon-size 96 \
    --icon "Qwave.app" 140 180 --app-drop-link 400 180 \
    --hide-extension "Qwave.app" \
    --no-internet-enable --skip-jenkins --hdiutil-quiet \
    "$out_dir/Qwave-nightly-${STAMP}.dmg" "$staging/"
  rm -rf "$staging"
else
  staging="$(mktemp -d)"
  cp -R "$APP_PATH" "$staging/"
  ln -s /Applications "$staging/Applications"
  hdiutil create -volname "Qwave Nightly" -srcfolder "$staging" -ov -format UDZO \
    "$out_dir/Qwave-nightly-${STAMP}.dmg" >/dev/null
  rm -rf "$staging"
fi

SHA="$(git rev-parse --short HEAD)"
ls -la "$out_dir" | grep -v "^total"
echo
echo "==> nightly $STAMP @ $SHA — publish with:"
echo "    git push origin HEAD:refs/tags/nightly -f"
echo "    gh release delete nightly -y 2>/dev/null"
echo "    gh release create nightly $out_dir/Qwave-nightly-${STAMP}.zip $out_dir/Qwave-nightly-${STAMP}.dmg \\"
echo "      --prerelease --title 'Qwave nightly' --target main --notes 'rolling build of main @ $SHA ($STAMP)'"
