#!/bin/sh
#
# Xcode Cloud post-xcodebuild hook. Runs after each xcodebuild action.
#
# Qwave's unit tests live in the QwaveKit Swift package
# (Packages/QwaveKit/Tests), NOT in the app scheme — so an Xcode Cloud "Test"
# action on the Qwave scheme would run nothing, and hand-wiring the package
# tests into a scheme / test plan is fragile because XcodeGen regenerates the
# .xcodeproj (and its schemes) on every build.
#
# So we run the package suite here, after the Build action, mirroring
# .github/workflows/ci.yml (`swift test -c release --package-path Packages/QwaveKit`).
# A non-zero exit fails the Xcode Cloud build, so a failing test blocks the build
# exactly like the GitHub Actions unit-tests lane. Configure the workflow with a
# single Build action (see docs/XCODE_CLOUD.md); this script is the "Test" step.

set -e

# If an Archive action is ever added, don't re-run the suite for it — Build
# already gated on tests. (Any other action, incl. Build, runs the tests.)
if [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ]; then
  echo "==> [ci_post_xcodebuild] archive action — skipping package tests"
  exit 0
fi

cd "${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE:-$(dirname "$0")/..}}"

echo "==> [ci_post_xcodebuild] Running QwaveKit unit tests (swift test -c release)"
swift test -c release --package-path Packages/QwaveKit

echo "==> [ci_post_xcodebuild] Tests passed"
