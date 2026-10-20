Run `bash scripts/diagnostics/omnibox-allocations.sh` on macOS with Xcode and
Homebrew jemalloc already installed. `JEMALLOC_PREFIX` can select an existing
installation. The script builds one temporary executable, runs it with a
process-scoped allocator, and removes only its own temporary directory.

The JSON report separates legacy/encoded/guarded host access and URL string
access using the exact synthetic 500-URL fixture from the Omnibox benchmark.
Each operation runs 100 passes in three warmed trials. The malloc positive
control must observe at least 100 allocations; the empty control reveals
measurement overhead. Cached host creation is outside measurement.

These are process-wide jemalloc request counts, not bytes, latency, or
whole-application results. Compare compiler, OS/Foundation, allocator version,
fixture and controls before comparing counts. A locally passing probe does not
prove the pinned CI gate passes. No benchmark threshold is changed by this tool.

CI runs the probe as a separate informational step before the unchanged
threshold check. A probe failure is visible but cannot skip that check.
