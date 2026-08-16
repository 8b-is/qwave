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

CI checks **`mallocCountTotal` only**, against the committed thresholds in
`Thresholds/` with a 25% p90 tolerance: allocation counts are
near-deterministic for a given code path, so they survive heterogeneous
runners (the job is pinned to one Blacksmith runner class regardless);
wall-clock is collected locally but never checked. Threshold updates are
reviewed like code — a jump in allocations is a diff someone must own.

**Scope limit:** these benchmarks measure in-process work ONLY. The
hibernation memory claim lives in WebKit's out-of-process WebContent
processes, which no in-process metric can see — that claim is proven by
`Packages/QwaveKit/Tests/BrowserCoreTests/HibernationReclaimTests` and the
numbers in [docs/ENERGY.md](../docs/ENERGY.md).
