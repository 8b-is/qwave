#!/bin/bash
# Local mirror of .github/workflows/ci.yml — the same gates, run on this Mac,
# emitting one pasteable transcript to attach to a PR when Actions is down.
#
#   scripts/ci-local.sh [--skip-summarize]
#
# ci.yml has EIGHT jobs. Five block a merge; three carry
# `continue-on-error: true` and can never gate one. This script preserves that
# split exactly — advisory lanes report but never change the exit status:
#
#   BLOCKING  format           xcrun swift-format lint --strict --recursive
#             unit-tests       swift test -c release (Packages/QwaveKit)
#             build-app        xcodegen generate + unsigned Release xcodebuild
#             benchmarks       swift package benchmark thresholds check
#             zig-validation   zig build / build-lib / test + blocklist validate
#
#   ADVISORY  dead-code-report periphery scan --quiet (`|| true` on top of
#                              continue-on-error — doubly non-blocking)
#             unit-tests-next  the same suite on the NEWEST Xcode on the box
#             perf-anchor      Speedometer parser check + baseline summary
#
# Deliberate deviations from ci.yml, all of them local-hygiene only:
#   * No `brew install` and no `sudo xcode-select`. CI provisions an ephemeral
#     runner; this script uses what is installed and says so. A missing tool
#     FAILS a blocking lane and SKIPs an advisory one — it is never papered over.
#   * The pinned-Xcode assertion is reported, not enforced. CI hard-fails on
#     toolchain drift; failing here would just make the script unusable on a
#     Mac that is one Xcode ahead. The header prints both versions and flags
#     a divergence so the transcript is honest about what produced the greens.
#   * xcodebuild output is NOT piped through xcbeautify (CI does it for log
#     readability only) so the literal "** BUILD SUCCEEDED **" survives into
#     the log as evidence, and it builds into build/ci-local/DerivedData
#     instead of ~/Library so nothing leaks between runs.
#   * zig build-lib emits libqpacket.a under build/ci-local/ rather than into
#     zig-core/, which is not gitignored.
#
# NOTE on SummarizeTests: ci.yml does NOT skip it, so neither does this script.
# SummarizeTests is pure-core (no FoundationModels import, no inference) and
# runs in milliseconds. `--skip-summarize` exists for anyone who needs the
# lever, and stamps a DIVERGENCE line into the transcript when used, because
# skipping it means the run no longer mirrors the blocking gate.
#
# The step_* lanes are dispatched by name through run_step, which shellcheck
# cannot see.
# shellcheck disable=SC2329
set -uo pipefail

SKIP_SUMMARIZE=false
for arg in "$@"; do
  case "$arg" in
    --skip-summarize) SKIP_SUMMARIZE=true ;;
    -h|--help) echo "usage: $0 [--skip-summarize]"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; echo "usage: $0 [--skip-summarize]" >&2; exit 64 ;;
  esac
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root" || exit 1
log_dir="build/ci-local"
rm -rf "$log_dir"
mkdir -p "$log_dir"
transcript="$log_dir/transcript.txt"
derived="$repo_root/$log_dir/DerivedData"

say() { printf '%s\n' "$*" | tee -a "$transcript"; }

fmt_dur() {
  local s="$1"
  printf '%dm%02ds' $((s / 60)) $((s % 60))
}

blocking_pass=0; blocking_fail=0
advisory_pass=0; advisory_fail=0; advisory_skip=0
failed_steps=()

# run_step <blocking|advisory> <name> <function>
# The function's stdout/stderr land in build/ci-local/<name>.log. Return 77
# from it to record SKIP (a tool this machine does not have, or a lane that is
# degenerate locally); any other non-zero is a failure.
run_step() {
  local kind="$1" name="$2" fn="$3"
  local log="$log_dir/$name.log"
  local start=$SECONDS rc dur status

  ( set -o pipefail; "$fn" ) >"$log" 2>&1
  rc=$?
  dur=$((SECONDS - start))

  if [ "$rc" -eq 0 ]; then
    status="PASS"
  elif [ "$rc" -eq 77 ]; then
    status="SKIP"
  else
    status="FAIL"
  fi

  if [ "$kind" = "blocking" ]; then
    case "$status" in
      PASS) blocking_pass=$((blocking_pass + 1)) ;;
      *) blocking_fail=$((blocking_fail + 1)); status="FAIL"; failed_steps+=("$name") ;;
    esac
  else
    case "$status" in
      PASS) advisory_pass=$((advisory_pass + 1)) ;;
      SKIP) advisory_skip=$((advisory_skip + 1)) ;;
      FAIL) advisory_fail=$((advisory_fail + 1)) ;;
    esac
  fi

  say "$(printf '[%-8s] %-18s %-4s %7s   %s' \
    "$kind" "$name" "$status" "$(fmt_dur "$dur")" "$log")"
  if [ "$status" != "PASS" ]; then
    tail -n 12 "$log" | sed 's/^/             | /' | tee -a "$transcript"
  fi
}

# --- lanes -------------------------------------------------------------------

step_format() {
  command -v xcrun >/dev/null 2>&1 || { echo "xcrun not found"; return 1; }
  xcrun swift-format lint --strict --recursive \
    Sources \
    Packages/QwaveKit/Sources \
    Packages/QwaveKit/Tests \
    Packages/QwaveKit/Package.swift \
    Benchmarks/Benchmarks \
    Benchmarks/Package.swift
}

SWIFT_TEST_ARGS=(-c release --package-path Packages/QwaveKit)
$SKIP_SUMMARIZE && SWIFT_TEST_ARGS+=(--skip SummarizeTests)

step_unit_tests() {
  swift test "${SWIFT_TEST_ARGS[@]}"
}

step_build_app() {
  command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found (brew install xcodegen)"; return 1; }
  command -v zig >/dev/null 2>&1 || { echo "zig not found — the packet-filter preBuildScript hard-errors without it"; return 1; }
  command -v go >/dev/null 2>&1 || { echo "go not found — WireGuardKitGo builds libwg-go.a at compile time"; return 1; }
  xcodegen generate --spec project.yml || return 1
  xcodebuild \
    -project Qwave.xcodeproj \
    -scheme Qwave \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY= \
    build || return 1
  # CI's "Locate built app" step, with the literal success marker asserted.
  grep -q '^\*\* BUILD SUCCEEDED \*\*$' "$repo_root/$log_dir/build-app.log" || {
    echo "xcodebuild exited 0 but did not print ** BUILD SUCCEEDED **"
    return 1
  }
  [ -d "$derived/Build/Products/Release/Qwave.app" ] || {
    echo "no Qwave.app at $derived/Build/Products/Release/"
    return 1
  }
  echo "Built: $derived/Build/Products/Release/Qwave.app"
}

step_benchmarks() {
  command -v brew >/dev/null 2>&1 || { echo "brew not found; jemalloc backs mallocCountTotal"; return 1; }
  local jemalloc
  jemalloc="$(brew --prefix jemalloc 2>/dev/null)"
  [ -n "$jemalloc" ] && [ -d "$jemalloc" ] || {
    echo "jemalloc not installed (brew install jemalloc) — mallocCountTotal cannot be measured"
    return 1
  }
  export PKG_CONFIG_PATH="$jemalloc/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  cd Benchmarks || return 1
  swift package benchmark thresholds check --no-progress
}

step_zig_validation() {
  command -v zig >/dev/null 2>&1 || { echo "zig not found (brew install zig)"; return 1; }
  cd zig-core || return 1
  zig build || return 1
  zig build-lib src/packet.zig -O ReleaseSafe -target aarch64-macos \
    -femit-bin="$repo_root/$log_dir/libqpacket.a" || return 1
  zig build test || return 1
  zig-out/bin/qwave-blocklist ../Packages/QwaveKit/Sources/Shields/Resources/easylist-compiled.json
}

step_dead_code_report() {
  command -v periphery >/dev/null 2>&1 || {
    echo "periphery not installed — advisory lane skipped"
    return 77
  }
  cd Packages/QwaveKit || return 1
  periphery scan --quiet || true
}

step_unit_tests_next() {
  # Same glob order as ci.yml: Xcode_*.app first, then any Xcode*.app.
  local newest current
  newest="$(find /Applications -maxdepth 1 -name 'Xcode_*.app' 2>/dev/null | sort -V | tail -n1)"
  [ -n "$newest" ] || newest="$(find /Applications -maxdepth 1 -name 'Xcode-*.app' -o -maxdepth 1 -name 'Xcode.app' 2>/dev/null | sort -V | tail -n1)"
  [ -n "$newest" ] && [ -d "$newest/Contents/Developer" ] || {
    echo "no usable /Applications/Xcode*.app found"
    return 77
  }
  current="$(xcode-select -p 2>/dev/null)"
  if [ "$newest/Contents/Developer" = "$current" ]; then
    echo "newest Xcode ($newest) is already the selected toolchain — this lane"
    echo "would re-run the blocking suite verbatim, so it carries no evidence."
    return 77
  fi
  echo "DEVELOPER_DIR=$newest/Contents/Developer"
  DEVELOPER_DIR="$newest/Contents/Developer" swift --version || return 1
  DEVELOPER_DIR="$newest/Contents/Developer" swift test "${SWIFT_TEST_ARGS[@]}"
}

step_perf_anchor() {
  command -v node >/dev/null 2>&1 || { echo "node not installed — advisory lane skipped"; return 77; }
  node Benchmarks/Speedometer/parse.test.mjs || return 1
  node Benchmarks/Speedometer/parse.mjs \
    Benchmarks/Speedometer/baseline.json \
    --baseline Benchmarks/Speedometer/baseline.json
}

# --- header ------------------------------------------------------------------

run_start=$SECONDS
sha="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
subject="$(git log -1 --pretty=%s 2>/dev/null || echo unknown)"
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
dirty_count="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
[ "$dirty_count" = "0" ] && tree="clean" || tree="DIRTY ($dirty_count paths)"
local_xcode="$(xcodebuild -version 2>/dev/null | head -n1)"
local_swift="$(swift --version 2>&1 | grep -o 'Apple Swift version [0-9.]*' | head -n1)"
# Read the pin out of ci.yml rather than hardcoding it, so this line cannot
# silently go stale when the workflow's pin moves.
ci_xcode="$(sed -n 's/.*grep -q "Xcode \([0-9.]*\)".*/\1/p' .github/workflows/ci.yml | head -n1)"

say "================================================================================"
say " qwave ci-local — local mirror of .github/workflows/ci.yml"
say "================================================================================"
say " commit     $sha  $subject"
say " branch     $branch (tree $tree)"
say " date       $(date '+%Y-%m-%dT%H:%M:%S%z')"
say " machine    $(sysctl -n hw.model) · $(uname -m) · macOS $(sw_vers -productVersion) · $(sysctl -n hw.ncpu) cores"
say " toolchain  $local_xcode · $local_swift"
if [ -n "$ci_xcode" ] && [ "$local_xcode" != "Xcode $ci_xcode" ]; then
  say " ci pin     Xcode $ci_xcode — DIVERGES from this machine (ci.yml hard-fails on drift;"
  say "            this script reports it instead, see the header comment)"
else
  say " ci pin     Xcode $ci_xcode — matches this machine"
fi
$SKIP_SUMMARIZE && say " DIVERGENCE --skip-summarize: the unit-test lanes are NOT the CI gate"
say " repo       $repo_root"
say " logs       $log_dir/"
say "--------------------------------------------------------------------------------"

run_step blocking format           step_format
run_step blocking unit-tests       step_unit_tests
run_step blocking build-app        step_build_app
run_step blocking benchmarks       step_benchmarks
run_step blocking zig-validation   step_zig_validation
run_step advisory dead-code-report step_dead_code_report
run_step advisory unit-tests-next  step_unit_tests_next
run_step advisory perf-anchor      step_perf_anchor

say "--------------------------------------------------------------------------------"
total=$((SECONDS - run_start))
advisory_tally="advisory ${advisory_pass} pass / ${advisory_fail} fail / ${advisory_skip} skip"
if [ "$blocking_fail" -eq 0 ]; then
  say "VERDICT: PASS — ${blocking_pass}/5 blocking green; ${advisory_tally}; $(fmt_dur "$total") on $(hostname -s) @ $sha"
  exit 0
fi
say "VERDICT: FAIL — ${blocking_fail}/5 blocking red (${failed_steps[*]}); ${advisory_tally}; $(fmt_dur "$total") on $(hostname -s) @ $sha"
exit 1
