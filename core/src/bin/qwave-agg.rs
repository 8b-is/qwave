// qwave-agg — aggregate scrubbed telemetry JSONL into data-science JSON.
//
// Input: one JSON event per line (already scrubbed — see telemetry.rs).
// Output: a count histogram, sorted descending, JSON. Everything on stdin
// and stdout, so the pipeline stays shell-friendly:
//
//   cat day.jsonl | qwave-agg > day.histogram.json
//
// This is the tool the nightly debug lane feeds; the private collection
// repo (8b-is/qwave-telemetry) stores the scrubbed JSONL and these
// histograms.

use std::io::{self, BufRead, Write};

use qwave_core::telemetry::{Aggregator, scrub_line};

fn main() -> io::Result<()> {
    let stdin = io::stdin();
    let mut agg = Aggregator::new();
    let mut lines = 0u64;

    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        lines += 1;
        // Belt and braces: even a line that claims to be scrubbed is passed
        // through the scrubber again before it is counted.
        agg.observe_line(&scrub_line(&line));
    }

    let mut out = io::stdout().lock();
    writeln!(out, "// qwave-telemetry aggregate")?;
    writeln!(out, "// lines: {lines}")?;
    writeln!(out, "{}", agg.to_json())?;
    Ok(())
}
