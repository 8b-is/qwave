#!/usr/bin/env bash
# Speedometer 3 harness for Qwave — a human-at-the-Mac driver.
#
# A GUI browser benchmark cannot run headlessly or in CI: it needs a real
# display, WindowServer, and GPU. This script makes the on-Mac run repeatable
# and honest (fresh profile per run, energy governor ACTIVE — no tier pinning,
# no benchmark-special flags), then parses the exported JSON against the
# committed baseline. See docs/PERF.md.
#
# It does NOT auto-scrape results: after each run you export Speedometer's
# details JSON ("Download results as JSON") to the path it prints, then it
# parses and, across N runs, reports the median Score.
#
# Usage:
#   QWAVE_APP=/path/to/Qwave.app \
#   QWAVE_PROFILE_DIR="$HOME/Library/Application Support/Qwave" \
#   scripts/benchmark.sh [-n RUNS] [-u SPEEDOMETER_URL]
#
# QWAVE_PROFILE_DIR is REQUIRED and has no default: this script moves it aside
# for a fresh profile and restores it on exit. Point it at the exact profile
# directory your build uses so nothing else is touched.

set -euo pipefail

RUNS=5
URL="https://browserbench.org/Speedometer3.0/?startAutomatically=true"
while getopts "n:u:" opt; do
  case "$opt" in
    n) RUNS="$OPTARG" ;;
    u) URL="$OPTARG" ;;
    *) echo "usage: $0 [-n RUNS] [-u URL]" >&2; exit 2 ;;
  esac
done

: "${QWAVE_APP:?set QWAVE_APP to the built Qwave.app}"
: "${QWAVE_PROFILE_DIR:?set QWAVE_PROFILE_DIR to the profile directory to isolate (it is moved aside and restored)}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
speedodir="$here/Benchmarks/Speedometer"
runsdir="$speedodir/runs"
mkdir -p "$runsdir"

# --- fresh profile, reversibly ------------------------------------------------
backup=""
restore_profile() {
  if [[ -n "$backup" && -d "$backup" ]]; then
    rm -rf "$QWAVE_PROFILE_DIR"
    mv "$backup" "$QWAVE_PROFILE_DIR"
    echo "restored original profile"
  fi
}
trap restore_profile EXIT INT TERM

if [[ -e "$QWAVE_PROFILE_DIR" ]]; then
  backup="${QWAVE_PROFILE_DIR}.bench-backup.$$"
  mv "$QWAVE_PROFILE_DIR" "$backup"
  echo "moved existing profile aside -> $backup"
fi

scores=()
for i in $(seq 1 "$RUNS"); do
  echo ""
  echo "=== run $i / $RUNS ==="
  rm -rf "$QWAVE_PROFILE_DIR"   # cold profile every run
  out="$runsdir/run-$i.json"
  echo "launching Qwave (governor ACTIVE, no benchmark flags)…"
  open -na "$QWAVE_APP" --args "$URL"
  echo "when Speedometer finishes, export its details JSON to:"
  echo "    $out"
  read -r -p "press RETURN once $out exists… " _
  if [[ ! -f "$out" ]]; then
    echo "no export at $out — skipping run $i" >&2
    continue
  fi
  score="$(node "$speedodir/parse.mjs" "$out" --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).score))')"
  echo "run $i score: $score"
  scores+=("$score")
  node "$speedodir/parse.mjs" "$out" --baseline "$speedodir/baseline.json" | sed 's/^/    /'
  osascript -e 'quit app "Qwave"' 2>/dev/null || true
  sleep 2
done

echo ""
if [[ ${#scores[@]} -eq 0 ]]; then
  echo "no scored runs" >&2; exit 1
fi
median="$(printf '%s\n' "${scores[@]}" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')"
echo "median Score over ${#scores[@]} runs: $median   (baseline 23.88)"
echo "individual runs saved under $runsdir/ (gitignored)"
