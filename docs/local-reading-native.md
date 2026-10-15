# Optional native local reading

`SovereignCore.RustLocalReadingSession` extends the existing qwave-core C ABI for
bounded English/Japanese translation and extractive summaries. Both app lanes
use this same shared Swift face. This is an integration boundary under test;
**browser controls and opt-in automatic speech are not connected yet**.

Default public builds have no local model implementation or model files. Their
weak C stubs report unavailable. They never produce placeholder translations or
silently send text to another service. An explicitly linked integration archive
must implement ABI version 1 and retain Qwave's existing sovereign-core exports.
No second C bridge or HTTP server is required.

The caller provisions immutable private assets before loading. Loading and
inference run on one utility worker. A busy request fails promptly; a UI may
keep only the latest pending document request. Native session and generation IDs
are not memory addresses. Starting a generation cancels older work; cancelling
an older task cannot cancel the next document. Release the session when finished.

Translate small plain-text blocks (at most 4096 UTF-8 bytes), retaining originals
and entry identifiers for restoration. Summaries accept 1–32 source sentences,
at most 1024 bytes each, and return verbatim selections. The C header documents
JSON sizes, ownership, errors and the required output buffer capacity. Native
failure or cancellation means keeping original content. Model output is data:
never insert a translation as HTML or execute it as page instructions.

Immediately before presenting results or starting speech, the browser must
recheck its current document, reading-mode state, and task cancellation. A
result already returned across the ABI cannot be recalled on navigation. Speech
is off by default and may start automatically only inside the user's opt-in
reading mode, with visible Stop and cancellation on mode exit/navigation.

Validation distinguishes the standalone package's unavailable behavior from an
explicitly linked implementation. The local pilot has exercised actual CPU
translation through C and Swift, original-sentence retention, stale-generation
rejection and task cancellation. Device memory, broader translation/summary
quality, model setup UI, browser DOM delivery and audio remain separate gates;
this code does not establish an App Store-ready feature.

## Explicit integration builds

Select a reviewed external integration manifest with the build setting
`QWAVE_LOCAL_READING_MANIFEST=/absolute/path/to/integration/Cargo.toml`. It must
produce `libqwave_core.a`, retain the existing core exports, implement reading
ABI v1, and have a committed `Cargo.lock`. The script uses `--locked` and accepts
this selection only in the stable channel. Model files are not bundled.

The optional `QWAVE_LOCAL_READING_TARGET_DIR` chooses an absolute, separate Cargo
cache. Otherwise, local-reading products use a `local-reading` subdirectory of
the default Cargo target directory. A cache equal to the default core cache is
rejected so two different manifests cannot overwrite the same named archive.
`CARGO_TARGET_DIR`, when set, determines the default core cache; both modes copy
the resulting architecture slices into the existing per-platform link location.

Both app lanes always run the core build phase. This makes switching the
manifest setting (including clearing it) rebuild/select the intended archive
instead of reusing a previously linked implementation. The final per-platform
archive is replaced only after all slices build and lipo succeeds. Keep private
build settings outside the public project and do not replace uploaded release
artifacts with an experimental integration build.

Local validation built the unsigned Mac app for arm64 and x86_64 with an
explicit implementation, then rebuilt the same Xcode products with the setting
cleared. Both slices changed from the real reading export to the unavailable
weak stub; linked C consumers returned ABI versions 1 and 0 respectively. Six
invalid manifest/cache/channel selections failed without changing the archive.
This checks build selection, not browser operation, iOS linking, model quality,
or distribution readiness.

## Host-owned model files

`LocalReadingModelStore.install(modelURL:tokenizerURL:)` accepts explicitly
selected local files for the pinned LFM2.5-1.2B-Instruct Q4_K_M model and its
canonical tokenizer. It streams bounded chunks into a private staging directory,
checks exact lengths and SHA-256 values, and publishes the complete pair by
renaming that directory. The source files are untouched. Installed files are
owner-readable, with no write bits; the managed directory is private and excluded
from backups. The weights retain their original license and are not bundled or
downloaded by this API.

`installed()` revalidates the pair before returning its URLs. Missing files,
changed bytes, writable assets and symbolic links cannot become a usable model.
A damaged installation is left for explicit repair, never silently overwritten.
Import and verification share the native utility worker, reject concurrent work,
and check cancellation between chunks; cancelled staging files are removed. A
cancellation racing final delivery may leave a fully verified installation for
the next lookup. Read-only files prevent accidental edits, not a malicious writer
with the same OS account; the host must keep assets immutable for each session.

The store layer has synthetic import/corruption/cancellation tests. File-picker
controls, application-sandbox import testing and real-model setup through the
browser are still pending. Hosts must offer setup only when the native engine is
available, and must never start speech merely because an import succeeded.
