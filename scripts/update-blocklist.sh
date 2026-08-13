#!/bin/bash
# Regenerates the bundled EasyList-derived content-blocker snapshot:
#   Packages/QwaveKit/Sources/Shields/Resources/easylist-compiled.json
#
# License boundary (see docs/BLOCKLIST.md): AdGuard's SafariConverterLib is
# GPL-3.0 and is used strictly as an EXTERNAL BUILD-TIME tool - cloned and
# built in a temp directory, invoked as a separate process, never linked,
# bundled, or vendored into Qwave. Only its plain content-blocker JSON output
# ships, which is a transformation of EasyList's data. EasyList is
# dual-licensed GPLv3 / CC BY-SA 3.0; Qwave elects the CC BY-SA 3.0 branch
# and ships attribution next to the snapshot.
set -euo pipefail

CONVERTER_REPO="https://github.com/AdguardTeam/SafariConverterLib.git"
CONVERTER_TAG="v4.3.0"
SAFARI_VERSION="17"
EASYLIST_URL="https://easylist.to/easylist/easylist.txt"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
out_json="${repo_root}/Packages/QwaveKit/Sources/Shields/Resources/easylist-compiled.json"
out_attribution="${repo_root}/Packages/QwaveKit/Sources/Shields/Resources/easylist-compiled-ATTRIBUTION.txt"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo "==> Cloning SafariConverterLib ${CONVERTER_TAG} (build-time tool, GPL-3.0, not shipped)"
git clone --quiet --depth 1 --branch "$CONVERTER_TAG" "$CONVERTER_REPO" "$workdir/converter"

echo "==> Building ConverterTool"
swift build -c release --product ConverterTool --package-path "$workdir/converter"

echo "==> Fetching EasyList"
curl -fsSL -o "$workdir/easylist.txt" "$EASYLIST_URL"
easylist_version="$(grep -m1 '^! Version:' "$workdir/easylist.txt" | sed 's/^! Version:[[:space:]]*//')"
easylist_modified="$(grep -m1 '^! Last modified:' "$workdir/easylist.txt" | sed 's/^! Last modified:[[:space:]]*//')"

echo "==> Converting (EasyList version ${easylist_version})"
"$workdir/converter/.build/release/ConverterTool" convert \
  --safari-version "$SAFARI_VERSION" \
  --input-path "$workdir/easylist.txt" \
  --safari-rules-json-path "$out_json"

rule_count="$(python3 -c "import json; print(len(json.load(open('$out_json'))))")"

cat > "$out_attribution" <<EOF
This file accompanies easylist-compiled.json.

easylist-compiled.json is derived from EasyList (https://easylist.to/),
version ${easylist_version} (last modified ${easylist_modified}), by the
EasyList authors, and is used under the Creative Commons Attribution-
ShareAlike 3.0 Unported licence (CC BY-SA 3.0,
https://creativecommons.org/licenses/by-sa/3.0/). The compiled snapshot is
itself distributed under CC BY-SA 3.0.

Conversion: AdguardTeam/SafariConverterLib ${CONVERTER_TAG} (ConverterTool
convert --safari-version ${SAFARI_VERSION}), run at build time as an
external tool. Rules in snapshot: ${rule_count}.
EOF

echo "==> Wrote ${rule_count} rules to ${out_json}"
echo "==> Wrote attribution to ${out_attribution}"
echo "Re-run the Shields tests to verify the snapshot compiles:"
echo "  swift test --package-path Packages/QwaveKit --filter RuleListCompileTests"
