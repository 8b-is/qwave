#!/usr/bin/env node
// Locks parse.mjs against the committed baseline so a schema drift or a parser
// regression fails loudly. Run: node parse.test.mjs
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import assert from "node:assert/strict";
import { summarize, normalize } from "./parse.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const baseline = JSON.parse(readFileSync(join(here, "baseline.json"), "utf8"));

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok  ${name}`);
}

// Summary-schema (committed baseline) parses to the known headline numbers.
const s = summarize(baseline);
check("score matches committed baseline", () => assert.ok(Math.abs(s.score - 23.8804) < 0.01));
check("geomean matches committed baseline", () => assert.ok(Math.abs(s.geomean - 42.7055) < 0.01));
check("iteration-0 total is the cold outlier", () => assert.ok(Math.abs(s.iter0 - 76.737) < 0.01));
check("cold-start gap is ~55% (the phase's headline finding)", () =>
  assert.ok(s.iter0GapPct > 45 && s.iter0GapPct < 65, `gap was ${s.iter0GapPct}`)
);
check("NewsSite-Next is the slowest suite", () => assert.equal(s.slowest[0][0], "NewsSite-Next"));
check("WebComponents is among the fastest", () =>
  assert.ok(s.fastest.some(([k]) => k === "TodoMVC-WebComponents"))
);

// The parser also handles a full Speedometer export (flat keyed object).
const fakeExport = {
  "TodoMVC-WebComponents": { mean: 15.6 },
  "TodoMVC-WebComponents/Adding100Items": { mean: 8.6 }, // sub-test must be ignored
  "NewsSite-Next": { mean: 156 },
  "Iteration-0-Total": { mean: 76.7 },
  "Iteration-1-Total": { mean: 49.3 },
  "Iteration-2-Total": { mean: 50.1 },
  Geomean: { mean: 42.7 },
  Score: { mean: 23.9 },
};
const e = normalize(fakeExport);
check("full-export schema: score read from Score entry", () => assert.equal(e.score, 23.9));
check("full-export schema: sub-tests excluded from suites", () =>
  assert.ok(!("TodoMVC-WebComponents/Adding100Items" in e.suites))
);
check("full-export schema: iteration totals collected in order", () =>
  assert.deepEqual(e.iterationTotals, [76.7, 49.3, 50.1])
);

console.log(`\n${passed} checks passed`);
