# Qwave in-process benchmarks

[package-benchmark](https://github.com/ordo-one/package-benchmark) suite for
the hot in-process paths: `OmniboxParser.parse` (every keystroke, and the
WHATWG/WebURL adoption measured rather than asserted), `OmniboxSuggester`
ranking, `HistoryStore` queries at 50k rows, `UBORuleListCompiler` JSON
compilation, and the `SessionRestorer` round-trip.

```sh
cd Benchmarks
swift package benchmark                       # run everything, human output
swift package benchmark thresholds check      # what CI runs
swift package --allow-writing-to-package-directory \
  benchmark thresholds update                 # re-record after intended changes
```

**Benchmark names must not contain spaces.** `thresholds update` writes each
file through a shell-safety filter that rewrites spaces to underscores, but
the threshold *reader* looks the file up under the benchmark's raw name. Name
a benchmark `Foo.bar (baz)` and the update step writes
`Thresholds/Target.Foo.bar_(baz).p90.json`, the check step then looks for
`Thresholds/Target.Foo.bar (baz).p90.json`, finds nothing, and **skips that
benchmark silently** — no threshold, no gate, no error. Keeping the two
spellings identical is the only thing that makes the gate real, so the names
here use underscores where a space would read more naturally.

**`mallocCountTotal` is process-wide, not per-thread.** package-benchmark's
jemalloc backend reads `stats.arenas.<all>.{small,large}.nrequests` and takes
the delta across the measured window, so *every* thread's allocations during
that window land in the number. That is invisible while a benchmark measures a
tight synchronous loop, and it dominates as soon as one does not: a benchmark
whose measured window is a single `await`-crossing call (an actor hop, disk
I/O) also counts whatever the rest of the process did while that call was in
flight, and the count then moves with machine load rather than with the code.
`HistoryStore.entries(matching:)` measured 537, 602, 666 and 675 at one commit
for exactly this reason (#141). Two rules follow, and both are load-bearing:

- **Seed corpora in `setup:`, never inside the measured closure.** Setup inside
  the closure runs per sample, so an expensive corpus starves the run of
  samples — 50k rows seeded in-closure left this benchmark with two, and a p90
  over two samples is just the worse one.
- **Measure many iterations per window, or many windows, or both.** The signal
  has to dominate whatever else the process is doing.

CI checks **`mallocCountTotal` only**, against the committed thresholds in
`Thresholds/` with a 25% p90 tolerance: allocation counts are
near-deterministic for a given code path, so they survive heterogeneous
runners (the job is pinned to GitHub-hosted `macos-15`);
wall-clock is collected locally but never checked. Threshold updates are
reviewed like code — a jump in allocations is a diff someone must own.

**Scope limit:** these benchmarks measure in-process work ONLY. The
hibernation memory claim lives in WebKit's out-of-process WebContent
processes, which no in-process metric can see — that claim is proven by
`Packages/QwaveKit/Tests/BrowserCoreTests/HibernationReclaimTests` and the
numbers in [docs/ENERGY.md](../docs/ENERGY.md).
