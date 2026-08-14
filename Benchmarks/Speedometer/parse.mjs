#!/usr/bin/env node
// Speedometer 3 result parser for Qwave.
//
// Reduces a run to the three numbers the perf phase tracks:
//   - score            (Speedometer's headline; HIGHER is better)
//   - geomean (ms)      (per-iteration geomean; lower is better)
//   - iteration-0 gap % (cold-start tax: iter0 total vs the MEDIAN steady-state total)
// plus per-suite means, so a regression can be attributed to a suite.
//
// Accepts BOTH schemas:
//   - a full Speedometer 3 details export (flat object keyed by test name,
//     with "Iteration-N-Total", "Geomean", "Score", and per-suite entries)
//   - the committed baseline.json summary ({ score, geomean, iterationTotals, suites })
//
// Usage:
//   node parse.mjs <run.json>                 # print the summary
//   node parse.mjs <run.json> --baseline b    # + compare score vs baseline, exit 0 always
//                                             #   (alert-only; prints ALERT on >5% score drop)
//   node parse.mjs <run.json> --json          # machine-readable summary on stdout

import { readFileSync } from "node:fs";

const REGRESSION_PCT = 5; // alert threshold on score drop vs baseline

function median(xs) {
  if (xs.length === 0) return NaN;
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

// Normalize either schema to { score, geomean, iterationTotals:[mean...], suites:{name:mean} }.
export function normalize(doc) {
  // Summary schema (committed baseline).
  if (typeof doc.score === "object" && Array.isArray(doc.iterationTotals)) {
    return {
      score: doc.score.mean,
      geomean: doc.geomean.mean,
      iterationTotals: doc.iterationTotals.map((t) => t.mean),
      suites: Object.fromEntries(Object.entries(doc.suites).map(([k, v]) => [k, v.mean])),
    };
  }
  // Full Speedometer export: flat object keyed by test name.
  const iterations = [];
  const suites = {};
  for (const [name, entry] of Object.entries(doc)) {
    if (!entry || typeof entry.mean !== "number") continue;
    const iterMatch = /^Iteration-(\d+)-Total$/.exec(name);
    if (iterMatch) {
      iterations[Number(iterMatch[1])] = entry.mean;
      continue;
    }
    if (name === "Geomean" || name === "Score") continue;
    if (name.includes("/")) continue; // sub-test breakdown — not a top-level suite
    suites[name] = entry.mean;
  }
  return {
    score: doc.Score?.mean,
    geomean: doc.Geomean?.mean,
    iterationTotals: iterations.filter((x) => typeof x === "number"),
    suites,
  };
}

export function summarize(doc) {
  const n = normalize(doc);
  const iter0 = n.iterationTotals[0];
  const steady = n.iterationTotals.slice(1);
  const steadyMedian = median(steady);
  const iter0GapPct = iter0 != null && steadyMedian ? ((iter0 - steadyMedian) / steadyMedian) * 100 : NaN;
  const suitesSorted = Object.entries(n.suites).sort((a, b) => b[1] - a[1]);
  return {
    score: n.score,
    geomean: n.geomean,
    iter0: iter0,
    steadyMedian,
    iter0GapPct,
    slowest: suitesSorted.slice(0, 5),
    fastest: suitesSorted.slice(-5).reverse(),
    suites: n.suites,
  };
}

function fmt(x, d = 2) {
  return typeof x === "number" && isFinite(x) ? x.toFixed(d) : "n/a";
}

function main(argv) {
  const args = argv.slice(2);
  const runPath = args.find((a) => !a.startsWith("--"));
  if (!runPath) {
    console.error("usage: node parse.mjs <run.json> [--baseline <b.json>] [--json]");
    process.exit(2);
  }
  const jsonOut = args.includes("--json");
  const baselineIdx = args.indexOf("--baseline");
  const baselinePath = baselineIdx >= 0 ? args[baselineIdx + 1] : null;

  const s = summarize(JSON.parse(readFileSync(runPath, "utf8")));

  if (jsonOut) {
    process.stdout.write(JSON.stringify(s, null, 2) + "\n");
    return;
  }

  console.log(`Speedometer 3 — ${runPath}`);
  console.log(`  Score           ${fmt(s.score)}   (higher is better)`);
  console.log(`  Geomean         ${fmt(s.geomean)} ms   (lower is better)`);
  console.log(`  Iteration-0     ${fmt(s.iter0)} ms  vs steady median ${fmt(s.steadyMedian)} ms`);
  console.log(`  Cold-start gap  ${fmt(s.iter0GapPct, 1)} %   (target: within 25%)`);
  console.log(`  Slowest suites: ${s.slowest.map(([k, v]) => `${k} ${fmt(v, 1)}`).join(", ")}`);

  if (baselinePath) {
    const b = summarize(JSON.parse(readFileSync(baselinePath, "utf8")));
    const dropPct = b.score ? ((b.score - s.score) / b.score) * 100 : 0;
    const verdict = dropPct > REGRESSION_PCT ? "ALERT" : "ok";
    console.log(
      `  vs baseline:    score ${fmt(s.score)} vs ${fmt(b.score)} (${dropPct >= 0 ? "-" : "+"}${fmt(Math.abs(dropPct), 1)}%) → ${verdict}`
    );
    // Alert-only by contract: never a nonzero exit, so the CI lane can never gate a merge.
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main(process.argv);
}
